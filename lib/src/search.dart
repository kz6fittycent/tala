import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'avatars.dart';
import 'chat.dart';
import 'chat_view.dart';
import 'log.dart';
import 'markdown.dart';

/// How many results to ask for at a time.
const searchPageSize = 20;

/// A message the server's search found.
class SearchHit {
  const SearchHit({
    required this.token,
    required this.messageId,
    required this.title,
    required this.excerpt,
    required this.actorType,
    required this.actorId,
    required this.timestamp,
  });

  /// Null for an entry without the fields needed to open it.
  static SearchHit? fromJson(Map<String, dynamic> j) {
    final a = j['attributes'];
    if (a is! Map) return null;
    final token = a['conversation'];
    final id = int.tryParse('${a['messageId']}');
    if (token is! String || token.isEmpty || id == null) return null;
    return SearchHit(
      token: token,
      messageId: id,
      title: j['title'] as String? ?? '',
      excerpt: plainExcerpt(j['subline'] as String? ?? ''),
      actorType: a['actorType'] as String? ?? '',
      actorId: a['actorId'] as String? ?? '',
      timestamp: int.tryParse('${a['timestamp']}') ?? 0,
    );
  }

  final String token;
  final int messageId;

  /// The server's own "Maya in Book club".
  final String title;
  final String excerpt;
  final String actorType;
  final String actorId;
  final int timestamp;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
}

/// The server sends the message's raw source, so `**` would show otherwise.
String plainExcerpt(String source) {
  final blocks = parseMarkdown(source, const {});
  final text = blocks == null
      ? source
      : flattenMarkdown(blocks).map((s) => s.text).join();
  return text.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
}

class SearchPage {
  const SearchPage(this.hits, this.cursor, this.hasMore);
  final List<SearchHit> hits;
  final Object? cursor;
  final bool hasMore;
}

/// Searches messages, in one conversation if [conversation] is set. Closes with
/// a conversation's token if the user chooses to open one.
class SearchDialog extends StatefulWidget {
  const SearchDialog({
    super.key,
    required this.search,
    required this.context,
    required this.preview,
    required this.selfId,
    this.conversation,
    this.conversationName,
    this.avatars,
  });
  final Future<SearchPage> Function(
    String term, {
    String? token,
    Object? cursor,
  })
  search;
  final Future<List<ChatMessage>> Function(String token, int messageId) context;
  final Future<Uint8List> Function(int fileId) preview;
  final String selfId;
  final String? conversation;
  final String? conversationName;
  final AvatarStore? avatars;

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  static const _pause = Duration(milliseconds: 400);

  final TextEditingController _term = TextEditingController();
  Timer? _timer;
  final List<SearchHit> _hits = [];
  Object? _cursor;
  bool _hasMore = false;
  bool _searched = false;
  bool _searching = false;
  bool _loadingMore = false;
  bool _failed = false;

  /// Only the newest search may show its results.
  int _latest = 0;

  void _changed(String text) {
    _timer?.cancel();
    final term = text.trim();
    final search = ++_latest;
    if (term.isEmpty) {
      setState(() {
        _hits.clear();
        _hasMore = false;
        _searched = false;
        _searching = false;
        _failed = false;
      });
      return;
    }
    setState(() => _searching = true);
    _timer = Timer(_pause, () => _run(term, search));
  }

  Future<void> _run(String term, int search) async {
    try {
      final page = await widget.search(term, token: widget.conversation);
      if (!mounted || search != _latest) return;
      setState(() {
        _hits
          ..clear()
          ..addAll(page.hits);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _searched = true;
        _searching = false;
        _failed = false;
      });
    } catch (e) {
      _logFailure(e);
      if (!mounted || search != _latest) return;
      setState(() {
        _hits.clear();
        _hasMore = false;
        _searching = false;
        _failed = true;
      });
    }
  }

  Future<void> _more() async {
    final search = _latest;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.search(
        _term.text.trim(),
        token: widget.conversation,
        cursor: _cursor,
      );
      if (!mounted || search != _latest) return;
      setState(() {
        _hits.addAll(page.hits);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      _logFailure(e);
      if (!mounted || search != _latest) return;
      setState(() => _loadingMore = false);
    }
  }

  /// Not the error itself: its address holds what was searched for.
  void _logFailure(Object e) => log(
    'search failed: ${e is ApiException ? e.status : e.runtimeType}',
  );

  Future<void> _open(SearchHit hit) async {
    final navigator = Navigator.of(context);
    final open = await showDialog<bool>(
      context: context,
      builder: (_) => MessageContextDialog(
        hit: hit,
        load: widget.context,
        preview: widget.preview,
        selfId: widget.selfId,
        avatars: widget.avatars,
      ),
    );
    if (open == true && mounted) navigator.pop(hit.token);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _term.dispose();
    super.dispose();
  }

  Widget _results(BuildContext context) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? message = _failed
        ? 'Couldn\'t search. Check your connection and try again.'
        : _searched && _hits.isEmpty
        ? 'No messages found.'
        : null;
    if (message != null) return Center(child: Text(message));
    final dates = MaterialLocalizations.of(context);
    return ListView.builder(
      itemCount: _hits.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == _hits.length) {
          return Center(
            child: TextButton(
              onPressed: _loadingMore ? null : _more,
              child: Text(_loadingMore ? 'Loading…' : 'Show more'),
            ),
          );
        }
        final hit = _hits[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Avatar(
            name: hit.title,
            image: hit.actorType == 'users'
                ? widget.avatars?.forUser(hit.actorId)
                : null,
          ),
          title: Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            hit.excerpt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            dates.formatShortDate(hit.time),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          onTap: () => _open(hit),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.conversationName == null
          ? 'Search messages'
          : 'Search ${widget.conversationName}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    content: SizedBox(
      width: 520,
      height: 460,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _term,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Search for',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: _changed,
          ),
          const SizedBox(height: 8),
          Expanded(child: _results(context)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}

/// A found message among its neighbors. Reading it here moves no read marker.
/// Closes with true to open the conversation.
class MessageContextDialog extends StatefulWidget {
  const MessageContextDialog({
    super.key,
    required this.hit,
    required this.load,
    required this.preview,
    required this.selfId,
    this.avatars,
  });
  final SearchHit hit;
  final Future<List<ChatMessage>> Function(String token, int messageId) load;
  final Future<Uint8List> Function(int fileId) preview;
  final String selfId;
  final AvatarStore? avatars;

  @override
  State<MessageContextDialog> createState() => _MessageContextDialogState();
}

class _MessageContextDialogState extends State<MessageContextDialog> {
  final GlobalKey _found = GlobalKey();
  final Map<int, Future<Uint8List>> _previews = {};
  List<ChatMessage>? _messages;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final got = await widget.load(widget.hit.token, widget.hit.messageId);
      if (!mounted) return;
      setState(
        () => _messages = got.where((m) => !m.isHidden && m.id > 0).toList()
          ..sort((a, b) => a.id.compareTo(b.id)),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _found.currentContext;
        if (target != null && target.mounted) {
          Scrollable.ensureVisible(target, alignment: 0.4);
        }
      });
    } catch (e) {
      log('search: loading a message failed: '
          '${e is ApiException ? e.status : e.runtimeType}');
      if (!mounted) return;
      setState(
        () => _error = e is ApiException && e.status == 404
            ? 'This message isn\'t available any more.'
            : 'Couldn\'t load this message.',
      );
    }
  }

  Widget _body(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    final messages = _messages;
    if (messages == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final highlight = Theme.of(context).colorScheme.secondaryContainer;
    return SingleChildScrollView(
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, m) in messages.indexed) ...[
              if (i == 0 || !DateUtils.isSameDay(messages[i - 1].time, m.time))
                FullDateDivider(m.time),
              m.id == widget.hit.messageId
                  ? DecoratedBox(
                      key: _found,
                      decoration: BoxDecoration(
                        color: highlight,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _row(m),
                    )
                  : _row(m),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(ChatMessage m) => ReadOnlyMessage(
    message: m,
    own: m.actorType == 'users' && m.actorId == widget.selfId,
    avatars: widget.avatars,
    preview: (id) => _previews[id] ??= widget.preview(id),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.hit.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
    content: SizedBox(width: 620, height: 520, child: _body(context)),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Back'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Open conversation'),
      ),
    ],
  );
}
