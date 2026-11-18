import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat.dart' show ApiException;
import 'log.dart';

/// GIFs through the server's Giphy integration app (`integration_giphy`),
/// which holds the Giphy key and passes the pictures on, so Tala never talks
/// to Giphy itself. Typing `/giphy cats` (or `/gif cats`) opens [GifPanel].
/// A pick is sent as its giphy.com link, as Talk's own picker does, and other
/// clients show it from that link.

/// What the server offers.
enum GifSupport {
  /// No Giphy app on the server.
  none,

  /// The app is there, but nobody has given it a Giphy key yet.
  unconfigured,
  ready,
}

/// One search result.
class GifResult {
  const GifResult({
    required this.title,
    required this.mediaPath,
    required this.link,
  });

  /// Null for an entry Tala can't show or send.
  static GifResult? fromJson(Object? j) {
    if (j is! Map) return null;
    final media = giphyMediaPath(j['thumbnailUrl']);
    final link = j['resourceUrl'];
    if (media == null || link is! String || !isGiphyLink(link)) return null;
    final title = j['title'];
    return GifResult(
      title: title is String && title.trim().isNotEmpty ? title.trim() : 'GIF',
      mediaPath: media,
      link: link,
    );
  }

  final String title;

  /// The picture's path on the user's own server.
  final String mediaPath;

  /// What gets sent: the giphy.com page.
  final String link;
}

/// A page of results. [more] is false once a page came back short.
class GifPage {
  const GifPage(this.gifs, {required this.next, required this.more});
  final List<GifResult> gifs;
  final int next;
  final bool more;

  static const size = 24;

  factory GifPage.fromJson(Object? d, int cursor) {
    final entries = d is Map ? d['entries'] : null;
    final list = entries is List ? entries : const [];
    final next = d is Map ? d['cursor'] : null;
    return GifPage(
      [for (final e in list) ?GifResult.fromJson(e)],
      next: next is int ? next : cursor + list.length,
      more: list.length >= size,
    );
  }
}

/// What the GIF screens need from the server.
class GifSource {
  const GifSource({
    required this.support,
    required this.search,
    required this.media,
    required this.forLink,
  });

  final Future<GifSupport> Function() support;

  /// Trending when [term] is empty.
  final Future<GifPage> Function(String term, int cursor) search;

  /// A picture from [GifResult.mediaPath].
  final Future<Uint8List> Function(String path) media;

  /// The picture for a giphy link in a message; null when the server
  /// doesn't show it.
  final Future<Uint8List?> Function(String link) forLink;
}

/// The search typed in the composer, when the whole message is a GIF
/// command: `/giphy`, `/gif`, then optionally what to look for.
String? gifCommandTerm(String text) {
  final m = RegExp(r'^/(?:giphy|gif)(?:[ \t]+([^\n]*))?$').firstMatch(text);
  return m == null ? null : (m.group(1) ?? '').trim();
}

final _giphyPage =
    RegExp(r'^https?://(?:www\.)?giphy\.com/gifs/[^/?&#\s]+$', caseSensitive: false);
final _giphyMedia = RegExp(
  r'^https?://(?:www\.)?media\.giphy\.com/media/[^/?&#\s]+/giphy\.gif$',
  caseSensitive: false,
);

/// The links the server's Giphy app previews (its `getGifId`).
bool isGiphyLink(String url) =>
    _giphyPage.hasMatch(url) || _giphyMedia.hasMatch(url);

const _appRoot = ['index.php', 'apps', 'integration_giphy'];

/// The server-relative path of a picture the Giphy app passes on, from one of
/// its own absolute links. Only the app's picture route is accepted, and
/// it's rebuilt on the signed-in server, so credentials only ever go there
/// even if the server reports another host name.
String? giphyMediaPath(Object? url) {
  if (url is! String) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final s = uri.pathSegments;
  for (var i = 0; i + 1 < s.length; i++) {
    if (s[i] != 'integration_giphy') continue;
    final rest = s.sublist(i + 1);
    final start = rest.length == 9 && rest[0] == 'private' ? 1 : 0;
    final route = rest.sublist(start);
    if (route.length != 8 || route[0] != 'gif' || route[1] != 'direct') {
      return null;
    }
    return _route(route.sublist(2));
  }
  return null;
}

String? _route(List<String> parts) {
  if (parts.length != 6 ||
      parts.any((p) => p.isEmpty || p == '.' || p == '..')) {
    return null;
  }
  return Uri(pathSegments: ['', ..._appRoot, 'gif', 'direct', ...parts]).path;
}

/// The same picture as animated WebP, which Giphy keeps beside each GIF at
/// about half the size with the same motion. Null if [path] isn't a GIF.
String? webpPath(String path) {
  final parts = Uri.parse(path).pathSegments;
  if (parts.length < 6) return null;
  final file = parts[parts.length - 4];
  final rid = parts[parts.length - 2];
  if (!file.endsWith('.gif')) return null;
  String swap(String name) =>
      name.endsWith('.gif') ? '${name.substring(0, name.length - 4)}.webp' : name;
  return Uri(pathSegments: [
    '',
    ...parts.sublist(0, parts.length - 4),
    swap(file),
    parts[parts.length - 3],
    swap(rid),
    parts.last,
  ]).path;
}

/// The small moving picture for a resolved Giphy link. The app's own
/// `proxied_url` is the full-size original, often megabytes, so the
/// 200-wide version is asked for when its address can be read.
String? gifPathFromRichObject(Object? rich) {
  if (rich is! Map) return null;
  final id = rich['id'];
  final small = (rich['images'] as Object?) is Map
      ? (rich['images'] as Map)['fixed_width']
      : null;
  final url = small is Map ? small['url'] : null;
  if (id is String && url is String) {
    final uri = Uri.tryParse(url);
    final host = RegExp(r'^(?:www\.)?([A-Za-z0-9]+)\.giphy\.com$')
        .firstMatch(uri?.host ?? '');
    if (uri != null && host != null && uri.pathSegments.length >= 3 &&
        uri.pathSegments.first == 'media') {
      final q = uri.queryParameters;
      final file = uri.pathSegments.last;
      final path = _route([
        id,
        host.group(1)!,
        file,
        q['cid'] ?? 'cid',
        q['rid'] ?? file,
        q['ct'] ?? 'g',
      ]);
      if (path != null) return path;
    }
  }
  return giphyMediaPath(rich['proxied_url']);
}

/// Over the composer while a GIF command is typed: moving pictures for
/// [term], or trending ones for an empty term. Searches wait for a pause in
/// typing, since the server's Giphy key has an hourly limit.
class GifPanel extends StatefulWidget {
  const GifPanel({
    super.key,
    required this.source,
    required this.support,
    required this.term,
    required this.onPick,
  });

  final GifSource source;
  final GifSupport support;
  final String term;
  final ValueChanged<GifResult> onPick;

  @override
  State<GifPanel> createState() => GifPanelState();
}

class GifPanelState extends State<GifPanel> {
  static const _tile = 150.0;
  final ScrollController _scroll = ScrollController();
  final Map<String, Future<Uint8List>> _media = {};
  Timer? _wait;
  int _search = 0;

  /// What [_gifs] are for; null before the first results arrive.
  String? _shownTerm;
  List<GifResult> _gifs = const [];
  int _next = 0;
  bool _more = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _problem;
  int _highlight = 0;
  int _columns = 1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _start(immediately: true);
  }

  @override
  void didUpdateWidget(GifPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.term != widget.term ||
        oldWidget.support != widget.support) {
      _start();
    }
  }

  void _start({bool immediately = false}) {
    _wait?.cancel();
    final search = ++_search;
    if (widget.support != GifSupport.ready) return;
    final term = widget.term;
    if (term == _shownTerm && _problem == null) {
      _loading = false;
      return;
    }
    // Called before a build (from initState or didUpdateWidget), so no
    // setState.
    _loading = true;
    if (immediately || term.isEmpty) {
      _load(term, 0, search);
    } else {
      _wait = Timer(
        const Duration(milliseconds: 500),
        () => _load(term, 0, search),
      );
    }
  }

  Future<void> _load(String term, int cursor, int search) async {
    try {
      final page = await widget.source.search(term, cursor);
      if (!mounted || search != _search) return;
      setState(() {
        if (cursor == 0) {
          _gifs = page.gifs;
          _highlight = 0;
          _media.clear();
          if (_scroll.hasClients) _scroll.jumpTo(0);
        } else {
          _gifs = [..._gifs, ...page.gifs];
        }
        _shownTerm = term;
        _next = page.next;
        _more = page.more && page.gifs.isNotEmpty;
        _loading = false;
        _loadingMore = false;
        _problem = null;
      });
    } catch (e) {
      // Only the status: the request's address holds what was typed.
      final status = e is ApiException ? e.status : null;
      log('gifs: search failed: ${status ?? e.runtimeType}');
      if (!mounted || search != _search) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _more = false;
        _problem = status == 429
            ? 'GIF search is busy. Try again in a while.'
            : status == 401 || status == 403
            ? 'The server\'s Giphy key was refused. An admin can check it '
                  'in the Giphy settings.'
            : 'Couldn\'t search for GIFs.';
        if (cursor == 0) {
          _gifs = const [];
          _shownTerm = term;
        }
      });
    }
  }

  void _onScroll() {
    if (_loading || _loadingMore || !_more) return;
    if (_scroll.position.extentAfter > 300) return;
    final term = _shownTerm;
    if (term == null || term != widget.term) return;
    setState(() => _loadingMore = true);
    _load(term, _next, _search);
  }

  /// Up and Down move a row, Tab and Shift+Tab one picture, Enter sends.
  /// Left and Right stay with the text. Enter does nothing while the
  /// pictures are for older text, so a quick Enter can't send the wrong GIF.
  KeyEventResult? handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    final key = event.logicalKey;
    final count = _gifs.length;
    final current = _shownTerm == widget.term && !_loading;
    void move(int by) {
      if (count == 0) return;
      setState(() => _highlight = (_highlight + by).clamp(0, count - 1));
      _reveal();
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      move(_columns);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      move(-_columns);
    } else if (key == LogicalKeyboardKey.tab) {
      move(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
    } else if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (current && _highlight < count) widget.onPick(_gifs[_highlight]);
    } else {
      return null;
    }
    return KeyEventResult.handled;
  }

  void _reveal() {
    if (!_scroll.hasClients) return;
    final row = _highlight ~/ _columns;
    final top = row * (_tile * 0.75 + 6);
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _tile * 0.75 > _scroll.offset + view) {
      _scroll.jumpTo(
        (top + _tile * 0.75 - view).clamp(0, _scroll.position.maxScrollExtent),
      );
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final term = widget.term;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      term.isEmpty ? 'Trending GIFs' : 'GIFs for "$term"',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  // Giphy asks for this wherever its search is used.
                  Text('Powered by GIPHY', style: small),
                ],
              ),
            ),
            SizedBox(height: 240, child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final message = switch (widget.support) {
      GifSupport.none => 'This server has no GIF search.',
      GifSupport.unconfigured =>
        'GIF search isn\'t set up yet. An admin can add a Giphy key '
            'in the server\'s Giphy settings.',
      GifSupport.ready when _gifs.isEmpty && _problem != null => _problem,
      GifSupport.ready
          when _gifs.isEmpty && !_loading && _shownTerm == widget.term =>
        'No GIFs found.',
      _ => null,
    };
    if (message != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message, textAlign: TextAlign.center),
        ),
      );
    }
    if (_gifs.isEmpty) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _columns = (constraints.maxWidth / _tile).floor().clamp(1, 12);
        return GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columns,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 4 / 3,
          ),
          itemCount: _gifs.length,
          itemBuilder: (context, i) {
            final gif = _gifs[i];
            final bytes = _media[gif.mediaPath] ??= widget.source.media(
              gif.mediaPath,
            );
            return Tooltip(
              message: gif.title,
              waitDuration: const Duration(milliseconds: 600),
              child: InkWell(
                onTap: () => widget.onPick(gif),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                    border: i == _highlight
                        ? Border.all(color: scheme.primary, width: 3)
                        : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: GifImage(
                    bytes: bytes,
                    label: gif.title,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// A moving picture once its bytes arrive; Flutter plays GIFs itself.
class GifImage extends StatelessWidget {
  const GifImage({
    super.key,
    required this.bytes,
    required this.label,
    this.cacheWidth,
    this.fit = BoxFit.contain,
    this.failed,
  });

  final Future<Uint8List?> bytes;
  final String label;
  final int? cacheWidth;
  final BoxFit fit;

  /// Shown when there's no picture; empty by default.
  final Widget? failed;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: bytes,
    builder: (context, snap) {
      final failure = failed ?? const SizedBox.shrink();
      if (snap.hasError) return failure;
      if (snap.connectionState != ConnectionState.done) {
        return const Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      final data = snap.data;
      if (data == null) return failure;
      return Image.memory(
        data,
        // Bounds the memory each decoded frame takes.
        cacheWidth: cacheWidth,
        fit: fit,
        gaplessPlayback: true,
        semanticLabel: label,
        errorBuilder: (context, _, _) => failure,
      );
    },
  );
}
