import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'src/call.dart';
import 'src/chat.dart';
import 'src/camera_cycle.dart';
import 'src/chat_alerts.dart';
import 'src/chat_view.dart';
import 'src/desktop_notify.dart';
import 'src/incoming_calls.dart';
import 'src/log.dart';
import 'src/nc_api.dart';
import 'src/ringer.dart';
import 'src/tray.dart';
import 'src/tray_selftest.dart';
import 'src/selftest.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  log('Tala prototype starting');
  if (args.contains('--chat-check')) {
    final creds = Credentials.load();
    if (creds == null) {
      log('check: not signed in');
      exit(1);
    }
    await NcApi(creds).chatCheck();
    exit(0);
  }
  if (args.contains('--test-ring')) {
    final ringer = Ringer();
    await ringer.start('Tala test');
    await Future<void>.delayed(const Duration(seconds: 6));
    await ringer.stop();
    log('ring test done');
    exit(0);
  }
  if (args.contains('--tray-selftest')) {
    runApp(const TraySelfTest());
    return;
  }
  runApp(args.contains('--selftest')
      ? const SelfTest()
      : args.contains('--camera-cycle')
          ? const CameraCycle()
          : const TalaApp());
}

class TalaApp extends StatelessWidget {
  const TalaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tala',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
        home: Credentials.load() == null
            ? const LoginPage()
            : RoomsPage(api: NcApi(Credentials.load()!)),
      );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController();
  String? _status;

  Future<void> _go() async {
    var url = _server.text.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http')) url = 'https://$url';
    setState(() => _status = 'Approve the login in your browser…');
    try {
      final creds = await loginFlow(url);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => RoomsPage(api: NcApi(creds))));
    } catch (e) {
      log('login: $e');
      setState(() => _status = 'Login failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: _server,
                decoration: const InputDecoration(
                    labelText: 'Nextcloud server address'),
                onSubmitted: (_) => _go(),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _go, child: const Text('Sign in')),
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(_status!),
              ],
            ]),
          ),
        ),
      );
}

class RoomsPage extends StatefulWidget {
  const RoomsPage({super.key, required this.api});
  final NcApi api;
  @override
  State<RoomsPage> createState() => _RoomsPageState();
}

class _RoomsPageState extends State<RoomsPage> {
  late final IncomingCalls _incoming = IncomingCalls(widget.api);
  final Ringer _ringer = Ringer();
  bool _dialogOpen = false;

  List<Room>? _rooms;
  Object? _roomsError;
  String? _selected;
  Timer? _roomTimer;
  final Map<String, String> _drafts = {};
  final DesktopNotifier _notifier = DesktopNotifier();
  late final AppLifecycleListener _lifecycle;
  late final ChatAlerts _alerts = ChatAlerts(
    isViewing: (token) => _focused && _selected == token,
    show: (note) {
      _notifier.show(note.token, note.title, note.body);
      _refreshRooms();
    },
    hide: _notifier.close,
    dismiss: (id) => widget.api.dismissNotification(id).catchError((Object e) {
      log('chat: clearing a notification failed: $e');
    }),
  );
  bool _focused = true;
  final AppTray _tray = AppTray();

  /// Runs before the process ends when the user quits from the tray.
  Future<void> _beforeQuit() async {
    log('app: quitting');
    _notifier.closeAll();
    await _ringer.stop();
    await Call.current?.hangUp();
  }

  @override
  void initState() {
    super.initState();
    _tray.start(onQuit: _beforeQuit);
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      log('app: ${state.name}');
      _focused = state == AppLifecycleState.resumed;
    });
    widget.api
      ..onChatNotes = _alerts.update
      ..onConversationRead = _alerts.conversationRead;
    _incoming.addListener(_onIncomingChanged);
    _incoming.start();
    _refreshRooms();
    _roomTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _refreshRooms());
  }

  Future<void> _refreshRooms() async {
    try {
      final rooms = await widget.api.rooms();
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _roomsError = null;
      });
    } catch (e) {
      log('rooms: $e');
      if (mounted) setState(() => _roomsError = e);
    }
  }

  Future<void> _removeRoom(Room room) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${room.name}?'),
        content: Text(room.type == 1
            ? 'This removes the chat from your list, and you lose access to '
                'its messages. It may come back if they message you.'
            : 'You\'ll leave this conversation and lose access to its '
                'messages. It carries on for everyone else.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.leaveConversation(room.token);
    } catch (e) {
      log('rooms: leaving failed: $e');
      messenger.showSnackBar(SnackBar(
        content: Text(e is ApiException && e.status == 400
            ? 'You\'re the only moderator. Make someone else a moderator '
                'first.'
            : 'Couldn\'t remove that conversation.'),
      ));
      return;
    }
    _drafts.remove(room.token);
    if (!mounted) return;
    if (_selected == room.token) setState(() => _selected = null);
    await _refreshRooms();
  }

  void _select(String? token) {
    if (token == _selected) return;
    setState(() => _selected = token);
    // The conversation being left, or opened, may have just been read.
    _refreshRooms();
  }

  @override
  void dispose() {
    _tray.stop();
    _lifecycle.dispose();
    widget.api
      ..onChatNotes = null
      ..onConversationRead = null;
    _notifier.closeAll();
    _roomTimer?.cancel();
    _incoming.removeListener(_onIncomingChanged);
    _incoming.dispose();
    _ringer.stop();
    super.dispose();
  }

  void _onIncomingChanged() {
    final ring = _incoming.current;
    if (ring != null && !_dialogOpen) {
      _dialogOpen = true;
      _ringer.start(ring.name);
      // The window may be hidden, and a call needs an answer.
      _tray.show();
      _showIncoming(ring);
    } else if (ring == null && _dialogOpen) {
      // The caller gave up, or another of the user's devices answered.
      _ringer.stop();
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _showIncoming(CallNote ring) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(ring.name),
        content: const Text('Incoming call'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Decline')),
          FilledButton.icon(
              icon: const Icon(Icons.call),
              onPressed: () => Navigator.of(context).pop(true),
              label: const Text('Accept')),
        ],
      ),
    );
    _dialogOpen = false;
    await _ringer.stop();
    if (accepted == true) {
      final note = await _incoming.accept();
      if (note != null) {
        await _openCall(Room(note.token, note.name, true, note.isOneToOne ? 1 : 2));
      }
    } else if (accepted == false) {
      await _incoming.decline();
    }
  }

  Future<void> _openCall(Room room) async {
    _incoming.suspended = true;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => CallPage(api: widget.api, room: room)));
    _incoming.suspended = false;
  }

  @override
  Widget build(BuildContext context) {
    final rooms = _rooms;
    Room? selected;
    for (final r in rooms ?? const <Room>[]) {
      if (r.token == _selected) selected = r;
    }
    return Scaffold(
      body: SafeArea(
        child: ChatLayout(
          rooms: rooms,
          roomsError: _roomsError,
          selected: selected,
          onSelect: _select,
          onRefresh: _refreshRooms,
          onRemove: _removeRoom,
          conversation: selected == null
              ? null
              : ConversationPane(
                  key: ValueKey(selected.token),
                  source: widget.api,
                  room: selected,
                  drafts: _drafts,
                  onBack: () => _select(null),
                  onCall: () => _openCall(selected!),
                ),
        ),
      ),
    );
  }
}

class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.api, required this.room});
  final NcApi api;
  final Room room;
  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late final Call _call = Call(widget.api, widget.room)..start();

  @override
  void dispose() {
    _call.hangUp();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _call,
        builder: (context, _) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(title: Text('${widget.room.name}: ${_call.state}')),
          body: Stack(children: [
            GridView.extent(
              maxCrossAxisExtent: 900,
              childAspectRatio: 16 / 9,
              children: [
                for (final r in _call.remotes)
                  RTCVideoView(r,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
              ],
            ),
            Positioned(
              right: 16,
              top: 16,
              width: 240,
              height: 135,
              child: RTCVideoView(_call.localRenderer, mirror: true),
            ),
          ]),
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton.filled(
                  icon: Icon(_call.micOn ? Icons.mic : Icons.mic_off),
                  onPressed: _call.toggleMic),
              const SizedBox(width: 12),
              IconButton.filled(
                  icon: Icon(_call.camOn ? Icons.videocam : Icons.videocam_off),
                  onPressed: _call.toggleCam),
              const SizedBox(width: 12),
              IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Colors.red),
                  icon: const Icon(Icons.call_end),
                  onPressed: () => Navigator.of(context).pop()),
            ]),
          ),
        ),
      );
}
