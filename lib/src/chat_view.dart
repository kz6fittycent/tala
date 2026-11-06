import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat.dart';
import 'log.dart';
import 'nc_api.dart';

/// Below this the two panes don't both fit, so one shows at a time. Larger
/// text never hides the conversation list while there's room for it.
const _twoPaneWidth = 720.0;
const _listWidth = 320.0;

/// Only http and https ever reach here, and arguments never pass a shell.
Future<void> openExternal(String url) async {
  if (safeUrl(url) == null) return;
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  } catch (e) {
    log('opening a link failed: $e');
  }
}

class ChatLayout extends StatelessWidget {
  const ChatLayout({
    super.key,
    required this.rooms,
    required this.roomsError,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
    required this.conversation,
  });

  final List<Room>? rooms;
  final Object? roomsError;
  final Room? selected;
  final ValueChanged<String?> onSelect;
  final VoidCallback onRefresh;
  final Widget? conversation;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final list = RoomList(
            rooms: rooms,
            error: roomsError,
            selected: selected?.token,
            onSelect: onSelect,
            onRefresh: onRefresh,
          );
          if (box.maxWidth < _twoPaneWidth) {
            return conversation ?? list;
          }
          return Row(children: [
            SizedBox(width: _listWidth, child: list),
            const VerticalDivider(width: 1),
            Expanded(
              child: conversation ??
                  const Center(child: Text('Choose a conversation')),
            ),
          ]);
        },
      );
}

class RoomList extends StatelessWidget {
  const RoomList({
    super.key,
    required this.rooms,
    required this.error,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
  });

  final List<Room>? rooms;
  final Object? error;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final items = rooms;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(children: [
          Expanded(
            child: Text('Conversations',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: onRefresh),
        ]),
      ),
      if (error != null && items != null)
        const _Banner('Can\'t reach the server. Retrying…'),
      Expanded(
        child: items == null
            ? Center(
                child: error != null
                    ? Text('$error')
                    : const CircularProgressIndicator())
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) => _RoomTile(
                  room: items[i],
                  selected: items[i].token == selected,
                  onTap: () => onSelect(items[i].token),
                ),
              ),
      ),
    ]);
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile(
      {required this.room, required this.selected, required this.onTap});
  final Room room;
  final bool selected;
  final VoidCallback onTap;

  String get _preview {
    final m = room.lastMessage;
    if (m == null) return '';
    final text = m.text.replaceAll('\n', ' ');
    return m.isSystem || m.actorName.isEmpty || m.actorId == room.selfId
        ? text
        : '${m.actorName}: $text';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = room.unread > 0;
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer,
      leading: _Initial(room.name),
      title: Text(room.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: unread ? const TextStyle(fontWeight: FontWeight.bold) : null),
      subtitle: Text(_preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (room.hasCall)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(Icons.call,
                size: 18,
                color: scheme.primary,
                semanticLabel: 'Call in progress'),
          ),
        if (unread)
          Badge(
            label: Text('${room.unread}'),
            backgroundColor:
                room.unreadMention ? scheme.error : scheme.primary,
            textColor:
                room.unreadMention ? scheme.onError : scheme.onPrimary,
          ),
      ]),
      onTap: onTap,
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CircleAvatar(
          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase()),
        ),
      );
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }
}

class ConversationPane extends StatefulWidget {
  const ConversationPane({
    super.key,
    required this.source,
    required this.room,
    required this.drafts,
    required this.onBack,
    required this.onCall,
  });

  final ChatSource source;
  final Room room;

  /// Unsent text by conversation, so switching away doesn't lose it.
  final Map<String, String> drafts;
  final VoidCallback onBack;
  final VoidCallback onCall;

  @override
  State<ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends State<ConversationPane> {
  late final ChatThread _thread = ChatThread(widget.source, widget.room.token,
      lastRead: widget.room.lastRead);
  late final AppLifecycleListener _lifecycle;

  /// Fixed when the conversation opens, so the divider stays put as it's read.
  late final int _lastReadAtOpen = widget.room.lastRead;
  late final bool _hadUnread = widget.room.unread > 0;
  late final TextEditingController _input =
      TextEditingController(text: widget.drafts[widget.room.token] ?? '');
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    final state = WidgetsBinding.instance.lifecycleState;
    _thread
      ..active = state == null || state == AppLifecycleState.resumed
      ..start();
    _scroll.addListener(_onScroll);
    _input.addListener(
        () => widget.drafts[widget.room.token] = _input.text);
  }

  void _onLifecycle(AppLifecycleState state) =>
      _thread.active = state == AppLifecycleState.resumed;

  /// The list is reversed, so its far end is the oldest message.
  void _onScroll() {
    if (_scroll.position.extentAfter < 400) _thread.loadOlder();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    _thread.send(text);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _inputFocus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        HardwareKeyboard.instance.isShiftPressed ||
        // An input method is still composing; Enter belongs to it.
        _input.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    _send();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _thread.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final twoPane = MediaQuery.sizeOf(context).width >= _twoPaneWidth;
    return ListenableBuilder(
      listenable: _thread,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                if (!twoPane)
                  IconButton(
                      tooltip: 'Back to conversations',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: widget.onBack),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(room.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (room.canCall)
                  room.hasCall
                      ? FilledButton.icon(
                          icon: const Icon(Icons.call),
                          label: const Text('Join call'),
                          onPressed: widget.onCall)
                      : IconButton(
                          tooltip: 'Start a call',
                          icon: const Icon(Icons.call),
                          onPressed: widget.onCall),
              ]),
            ),
          ),
          if (_thread.problem != null) _Banner(_thread.problem!),
          Expanded(child: _body(context)),
          if (room.canChat && !_thread.gone)
            _Composer(
              controller: _input,
              focus: _inputFocus,
              onKey: _onKey,
              onSend: _send,
            )
          else if (!room.canChat)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('You can\'t send messages here.',
                  textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_thread.gone) {
      return const Center(child: Text('This conversation isn\'t available.'));
    }
    if (_thread.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final rows = _buildRows(context);
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: rows.length,
        itemBuilder: (context, i) => rows[i],
      ),
    );
  }

  /// Newest first, because the list is reversed to start at the bottom.
  List<Widget> _buildRows(BuildContext context) {
    final out = <Widget>[];
    for (final o in _thread.outgoing.reversed) {
      out.add(_OutgoingBubble(
        message: o,
        onRetry: () => _thread.retry(o),
        onDiscard: () => _thread.discard(o),
      ));
    }
    final messages = _thread.messages;
    final selfId = widget.room.selfId;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      final prev = i > 0 ? messages[i - 1] : null;
      final sameDay = prev != null && DateUtils.isSameDay(prev.time, m.time);
      final grouped = sameDay &&
          !prev.isSystem &&
          !m.isSystem &&
          prev.actorType == m.actorType &&
          prev.actorId == m.actorId &&
          m.timestamp - prev.timestamp < 300;
      out.add(m.isSystem
          ? _SystemRow(m)
          : _MessageBubble(
              message: m,
              own: m.actorType == 'users' && m.actorId == selfId,
              showName: !grouped,
            ));
      final firstUnread = _hadUnread &&
          m.id > _lastReadAtOpen &&
          (prev == null || prev.id <= _lastReadAtOpen);
      if (firstUnread) out.add(const _Divider('New messages'));
      if (!sameDay) {
        out.add(_Divider(
            MaterialLocalizations.of(context).formatMediumDate(m.time)));
      }
    }
    if (_thread.loadingOlder) {
      out.add(const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator()),
      ));
    }
    return out;
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.onKey,
    required this.onSend,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final FocusOnKeyEventCallback onKey;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Focus(
              onKeyEvent: onKey,
              skipTraversal: true,
              child: TextField(
                controller: controller,
                focusNode: focus,
                autofocus: true,
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Write a message',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
              tooltip: 'Send',
              icon: const Icon(Icons.send),
              onPressed: onSend),
        ]),
      );
}

class _Divider extends StatelessWidget {
  const _Divider(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(text, style: Theme.of(context).textTheme.labelMedium),
          ),
          const Expanded(child: Divider()),
        ]),
      );
}

class _SystemRow extends StatelessWidget {
  const _SystemRow(this.message);
  final ChatMessage message;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Text(message.text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.own, required this.child});
  final bool own;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Align(
        alignment: own ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: own
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble(
      {required this.message, required this.own, required this.showName});
  final ChatMessage message;
  final bool own;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(message.time),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
    final parent = message.parent;
    return _Bubble(
      own: own,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showName && !own)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
                message.actorName.isEmpty ? 'Guest' : message.actorName,
                style: small?.copyWith(fontWeight: FontWeight.bold)),
          ),
        if (parent != null && !message.isDeleted)
          _Quote(parent: parent, deleted: message.parentDeleted),
        _MessageText(message.segments, italic: message.isDeleted),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(message.edited ? '$time · edited' : time, style: small),
        ),
      ]),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote({required this.parent, required this.deleted});
  final ChatMessage parent;
  final bool deleted;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border:
            Border(left: BorderSide(color: theme.colorScheme.primary, width: 3)),
      ),
      child: Text(
        deleted ? 'Deleted message' : '${parent.actorName}: ${parent.text}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

/// Stateful only to dispose the tap handlers on its links.
class _MessageText extends StatefulWidget {
  const _MessageText(this.segments, {this.italic = false});
  final List<Segment> segments;
  final bool italic;
  @override
  State<_MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<_MessageText> {
  final List<TapGestureRecognizer> _taps = [];

  void _clearTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clearTaps();
    super.dispose();
  }

  InlineSpan _span(Segment s, ThemeData theme) {
    final scheme = theme.colorScheme;
    TapGestureRecognizer? tap;
    if (s.url != null) {
      tap = TapGestureRecognizer()..onTap = () => openExternal(s.url!);
      _taps.add(tap);
    }
    final link = TextStyle(
        color: scheme.primary, decoration: TextDecoration.underline);
    final mouse = tap != null ? SystemMouseCursors.click : MouseCursor.defer;
    return switch (s.kind) {
      SegmentKind.text => TextSpan(text: s.text),
      SegmentKind.mention => TextSpan(
          text: '@${s.text}',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      SegmentKind.file => TextSpan(
          text: '📎 ${s.text}',
          style: tap != null ? link : null,
          recognizer: tap,
          mouseCursor: mouse),
      SegmentKind.link => TextSpan(
          text: s.text, style: link, recognizer: tap, mouseCursor: mouse),
    };
  }

  @override
  Widget build(BuildContext context) {
    _clearTaps();
    final theme = Theme.of(context);
    return Text.rich(TextSpan(
      style: widget.italic ? const TextStyle(fontStyle: FontStyle.italic) : null,
      children: [for (final s in widget.segments) _span(s, theme)],
    ));
  }
}

class _OutgoingBubble extends StatelessWidget {
  const _OutgoingBubble(
      {required this.message, required this.onRetry, required this.onDiscard});
  final OutgoingMessage message;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = message.state == SendState.failed;
    return _Bubble(
      own: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(message.text),
        if (!failed)
          Text('Sending…', style: theme.textTheme.bodySmall)
        else
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(message.error ?? 'Not sent',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
            TextButton(onPressed: onDiscard, child: const Text('Discard')),
          ]),
      ]),
    );
  }
}
