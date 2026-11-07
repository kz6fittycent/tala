import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'chat.dart';
import 'log.dart';
import 'nc_api.dart';
import 'settings.dart';

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
    required this.onRemove,
    required this.onArchive,
    required this.settings,
    required this.conversation,
    this.menu,
    this.banner,
    this.onNewConversation,
    this.onGuestLink,
    this.onDelete,
    this.onMembers,
    this.onRename,
  });

  final List<Room>? rooms;
  final Object? roomsError;
  final Room? selected;
  final ValueChanged<String?> onSelect;
  final VoidCallback onRefresh;
  final ValueChanged<Room> onRemove;
  final ValueChanged<Room> onArchive;
  final AppSettings settings;
  final Widget? conversation;
  final Widget? menu;
  final Widget? banner;
  final VoidCallback? onNewConversation;
  final ValueChanged<Room>? onGuestLink;
  final ValueChanged<Room>? onDelete;
  final ValueChanged<Room>? onMembers;
  final ValueChanged<Room>? onRename;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final list = RoomList(
        rooms: rooms,
        error: roomsError,
        selected: selected?.token,
        onSelect: onSelect,
        onRefresh: onRefresh,
        onRemove: onRemove,
        onArchive: onArchive,
        settings: settings,
        menu: menu,
        banner: banner,
        onNewConversation: onNewConversation,
        onGuestLink: onGuestLink,
        onDelete: onDelete,
        onMembers: onMembers,
        onRename: onRename,
      );
      if (box.maxWidth < _twoPaneWidth) {
        return conversation ?? list;
      }
      return Row(
        children: [
          SizedBox(width: _listWidth, child: list),
          const VerticalDivider(width: 1),
          Expanded(
            child:
                conversation ??
                const Center(child: Text('Choose a conversation')),
          ),
        ],
      );
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
    required this.onRemove,
    required this.onArchive,
    required this.settings,
    this.menu,
    this.banner,
    this.onNewConversation,
    this.onGuestLink,
    this.onDelete,
    this.onMembers,
    this.onRename,
  });

  final List<Room>? rooms;
  final Object? error;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final VoidCallback onRefresh;
  final ValueChanged<Room> onRemove;
  final ValueChanged<Room> onArchive;
  final AppSettings settings;
  final Widget? menu;
  final Widget? banner;
  final VoidCallback? onNewConversation;
  final ValueChanged<Room>? onGuestLink;
  final ValueChanged<Room>? onDelete;
  final ValueChanged<Room>? onMembers;
  final ValueChanged<Room>? onRename;

  Widget _tile(Room room) => _RoomTile(
    room: room,
    selected: room.token == selected,
    onTap: () => onSelect(room.token),
    onRemove: () => onRemove(room),
    onArchive: () => onArchive(room),
    onGuestLink: onGuestLink == null ? null : () => onGuestLink!(room),
    onDelete: onDelete == null ? null : () => onDelete!(room),
    onMembers: onMembers == null ? null : () => onMembers!(room),
    onRename: onRename == null ? null : () => onRename!(room),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final items = rooms;
    final active = [...?items?.where((r) => !r.archived)];
    final archived = [...?items?.where((r) => r.archived)];
    final showArchived = archived.isNotEmpty && !settings.hideArchived;
    final archivedOpen = showArchived && settings.archivedOpen;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Conversations',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: onRefresh,
              ),
              ?menu,
            ],
          ),
        ),
        if (onNewConversation != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('New conversation'),
              onPressed: onNewConversation,
            ),
          ),
        ?banner,
        if (error != null && items != null)
          const _Banner('Can\'t reach the server. Retrying…'),
        Expanded(
          child: items == null
              ? Center(
                  child: error != null
                      ? Text('$error')
                      : const CircularProgressIndicator(),
                )
              : ListView.builder(
                  itemCount:
                      active.length +
                      (showArchived ? 1 : 0) +
                      (archivedOpen ? archived.length : 0),
                  itemBuilder: (context, i) {
                    if (i < active.length) return _tile(active[i]);
                    if (i == active.length) {
                      return _ArchivedHeader(
                        rooms: archived,
                        open: archivedOpen,
                        onTap: () =>
                            settings.archivedOpen = !settings.archivedOpen,
                      );
                    }
                    return _tile(archived[i - active.length - 1]);
                  },
                ),
        ),
      ],
    );
  }
}

class _ArchivedHeader extends StatelessWidget {
  const _ArchivedHeader({
    required this.rooms,
    required this.open,
    required this.onTap,
  });
  final List<Room> rooms;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = rooms.fold(0, (sum, r) => sum + r.unread);
    final mention = rooms.any((r) => r.unreadMention);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.archive_outlined),
      title: Text('Archived (${rooms.length})'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unread > 0)
            Badge(
              label: Text('$unread'),
              backgroundColor: mention ? scheme.error : scheme.primary,
              textColor: mention ? scheme.onError : scheme.onPrimary,
            ),
          const SizedBox(width: 6),
          Icon(open ? Icons.expand_less : Icons.expand_more),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({
    required this.room,
    required this.selected,
    required this.onTap,
    required this.onRemove,
    required this.onArchive,
    this.onGuestLink,
    this.onDelete,
    this.onMembers,
    this.onRename,
  });
  final Room room;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onArchive;
  final VoidCallback? onGuestLink;
  final VoidCallback? onDelete;
  final VoidCallback? onMembers;
  final VoidCallback? onRename;

  Future<void> _menu(BuildContext context, Offset at) async {
    final choice = await _showMenuAt<String>(context, at, [
      if (room.hasMembers && onMembers != null)
        const PopupMenuItem(value: 'members', child: Text('Members…')),
      if (room.canManage && onRename != null)
        const PopupMenuItem(value: 'rename', child: Text('Rename…')),
      if (room.hasGuestLink && onGuestLink != null)
        const PopupMenuItem(value: 'link', child: Text('Guest link…')),
      if (room.canArchive)
        PopupMenuItem(
          value: 'archive',
          child: Text(room.archived ? 'Unarchive' : 'Archive'),
        ),
      PopupMenuItem(
        value: 'remove',
        enabled: room.canLeave,
        child: Text(
          room.canLeave
              ? 'Remove chat…'
              : 'Remove chat (you\'re the only moderator)',
        ),
      ),
      if (room.offersDelete && onDelete != null)
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete for everyone…'),
        ),
    ]);
    if (choice == 'members') onMembers?.call();
    if (choice == 'rename') onRename?.call();
    if (choice == 'remove') onRemove();
    if (choice == 'archive') onArchive();
    if (choice == 'link') onGuestLink?.call();
    if (choice == 'delete') onDelete?.call();
  }

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
    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
      child: ListTile(
        selected: selected,
        selectedTileColor: scheme.secondaryContainer,
        leading: _Initial(room.name),
        title: Text(
          room.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: unread ? const TextStyle(fontWeight: FontWeight.bold) : null,
        ),
        subtitle: Text(_preview, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (room.isFederated)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Tooltip(
                  message: 'Hosted on ${_hostOf(room.remoteServer)}',
                  child: Icon(Icons.public, size: 16, color: scheme.outline),
                ),
              ),
            if (room.hasGuestLink)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Tooltip(
                  message: 'Guests can join with a link',
                  child: Icon(Icons.link, size: 16, color: scheme.outline),
                ),
              ),
            if (room.hasCall)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.call,
                  size: 18,
                  color: scheme.primary,
                  semanticLabel: 'Call in progress',
                ),
              ),
            if (unread)
              Badge(
                label: Text('${room.unread}'),
                backgroundColor: room.unreadMention
                    ? scheme.error
                    : scheme.primary,
                textColor: room.unreadMention
                    ? scheme.onError
                    : scheme.onPrimary,
              ),
            Builder(
              builder: (context) => IconButton(
                tooltip: 'Conversation options',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_vert),
                onPressed: () => _menu(context, _centerOf(context)),
              ),
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

String _hostOf(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isEmpty ? url : host;
}

/// Invitations to conversations on other servers, above the list.
class InviteBanners extends StatelessWidget {
  const InviteBanners({
    super.key,
    required this.invites,
    required this.onAccept,
    required this.onDecline,
  });

  final List<FederationInvite> invites;
  final ValueChanged<FederationInvite> onAccept;
  final ValueChanged<FederationInvite> onDecline;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final invite in invites)
        Card(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  invite.roomName,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Invited by ${invite.inviter} on ${_hostOf(invite.server)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => onDecline(invite),
                      child: const Text('Decline'),
                    ),
                    TextButton(
                      onPressed: () => onAccept(invite),
                      child: const Text('Accept'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

Future<T?> _showMenuAt<T>(
  BuildContext context,
  Offset at,
  List<PopupMenuEntry<T>> items,
) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
    items: items,
  );
}

Offset _centerOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(box.size.center(Offset.zero));
}

class _Initial extends StatelessWidget {
  const _Initial(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CircleAvatar(
      backgroundColor:
          Theme.of(context).extension<AvatarColors>()?.background ?? talaBlue,
      foregroundColor: Colors.white,
      // White on the icon's blue is 4.17:1, which needs large, bold text.
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
      ),
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
    this.onMembers,
    this.showHeader = true,
  });

  final ChatSource source;
  final Room room;

  /// Unsent text by conversation, so switching away doesn't lose it.
  final Map<String, String> drafts;
  final VoidCallback onBack;
  final VoidCallback onCall;
  final VoidCallback? onMembers;

  /// Off inside a call, which already has the name and the controls.
  final bool showHeader;

  @override
  State<ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends State<ConversationPane> {
  late final ChatThread _thread = ChatThread(
    widget.source,
    widget.room.token,
    lastRead: widget.room.lastRead,
  );
  late final AppLifecycleListener _lifecycle;

  /// Fixed when the conversation opens, so the divider stays put as it's read.
  late final int _lastReadAtOpen = widget.room.lastRead;
  late final bool _hadUnread = widget.room.unread > 0;
  late final TextEditingController _input = TextEditingController(
    text: widget.drafts[widget.room.token] ?? '',
  );
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final Map<int, Future<Uint8List>> _previews = {};
  ChatMessage? _replyTo;
  bool _canUpload = false;
  ChatMessage? _editing;

  /// What was in the composer before editing began, put back afterward.
  String _draftBeforeEdit = '';

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    final state = WidgetsBinding.instance.lifecycleState;
    _thread
      ..active = state == null || state == AppLifecycleState.resumed
      ..start();
    _scroll.addListener(_onScroll);
    _input.addListener(() {
      if (_editing == null) widget.drafts[widget.room.token] = _input.text;
    });
    widget.source.chatUploadsAllowed().then((allowed) {
      // Talk has no attachments in federated conversations.
      if (mounted) {
        setState(() => _canUpload = allowed && !widget.room.isFederated);
      }
    }, onError: (Object e) => log('chat: attachment settings: $e'));
  }

  void _startReply(ChatMessage m) {
    if (_editing != null) _endEdit();
    setState(() => _replyTo = m);
    _inputFocus.requestFocus();
  }

  void _startEdit(ChatMessage m) {
    if (_editing == null) _draftBeforeEdit = _input.text;
    setState(() {
      _replyTo = null;
      _editing = m;
    });
    _input.text = m.editSource;
    _inputFocus.requestFocus();
  }

  void _endEdit() {
    setState(() => _editing = null);
    _input.text = _draftBeforeEdit;
  }

  void _notify(String message) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _saveEdit(ChatMessage m) async {
    final error = await _thread.editMessage(m.id, _input.text);
    if (!mounted) return;
    if (error != null) {
      // The text stays in the composer, so nothing typed is lost.
      _notify(error);
    } else if (identical(_editing, m)) {
      _endEdit();
    }
  }

  Future<void> _confirmDelete(ChatMessage m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this message?'),
        content: const Text(
          'It will be removed for everyone in this '
          'conversation. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await _thread.deleteMessage(m.id);
    if (!mounted) return;
    if (error != null) {
      _notify(error);
    } else if (_editing?.id == m.id) {
      _endEdit();
    }
  }

  Future<void> _react(ChatMessage m, String emoji) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!await _thread.toggleReaction(m.id, emoji)) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Couldn\'t update that reaction')),
      );
    }
  }

  Future<void> _attach() async {
    final files = await openFiles();
    for (final f in files) {
      await _thread.sendFile(f.path);
    }
  }

  void _onLifecycle(AppLifecycleState state) =>
      _thread.active = state == AppLifecycleState.resumed;

  /// The list is reversed, so its far end is the oldest message.
  void _onScroll() {
    if (_scroll.position.extentAfter < 400) _thread.loadOlder();
  }

  void _send() {
    final editing = _editing;
    if (editing != null) {
      _saveEdit(editing);
      return;
    }
    final text = _input.text;
    if (text.trim().isEmpty) return;
    final reply = _replyTo;
    _input.clear();
    if (reply != null) setState(() => _replyTo = null);
    _thread.send(text, replyTo: reply?.id);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _inputFocus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_editing != null) {
        _endEdit();
        return KeyEventResult.handled;
      }
      if (_replyTo != null) {
        setState(() => _replyTo = null);
        return KeyEventResult.handled;
      }
    }
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
          if (widget.showHeader) ...[
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                if (!twoPane)
                  IconButton(
                    tooltip: 'Back to conversations',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: widget.onBack,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (room.hasMembers && widget.onMembers != null)
                  IconButton(
                    tooltip: 'Members',
                    icon: const Icon(Icons.group_outlined),
                    onPressed: widget.onMembers,
                  ),
                if (room.canCall)
                  room.hasCall
                      ? FilledButton.icon(
                          icon: const Icon(Icons.call),
                          label: const Text('Join call'),
                          onPressed: widget.onCall,
                        )
                      : IconButton(
                          tooltip: 'Start a call',
                          icon: const Icon(Icons.call),
                          onPressed: widget.onCall,
                        ),
              ],
            ),
          ),
          const Divider(height: 1),
          ],
          if (_thread.problem != null) _Banner(_thread.problem!),
          Expanded(child: _body(context)),
          if (room.canChat && !_thread.gone) ...[
            if (_editing != null)
              _ComposerBar(
                text: 'Editing your message',
                cancelLabel: 'Cancel edit',
                onCancel: _endEdit,
              )
            else if (_replyTo != null)
              _ComposerBar(
                text: 'Replying to ${_replyTo!.actorName}: ${_replyTo!.text}',
                cancelLabel: 'Cancel reply',
                onCancel: () => setState(() => _replyTo = null),
              ),
            _Composer(
              controller: _input,
              focus: _inputFocus,
              onKey: _onKey,
              onSend: _send,
              onAttach: _canUpload && _editing == null ? _attach : null,
            ),
          ] else if (!room.canChat)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'You can\'t send messages here.',
                textAlign: TextAlign.center,
              ),
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
      out.add(
        _OutgoingBubble(
          message: o,
          onRetry: () => _thread.retry(o),
          onDiscard: () => _thread.discard(o),
        ),
      );
    }
    final messages = _thread.messages;
    final selfId = widget.room.selfId;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      final prev = i > 0 ? messages[i - 1] : null;
      final sameDay = prev != null && DateUtils.isSameDay(prev.time, m.time);
      final grouped =
          sameDay &&
          !prev.isSystem &&
          !m.isSystem &&
          prev.actorType == m.actorType &&
          prev.actorId == m.actorId &&
          m.timestamp - prev.timestamp < 300;
      out.add(
        m.isSystem
            ? _SystemRow(m)
            : _MessageBubble(
                message: m,
                own: m.actorType == 'users' && m.actorId == selfId,
                showName: !grouped,
                canInteract: widget.room.canChat,
                onReply: () => _startReply(m),
                onReact: (emoji) => _react(m, emoji),
                onEdit: () => _startEdit(m),
                onDelete: () => _confirmDelete(m),
                canModerate: widget.room.isModerator,
                preview: (id) =>
                    _previews[id] ??= widget.source.chatPreview(id),
              ),
      );
      final firstUnread =
          _hadUnread &&
          m.id > _lastReadAtOpen &&
          (prev == null || prev.id <= _lastReadAtOpen);
      if (firstUnread) out.add(const _Divider('New messages'));
      if (!sameDay) {
        out.add(
          _Divider(MaterialLocalizations.of(context).formatMediumDate(m.time)),
        );
      }
    }
    if (_thread.loadingOlder) {
      out.add(
        const Padding(
          padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
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
    required this.onAttach,
  });
  final VoidCallback? onAttach;
  final TextEditingController controller;
  final FocusNode focus;
  final FocusOnKeyEventCallback onKey;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (onAttach != null) ...[
          IconButton(
            tooltip: 'Attach files',
            icon: const Icon(Icons.attach_file),
            onPressed: onAttach,
          ),
          const SizedBox(width: 4),
        ],
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
          onPressed: onSend,
        ),
      ],
    ),
  );
}

class _Divider extends StatelessWidget {
  const _Divider(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(text, style: Theme.of(context).textTheme.labelMedium),
        ),
        const Expanded(child: Divider()),
      ],
    ),
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
      child: Text(
        message.text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.text,
    required this.cancelLabel,
    required this.onCancel,
  });
  final String text;
  final String cancelLabel;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.only(left: 16, right: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: cancelLabel,
            icon: const Icon(Icons.close),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.own, required this.child, this.actions});
  final bool own;
  final Widget child;
  final Widget? actions;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubble = Flexible(
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
    );
    final side = actions;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        mainAxisAlignment: own
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (own && side != null) side,
          bubble,
          if (!own && side != null) side,
        ],
      ),
    );
  }
}

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🎉'];

/// Shows while the pointer is over the message or a button here has keyboard
/// focus, and always holds its space so messages don't shift.
class _MessageActions extends StatefulWidget {
  const _MessageActions({
    required this.visible,
    required this.onReply,
    required this.onReact,
    required this.onMore,
  });
  final bool visible;
  final VoidCallback? onReply;
  final ValueChanged<String>? onReact;
  final ValueChanged<Offset> onMore;
  @override
  State<_MessageActions> createState() => _MessageActionsState();
}

class _MessageActionsState extends State<_MessageActions> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (f) => setState(() => _focused = f),
    child: Opacity(
      opacity: widget.visible || _focused ? 1 : 0,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.onReply != null)
            IconButton(
              tooltip: 'Reply',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.reply),
              onPressed: widget.onReply,
            ),
          if (widget.onReact != null)
            PopupMenuButton<String>(
              tooltip: 'Add a reaction',
              iconSize: 18,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.add_reaction_outlined),
              onSelected: widget.onReact,
              itemBuilder: (context) => [
                for (final e in _quickReactions)
                  PopupMenuItem(value: e, child: Text(e)),
              ],
            ),
          // The same menu as right-click, reachable from the keyboard.
          Builder(
            builder: (context) => IconButton(
              tooltip: 'More actions',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.more_horiz),
              onPressed: () => widget.onMore(_centerOf(context)),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Reactions extends StatelessWidget {
  const _Reactions({required this.message, required this.onReact});
  final ChatMessage message;
  final ValueChanged<String>? onReact;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final e in message.reactions.entries)
            ActionChip(
              label: Text('${e.key} ${e.value}'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              tooltip: message.reactionsSelf.contains(e.key)
                  ? 'Remove your reaction'
                  : 'Add this reaction',
              backgroundColor: message.reactionsSelf.contains(e.key)
                  ? scheme.secondaryContainer
                  : null,
              onPressed: onReact == null ? null : () => onReact!(e.key),
            ),
        ],
      ),
    );
  }
}

/// A fixed size, so messages above don't shift when the image arrives.
class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.segment, required this.bytes});
  final Segment segment;
  final Future<Uint8List> bytes;
  @override
  Widget build(BuildContext context) {
    final url = segment.url;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: FutureBuilder<Uint8List>(
        future: bytes,
        builder: (context, snap) {
          if (snap.hasError) return const SizedBox.shrink();
          final data = snap.data;
          // Narrower than this only inside a call's side panel.
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: AspectRatio(
              aspectRatio: 3 / 2,
              child: data == null
                ? const Center(child: CircularProgressIndicator())
                : MouseRegion(
                    cursor: url != null
                        ? SystemMouseCursors.click
                        : MouseCursor.defer,
                    child: GestureDetector(
                      onTap: url == null ? null : () => openExternal(url),
                      child: Image.memory(
                        data,
                        // Bounds the memory a huge image can take once decoded.
                        cacheWidth: 960,
                        fit: BoxFit.contain,
                        semanticLabel: segment.text,
                        errorBuilder: (context, _, _) =>
                            const SizedBox.shrink(),
                      ),
                    ),
                  ),
            ),
          );
        },
      ),
    );
  }
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.message,
    required this.own,
    required this.showName,
    required this.canInteract,
    required this.onReply,
    required this.onReact,
    required this.onEdit,
    required this.onDelete,
    required this.canModerate,
    required this.preview,
  });
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool canModerate;
  final ChatMessage message;
  final bool own;
  final bool showName;
  final bool canInteract;
  final VoidCallback onReply;
  final ValueChanged<String> onReact;
  final Future<Uint8List> Function(int fileId) preview;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  bool _hover = false;

  Future<void> _menu(Offset at) async {
    final message = widget.message;
    final canReply = widget.canInteract && message.isReplyable;
    final canEdit = widget.canInteract && widget.own && message.canEdit;
    final canDelete =
        widget.canInteract &&
        message.canDelete &&
        (widget.own || widget.canModerate);
    final text = message.text;
    final choice = await _showMenuAt<String>(context, at, [
      if (canReply) const PopupMenuItem(value: 'reply', child: Text('Reply')),
      if (text.isNotEmpty)
        const PopupMenuItem(value: 'copy', child: Text('Copy text')),
      if (canEdit) const PopupMenuItem(value: 'edit', child: Text('Edit')),
      if (canDelete)
        const PopupMenuItem(value: 'delete', child: Text('Delete…')),
    ]);
    switch (choice) {
      case 'reply':
        widget.onReply();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: text));
      case 'edit':
        widget.onEdit();
      case 'delete':
        widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(message.time),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final parent = message.parent;
    final canReply = widget.canInteract && message.isReplyable;
    final canReact = widget.canInteract && message.canReact;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTapUp: (d) => _menu(d.globalPosition),
        child: _Bubble(
          own: widget.own,
          actions: _MessageActions(
            visible: _hover,
            onReply: canReply ? widget.onReply : null,
            onReact: canReact ? widget.onReact : null,
            onMore: _menu,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showName && !widget.own)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    message.actorName.isEmpty ? 'Guest' : message.actorName,
                    style: small?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              if (parent != null && !message.isDeleted)
                _Quote(parent: parent, deleted: message.parentDeleted),
              for (final s in message.segments)
                if (s.previewFileId != null)
                  _ImagePreview(
                    segment: s,
                    bytes: widget.preview(s.previewFileId!),
                  ),
              _MessageText(message.segments, italic: message.isDeleted),
              if (message.reactions.isNotEmpty)
                _Reactions(
                  message: message,
                  onReact: widget.canInteract ? widget.onReact : null,
                ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  message.edited ? '$time · edited' : time,
                  style: small,
                ),
              ),
            ],
          ),
        ),
      ),
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
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
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
      color: scheme.primary,
      decoration: TextDecoration.underline,
    );
    final mouse = tap != null ? SystemMouseCursors.click : MouseCursor.defer;
    return switch (s.kind) {
      SegmentKind.text => TextSpan(text: s.text),
      SegmentKind.mention => TextSpan(
        text: '@${s.text}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      SegmentKind.file => TextSpan(
        text: '📎 ${s.text}',
        style: tap != null ? link : null,
        recognizer: tap,
        mouseCursor: mouse,
      ),
      SegmentKind.link => TextSpan(
        text: s.text,
        style: link,
        recognizer: tap,
        mouseCursor: mouse,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    _clearTaps();
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        style: widget.italic
            ? const TextStyle(fontStyle: FontStyle.italic)
            : null,
        children: [for (final s in widget.segments) _span(s, theme)],
      ),
    );
  }
}

class _OutgoingBubble extends StatelessWidget {
  const _OutgoingBubble({
    required this.message,
    required this.onRetry,
    required this.onDiscard,
  });
  final OutgoingMessage message;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = message.state == SendState.failed;
    return _Bubble(
      own: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(message.filePath != null ? '📎 ${message.text}' : message.text),
          if (!failed)
            Text(
              message.filePath != null ? 'Uploading…' : 'Sending…',
              style: theme.textTheme.bodySmall,
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.error ?? 'Not sent',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
                TextButton(onPressed: onDiscard, child: const Text('Discard')),
              ],
            ),
        ],
      ),
    );
  }
}
