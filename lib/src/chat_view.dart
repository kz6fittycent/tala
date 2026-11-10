import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'avatars.dart';
import 'chat.dart';
import 'drafts.dart';
import 'emoji_picker.dart';
import 'file_drop.dart';
import 'log.dart';
import 'markdown.dart';
import 'mentions.dart';
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
    this.onSearch,
    this.avatars,
  });

  final VoidCallback? onSearch;
  final AvatarStore? avatars;
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
        onSearch: onSearch,
        avatars: avatars,
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
    this.onSearch,
    this.avatars,
  });

  final VoidCallback? onSearch;
  final AvatarStore? avatars;
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
    avatars: avatars,
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
              if (onSearch != null)
                IconButton(
                  tooltip: 'Search messages',
                  icon: const Icon(Icons.search),
                  onPressed: onSearch,
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
    this.avatars,
  });
  final AvatarStore? avatars;
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
        leading: Avatar(name: room.name, image: avatars?.forRoom(room)),
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
    this.onSearch,
    this.avatars,
    this.showHeader = true,
  });

  final ChatSource source;
  final Room room;

  /// Unsent text by conversation, so switching away or restarting doesn't
  /// lose it.
  final DraftStore drafts;
  final VoidCallback onBack;
  final VoidCallback onCall;
  final VoidCallback? onMembers;
  final VoidCallback? onSearch;
  final AvatarStore? avatars;

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

  /// Kept with the draft holding these names.
  PickedMentions get _picked => widget.drafts.picked(widget.room.token);
  MentionQuery? _mention;
  List<MentionOption> _mentionOptions = const [];
  int _mentionHighlight = 0;
  int _mentionSearch = 0;
  int? _mentionDismissedAt;
  Timer? _mentionTimer;

  /// Keeps up with the text and the cursor. Results only show if they're for
  /// the newest search.
  void _updateMention() {
    final found = mentionQueryAt(_input.text, _input.selection);
    final dismissed = found != null && found.start == _mentionDismissedAt;
    final query = dismissed ? null : found;
    if (found == null) _mentionDismissedAt = null;
    if (query?.start == _mention?.start && query?.text == _mention?.text) {
      return;
    }
    _mention = query;
    _mentionTimer?.cancel();
    final search = ++_mentionSearch;
    if (query == null) {
      if (_mentionOptions.isNotEmpty) {
        setState(() => _mentionOptions = const []);
      }
      return;
    }
    _mentionTimer = Timer(
      const Duration(milliseconds: 200),
      () => _searchMentions(query.text, search),
    );
  }

  Future<void> _searchMentions(String text, int search) async {
    try {
      final options = await widget.source.chatMentions(widget.room.token, text);
      if (!mounted || search != _mentionSearch) return;
      setState(() {
        _mentionOptions = [
          for (final o in options)
            if (o.source != 'users' || o.id != widget.room.selfId) o,
        ].take(5).toList();
        _mentionHighlight = 0;
      });
    } catch (e) {
      // Not the error itself: its address holds what was typed, maybe a name.
      log('chat: mention search failed: ${e is ApiException ? e.status : e.runtimeType}');
      if (mounted && search == _mentionSearch) {
        setState(() => _mentionOptions = const []);
      }
    }
  }

  void _pickMention(MentionOption option) {
    final query = _mention;
    if (query == null) return;
    _mentionTimer?.cancel();
    _mentionSearch++;
    _mention = null;
    setState(() => _mentionOptions = const []);
    _input.value = insertMention(_input.value, query, _picked.pick(option));
    _inputFocus.requestFocus();
  }

  /// Arrows, Enter, Tab and Escape belong to an open suggestion list.
  KeyEventResult? _onMentionKey(KeyEvent event) {
    if (_mentionOptions.isEmpty ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return null;
    }
    final key = event.logicalKey;
    final count = _mentionOptions.length;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _mentionHighlight = (_mentionHighlight + 1) % count);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _mentionHighlight = (_mentionHighlight - 1 + count) % count);
    } else if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.tab) &&
        !_input.value.composing.isValid &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _pickMention(_mentionOptions[_mentionHighlight]);
    } else if (event is KeyDownEvent && key == LogicalKeyboardKey.escape) {
      _mentionDismissedAt = _mention?.start;
      _mentionTimer?.cancel();
      _mentionSearch++;
      _mention = null;
      setState(() => _mentionOptions = const []);
    } else {
      return null;
    }
    return KeyEventResult.handled;
  }
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
    FileDrops.instance.addTarget(_onDrop);
    _input.addListener(_updateMention);
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
    final error = await _thread.editMessage(m.id, _picked.expand(_input.text));
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

  Future<void> _onDrop(List<String> paths) async {
    if (!_canUpload || _editing != null) {
      _notify(_editing != null
          ? 'Finish editing before sending files.'
          : 'Files can\'t be sent in this conversation.');
      return;
    }
    final (:files, :skipped) = sendableFiles(paths);
    if (skipped > 0) {
      _notify(skipped == 1
          ? 'Folders can\'t be sent, only files.'
          : '$skipped items weren\'t files and were skipped.');
    }
    if (_scroll.hasClients && files.isNotEmpty) _scroll.jumpTo(0);
    for (final f in files) {
      await _thread.sendFile(f);
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
    final wire = _picked.expand(text);
    _picked.clear();
    _input.clear();
    if (reply != null) setState(() => _replyTo = null);
    _thread.send(text, replyTo: reply?.id, wireText: wire);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _inputFocus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final mention = _onMentionKey(event);
    if (mention != null) return mention;
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
    FileDrops.instance.removeTarget(_onDrop);
    _lifecycle.dispose();
    _thread.dispose();
    _mentionTimer?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final twoPane = MediaQuery.sizeOf(context).width >= _twoPaneWidth;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        _content(context, room, twoPane),
        ValueListenableBuilder(
          valueListenable: FileDrops.instance.hovering,
          builder: (context, hovering, _) =>
              hovering && _canUpload && FileDrops.instance.isCurrent(_onDrop)
              ? Positioned.fill(child: _DropHint(room.name))
              : const Positioned(left: 0, top: 0, child: SizedBox.shrink()),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, Room room, bool twoPane) {
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
                if (widget.onSearch != null)
                  IconButton(
                    tooltip: 'Search this conversation',
                    icon: const Icon(Icons.search),
                    onPressed: widget.onSearch,
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
            if (_mentionOptions.isNotEmpty)
              _MentionList(
                options: _mentionOptions,
                avatars: widget.avatars,
                highlighted: _mentionHighlight,
                onPick: _pickMention,
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
          onCancel: () => _thread.cancelUpload(o),
        ),
      );
    }
    final messages = _thread.messages;
    final selfId = widget.room.selfId;
    final readUpTo = _thread.lastCommonRead;
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
                readByAll: readUpTo == null ? null : m.id <= readUpTo,
                showName: !grouped,
                // A one-to-one's header already says who this is.
                avatar: !widget.room.hasMembers
                    ? null
                    : grouped
                    ? const SizedBox(width: _messageAvatarWidth)
                    : Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Avatar(
                          radius: _messageAvatarRadius,
                          name: m.actorName.isEmpty ? 'Guest' : m.actorName,
                          image: m.actorType == 'users'
                              ? widget.avatars?.forUser(m.actorId)
                              : null,
                        ),
                      ),
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

/// Over the conversation while files are dragged across it.
class _DropHint extends StatelessWidget {
  const _DropHint(this.name);
  final String name;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.9),
          border: Border.all(color: scheme.primary, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.upload_file, size: 48, color: scheme.primary),
            const SizedBox(height: 8),
            Text(
              'Drop to send to $name',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _MentionList extends StatelessWidget {
  const _MentionList({
    required this.options,
    required this.highlighted,
    required this.onPick,
    this.avatars,
  });
  final AvatarStore? avatars;
  final List<MentionOption> options;
  final int highlighted;
  final ValueChanged<MentionOption> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, o) in options.indexed)
              ListTile(
                dense: true,
                selected: i == highlighted,
                selectedTileColor: scheme.secondaryContainer,
                leading: o.isEveryone || o.isGroup
                    ? const Icon(Icons.groups_outlined)
                    : Avatar(
                        radius: 16,
                        name: o.label,
                        image: o.source == 'users'
                            ? avatars?.forUser(o.id)
                            : null,
                      ),
                title: Text(
                  o.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: o.details.isEmpty
                    ? null
                    : Text(
                        o.details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => onPick(o),
              ),
          ],
        ),
      ),
    );
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

/// A full date with its year, for messages that may be years old.
class FullDateDivider extends StatelessWidget {
  const FullDateDivider(this.time, {super.key});
  final DateTime time;

  @override
  Widget build(BuildContext context) =>
      _Divider(MaterialLocalizations.of(context).formatFullDate(time));
}

class _Divider extends StatelessWidget {
  const _Divider(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    // A long date wraps in a narrow window instead of overflowing.
    child: LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          const Expanded(child: Divider()),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth - 16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
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

/// A message to read, not act on: only Copy text is offered.
class ReadOnlyMessage extends StatelessWidget {
  const ReadOnlyMessage({
    super.key,
    required this.message,
    required this.own,
    required this.preview,
    this.avatars,
  });
  final ChatMessage message;
  final bool own;
  final Future<Uint8List> Function(int fileId) preview;
  final AvatarStore? avatars;

  @override
  Widget build(BuildContext context) {
    if (message.isSystem) return _SystemRow(message);
    return _MessageBubble(
      message: message,
      own: own,
      showName: true,
      avatar: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Avatar(
          radius: _messageAvatarRadius,
          name: message.actorName.isEmpty ? 'Guest' : message.actorName,
          image: message.actorType == 'users'
              ? avatars?.forUser(message.actorId)
              : null,
        ),
      ),
      canInteract: false,
      onReply: () {},
      onReact: (_) {},
      onEdit: () {},
      onDelete: () {},
      canModerate: false,
      preview: preview,
    );
  }
}

const _messageAvatarRadius = 16.0;
const _messageAvatarWidth = _messageAvatarRadius * 2 + 8;

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.own,
    required this.child,
    this.actions,
    this.avatar,
  });
  final bool own;
  final Widget child;
  final Widget? actions;
  final Widget? avatar;
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
        // A tall message keeps its avatar and its buttons in view at the top.
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!own) ?avatar,
          if (own && side != null) side,
          bubble,
          if (!own && side != null) side,
        ],
      ),
    );
  }
}

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🎉'];
const _moreReactions = '';

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
              onSelected: (e) async {
                if (e != _moreReactions) return widget.onReact!(e);
                final picked = await showEmojiPicker(context);
                if (picked != null) widget.onReact?.call(picked);
              },
              itemBuilder: (context) => [
                for (final e in _quickReactions)
                  PopupMenuItem(value: e, child: Text(e)),
                const PopupMenuItem(
                  value: _moreReactions,
                  child: Text('More…'),
                ),
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
    this.avatar,
    required this.canInteract,
    required this.onReply,
    required this.onReact,
    required this.onEdit,
    required this.onDelete,
    required this.canModerate,
    required this.preview,
    this.readByAll,
  });

  /// For the user's own messages, when the server reports read status.
  final bool? readByAll;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool canModerate;
  final ChatMessage message;
  final bool own;
  final bool showName;

  /// Beside other people's messages in a group; empty space to line up the
  /// later messages in a run.
  final Widget? avatar;
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
          avatar: widget.avatar,
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
              _MessageText(
                message.segments,
                blocks: message.blocks,
                italic: message.isDeleted,
              ),
              if (message.reactions.isNotEmpty)
                _Reactions(
                  message: message,
                  onReact: widget.canInteract ? widget.onReact : null,
                ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(message.edited ? '$time · edited' : time, style: small),
                    if (widget.own && widget.readByAll != null)
                      _ReadMark(read: widget.readByAll!),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tick when sent, two once everyone in the conversation has read it, as
/// in the official clients.
class _ReadMark extends StatelessWidget {
  const _ReadMark({required this.read});
  final bool read;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: read ? 'Read' : 'Sent',
        child: Icon(
          read ? Icons.done_all : Icons.done,
          size: 14,
          color: read ? scheme.primary : scheme.onSurfaceVariant,
          semanticLabel: read ? 'Read' : 'Sent',
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
  const _MessageText(this.segments, {this.blocks, this.italic = false});
  final List<Segment> segments;
  final List<MdBlock>? blocks;
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
    final kindStyle = switch (s.kind) {
      SegmentKind.text => null,
      SegmentKind.mention => const TextStyle(fontWeight: FontWeight.bold),
      SegmentKind.file => tap != null ? link : null,
      SegmentKind.link => link,
    };
    final format = _formatStyle(s.style, scheme);
    return TextSpan(
      text: s.kind == SegmentKind.mention
          ? '@${s.text}'
          : s.kind == SegmentKind.file
          ? '📎 ${s.text}'
          : s.text,
      style: kindStyle == null ? format : kindStyle.merge(format),
      recognizer: tap,
      mouseCursor: mouse,
    );
  }

  /// Null when plain, so a plain message's spans stay as simple as they were.
  TextStyle? _formatStyle(MdStyle m, ColorScheme scheme) {
    if (m.isPlain) return null;
    return TextStyle(
      fontWeight: m.bold ? FontWeight.bold : null,
      fontStyle: m.italic ? FontStyle.italic : null,
      decoration: m.strike ? TextDecoration.lineThrough : null,
      fontFamily: m.code ? 'monospace' : null,
      fontFamilyFallback: m.code ? _monospaceFallback : null,
      backgroundColor: m.code ? scheme.onSurface.withValues(alpha: 0.1) : null,
    );
  }

  Widget _rich(List<Segment> segments, ThemeData theme, {TextStyle? style}) =>
      Text.rich(
        TextSpan(
          style: widget.italic
              ? const TextStyle(fontStyle: FontStyle.italic).merge(style)
              : style,
          children: [for (final s in segments) _span(s, theme)],
        ),
      );

  Widget _block(MdBlock b, ThemeData theme) {
    final scheme = theme.colorScheme;
    return switch (b.kind) {
      MdKind.paragraph => _rich(b.segments, theme),
      MdKind.heading => _rich(
        b.segments,
        theme,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: switch (b.level) {
            1 => 20,
            2 => 18,
            _ => 16,
          },
        ),
      ),
      MdKind.quote => Container(
        padding: const EdgeInsets.only(left: 8),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: scheme.outline, width: 3)),
        ),
        child: _rich(b.segments, theme),
      ),
      MdKind.listItem => Padding(
        padding: EdgeInsets.only(left: 12.0 * b.level),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(b.marker),
            const SizedBox(width: 6),
            Flexible(child: _rich(b.segments, theme)),
          ],
        ),
      ),
      // Scrolls sideways: wrapping would break what the code means.
      MdKind.code => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text.rich(
            TextSpan(
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: _monospaceFallback,
              ),
              children: [
                for (final s in b.segments)
                  TextSpan(
                    text: s.kind == SegmentKind.mention
                        ? '@${s.text}'
                        : s.text,
                  ),
              ],
            ),
          ),
        ),
      ),
      MdKind.rule => const SizedBox(width: 120, child: Divider()),
    };
  }

  @override
  Widget build(BuildContext context) {
    _clearTaps();
    final theme = Theme.of(context);
    final blocks = widget.blocks;
    if (blocks == null) {
      return _rich(widget.segments, theme);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, b) in blocks.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
            child: _block(b, theme),
          ),
      ],
    );
  }
}

const _monospaceFallback = ['DejaVu Sans Mono', 'Noto Sans Mono', 'Liberation Mono'];

class _OutgoingBubble extends StatelessWidget {
  const _OutgoingBubble({
    required this.message,
    required this.onRetry,
    required this.onDiscard,
    required this.onCancel,
  });
  final OutgoingMessage message;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = message.state == SendState.failed;
    final progress = message.progress;
    return _Bubble(
      own: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(message.filePath != null ? '📎 ${message.text}' : message.text),
          if (!failed && message.filePath != null) ...[
            const SizedBox(height: 4),
            SizedBox(
              width: 200,
              child: LinearProgressIndicator(value: progress),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  progress == null
                      ? 'Uploading…'
                      : 'Uploading… ${(progress * 100).floor()}%',
                  style: theme.textTheme.bodySmall,
                ),
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
              ],
            ),
          ] else if (!failed)
            Text('Sending…', style: theme.textTheme.bodySmall)
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
