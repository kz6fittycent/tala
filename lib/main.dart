import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';


import 'src/account_store.dart';
import 'src/app_colors.dart';
import 'src/app_info.dart';
import 'src/app_menu.dart';
import 'src/call.dart';
import 'src/chat.dart';
import 'src/camera_cycle.dart';
import 'src/chat_alerts.dart';
import 'src/chat_view.dart';
import 'src/desktop_notify.dart';
import 'src/incoming_calls.dart';
import 'src/log.dart';
import 'src/nc_api.dart';
import 'src/guest_link.dart';
import 'src/new_conversation.dart';
import 'src/ringer.dart';
import 'src/settings.dart';
import 'src/tray.dart';
import 'src/tray_selftest.dart';
import 'src/selftest.dart';
import 'src/frame_log.dart';
import 'src/groups.dart';
import 'src/licenses.dart';
import 'src/report.dart';
import 'src/report_view.dart';
import 'src/search.dart';
import 'src/call_layout.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  log('=== Tala $appVersion starting · ${reportPlatform()}');
  installCrashCapture();
  registerLicenses();
  if (args.contains('--chat-check')) {
    final Credentials? creds;
    try {
      creds = await AccountStore().load();
    } on KeyringException catch (e) {
      log('check: keyring failed: ${e.message}');
      exit(1);
    }
    if (creds == null) {
      log('check: not signed in');
      exit(1);
    }
    await NcApi(creds).chatCheck();
    exit(0);
  }
  if (args.contains('--call-check')) {
    // Joins one call using the account in TALA_CHECK_*, for a test server. It
    // never touches the keyring or the real account. With --call-check-audio it
    // opens the default mic, which a check points at a silent source through
    // PULSE_SOURCE. Only --call-check-camera opens the camera.
    final env = Platform.environment;
    final room = Room(env['TALA_CHECK_TOKEN']!, 'check', false, 2);
    final api = NcApi(
      Credentials(
        env['TALA_CHECK_SERVER']!,
        env['TALA_CHECK_USER']!,
        env['TALA_CHECK_PASSWORD']!,
      ),
    );
    final call = Call(
      api,
      room,
      answering: true, // No ringback tone on the user's speakers.
      openMedia: () async {
        // Stands in for a camera that's slow to open.
        final delay = int.parse(env['TALA_CHECK_MEDIA_DELAY'] ?? '0');
        await Future<void>.delayed(Duration(seconds: delay));
        if (args.contains('--call-check-camera')) {
          return navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': true,
          });
        }
        return args.contains('--call-check-audio')
            ? navigator.mediaDevices.getUserMedia({
                'audio': true,
                'video': false,
              })
            : null;
      },
    );
    unawaited(call.start());
    final seconds = int.parse(env['TALA_CHECK_SECONDS'] ?? '45');
    for (var i = 0; i < seconds ~/ 5; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      log('check: ${call.state}, remotes ${call.remotes.length}, '
          '${await call.meshStats()}');
    }
    await call.hangUp();
    exit(0);
  }
  if (args.contains('--report-check')) {
    // What a report would hold, without sending anything.
    Credentials? creds;
    try {
      creds = await AccountStore().load();
    } on KeyringException catch (e) {
      log('report check: keyring failed: ${e.message}');
    }
    final report = buildReport(
      description: '',
      contact: '',
      facts: await gatherFacts(api: creds == null ? null : NcApi(creds)),
      creds: creds,
    );
    log('report check: platform ${report.platform}');
    log('report check: facts\n${report.facts}');
    log('report check: ${report.log.length} characters of log');
    exit(0);
  }
  if (args.contains('--keyring-selftest')) {
    final passed = await keyringSelfTest();
    log('keyring self-test ${passed ? 'passed' : 'FAILED'}');
    exit(passed ? 0 : 1);
  }
  if (args.contains('--test-ring')) {
    final ringer = Ringer();
    await ringer.start('Tala test');
    await Future<void>.delayed(const Duration(seconds: 6));
    await ringer.stop();
    log('ring test done');
    exit(0);
  }
  if (args.contains('--test-ringback')) {
    final ringback = Ringback()..start();
    await Future<void>.delayed(const Duration(seconds: 7));
    ringback.stop();
    log('ringback test done');
    exit(0);
  }
  if (args.contains('--frame-check')) {
    runApp(FrameCheck(done: () => exit(0)));
    return;
  }
  if (args.contains('--test-chime')) {
    // A real popup with the real sound, for checking the desktop plays it.
    await DesktopNotifier().show('test', 'Tala', 'Test message', sound: true);
    log('chime test: sent');
    exit(0);
  }
  if (args.contains('--badge-test')) {
    // Shows a count on the dock for a moment, for checking how it looks.
    final tray = AppTray();
    await tray.setBadge(7);
    log('badge test: 7 for 15 seconds');
    await Future<void>.delayed(const Duration(seconds: 15));
    await tray.setBadge(0);
    log('badge test: cleared');
    exit(0);
  }
  if (args.contains('--tray-selftest')) {
    runApp(const TraySelfTest());
    return;
  }
  startFrameLog();
  Timer(const Duration(seconds: 15), sendPendingReports);
  if (args.contains('--crash-test')) {
    // Throws on purpose, to check the capture and the report it offers.
    Timer(const Duration(seconds: 3), () {
      throw StateError('Tala crash test 123');
    });
  }
  runApp(args.contains('--selftest')
      ? const SelfTest()
      : args.contains('--camera-cycle')
          ? const CameraCycle()
          : TalaApp(startHidden: args.contains('--background')));
}

class TalaApp extends StatefulWidget {
  const TalaApp({super.key, required this.startHidden});
  final bool startHidden;
  @override
  State<TalaApp> createState() => _TalaAppState();
}

class _TalaAppState extends State<TalaApp> {
  final AppSettings _settings = AppSettings();

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _settings,
    builder: (context, _) => MaterialApp(
      title: 'Tala',
      theme: talaTheme(_settings.accent, Brightness.light),
      darkTheme: talaTheme(_settings.accent, Brightness.dark),
      themeMode: _settings.themeMode,
      home: StartPage(settings: _settings, startHidden: widget.startHidden),
    ),
  );
}

/// Finds the saved account. The window stays hidden on a background start
/// unless this needs the user, as they'd otherwise have no idea why nothing
/// is happening.
class StartPage extends StatefulWidget {
  const StartPage({
    super.key,
    required this.settings,
    required this.startHidden,
  });
  final AppSettings settings;
  final bool startHidden;
  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  /// The keyring service can still be starting when Tala starts at login.
  static const _attempts = 5;
  static const _retryDelay = Duration(seconds: 3);

  /// An unlock prompt can wait for as long as it likes, and one that can't
  /// appear never finishes. Tala can't take calls until this is settled.
  static const _slowAfter = Duration(seconds: 20);

  final AccountStore _store = AccountStore();
  bool _loading = true;
  NcApi? _api;
  KeyringException? _problem;

  /// Set when the server stopped accepting the saved sign-in.
  String? _expiredServer;
  bool _slow = false;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  /// Polling with a rejected password would get Tala locked out by the server's
  /// brute force protection, so this stops everything and asks the user.
  void _signInExpired() {
    log('account: the server rejected the sign-in');
    AppTray().show();
    setState(() {
      _expiredServer = _api?.creds.server;
      _api = null;
    });
  }

  /// Used for a first sign-in and for moving to another server.
  Future<void> _useAccount(Credentials creds) async {
    final messenger = ScaffoldMessenger.of(context);
    final previous = _api;
    final next = NcApi(creds);
    try {
      await _store.save(creds);
    } on KeyringException catch (e) {
      log('account: saving to the keyring failed: ${e.message}');
      if (previous != null) {
        // The keyring still holds the old account, which has to keep working.
        await next.revokeAppPassword().catchError((Object _) {});
        messenger.showSnackBar(const SnackBar(
          content: Text('Your keyring couldn\'t save the new server, so you '
              'stay on this one.'),
        ));
        return;
      }
      messenger.showSnackBar(const SnackBar(
        content: Text('Signed in, but your keyring couldn\'t save it. '
            'You\'ll need to sign in again next time.'),
      ));
    }
    if (!mounted) return;
    // One frame with no account, so the old page's cleanup finishes before the
    // new page takes over the tray.
    setState(() {
      _api = null;
      _expiredServer = null;
      _loading = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(() {
      _api = next;
      _loading = false;
    });
    if (previous == null) return;
    try {
      await previous.revokeAppPassword();
    } catch (e) {
      log('account: removing the old app password failed: $e');
      messenger.showSnackBar(SnackBar(
        content: Text('Tala couldn\'t remove its app password from '
            '${serverLabel(previous.creds.server)}. You can revoke it in that '
            'server\'s security settings.'),
      ));
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _problem = null;
    });
    _load();
  }

  Future<void> _load() async {
    _slowTimer?.cancel();
    _slowTimer = Timer(_slowAfter, () {
      log('account: still waiting for the keyring');
      AppTray().show();
      setState(() => _slow = true);
    });
    for (var attempt = 1;; attempt++) {
      try {
        final creds = await _store.load();
        _slowTimer?.cancel();
        if (!mounted) return;
        if (creds == null) AppTray().show();
        setState(() {
          _loading = false;
          _api = creds == null ? null : NcApi(creds);
        });
      } on KeyringException catch (e) {
        log('account: attempt $attempt: locked=${e.locked}: ${e.message}');
        if (!e.locked && attempt < _attempts) {
          await Future<void>.delayed(_retryDelay);
          if (!mounted) return;
          continue;
        }
        _slowTimer?.cancel();
        if (!mounted) return;
        AppTray().show();
        setState(() {
          _loading = false;
          _slow = false;
          _problem = e;
        });
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            if (_slow) ...[
              const SizedBox(height: 16),
              const Text('Waiting for your keyring. If it asked for a '
                  'password, answer that first.'),
            ],
          ]),
        ),
      );
    }
    final problem = _problem;
    if (problem != null) {
      return Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                problem.locked
                    ? 'Your keyring is locked'
                    : 'Can\'t reach your keyring',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                problem.locked
                    ? 'Tala keeps your sign-in there. Unlock it to continue.'
                    : Platform.environment.containsKey('SNAP')
                    ? 'Tala keeps your sign-in there, but no keyring service '
                        'answered. The snap may need permission to use it:\n\n'
                        'sudo snap connect tala:password-manager-service'
                    : 'Tala keeps your sign-in there, but no keyring service '
                        'answered. Your account is still saved if you\'ve '
                        'signed in before.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _retry, child: const Text('Try again')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => showReportDialog(context),
                child: const Text('Report a problem'),
              ),
            ]),
          ),
        ),
      );
    }
    final expired = _expiredServer;
    if (expired != null) {
      return SignInExpiredPage(server: expired, onSignedIn: _useAccount);
    }
    final api = _api;
    return api == null
        ? LoginPage(onSignedIn: _useAccount)
        : RoomsPage(
            api: api,
            settings: widget.settings,
            startHidden: widget.startHidden,
            onChangeAccount: _useAccount,
            onSignInExpired: _signInExpired,
          );
  }
}

class LoginPage extends StatelessWidget {
  const LoginPage({super.key, required this.onSignedIn});
  final ValueChanged<Credentials> onSignedIn;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SignInForm(onSignedIn: onSignedIn),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => showReportDialog(context),
              child: const Text('Report a problem'),
            ),
          ],
        ),
      ),
    ),
  );
}

class SignInExpiredPage extends StatelessWidget {
  const SignInExpiredPage({
    super.key,
    required this.server,
    required this.onSignedIn,
  });
  final String server;
  final ValueChanged<Credentials> onSignedIn;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Please sign in again',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '${serverLabel(server)} no longer accepts Tala\'s sign-in. It '
              'may have been revoked, or the account may have changed.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SignInForm(initialServer: server, onSignedIn: onSignedIn),
          ],
        ),
      ),
    ),
  );
}

class RoomsPage extends StatefulWidget {
  const RoomsPage({
    super.key,
    required this.api,
    required this.settings,
    required this.startHidden,
    required this.onChangeAccount,
    required this.onSignInExpired,
  });
  final NcApi api;
  final AppSettings settings;
  final bool startHidden;
  final ValueChanged<Credentials> onChangeAccount;
  final VoidCallback onSignInExpired;
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

  /// The conversation in a call, if any, and whether its chat is showing.
  String? _callToken;
  bool _callChatOpen = false;
  Timer? _roomTimer;
  final Map<String, String> _drafts = {};
  List<FederationInvite> _invites = const [];
  Timer? _inviteTimer;
  bool _inviteFailureLogged = false;
  final DesktopNotifier _notifier = DesktopNotifier();
  late final AppLifecycleListener _lifecycle;
  late final ChatAlerts _alerts = ChatAlerts(
    isViewing: (token) {
      if (!_focused) return false;
      final inCall = _callToken;
      return inCall == null
          ? _selected == token
          : _callChatOpen && inCall == token;
    },
    show: (note) {
      _notifier.show(
        note.token,
        note.title,
        note.body,
        // Not over a ringing phone or into the middle of a call.
        sound:
            widget.settings.messageSound &&
            !_dialogOpen &&
            Call.current == null,
      );
      _refreshRooms();
    },
    hide: _notifier.close,
    dismiss: (id) => widget.api.dismissNotification(id).catchError((Object e) {
      log('chat: clearing a notification failed: $e');
    }),
  );
  late bool _focused = !widget.startHidden;
  final AppTray _tray = AppTray();

  /// Runs before the process ends when the user quits from the tray.
  Future<void> _beforeQuit() async {
    log('app: quitting');
    _notifier.closeAll();
    await _ringer.stop();
    await Call.current?.hangUp();
  }

  void _offerEarlierCrash() {
    final crash = previousCrash();
    if (crash == null || !mounted) return;
    showReportDialog(
      context,
      creds: widget.api.creds,
      crash: crash,
      earlier: true,
    );
  }

  /// Not over a call: it stays saved and is offered at the next start.
  void _offerNewCrash() {
    final crash = newCrash.value;
    if (crash == null || !mounted || Call.current != null) return;
    showReportDialog(context, creds: widget.api.creds, crash: crash);
  }

  @override
  void initState() {
    super.initState();
    _tray.start(onQuit: _beforeQuit);
    _lifecycle = AppLifecycleListener(onStateChange: (state) {
      log('app: ${state.name}');
      _focused = state == AppLifecycleState.resumed;
      _updateBadge();
    });
    widget.api
      ..onChatNotes = _alerts.update
      ..onConversationRead = _alerts.conversationRead;
    _incoming.addListener(_onIncomingChanged);
    _incoming.start();
    newCrash.addListener(_offerNewCrash);
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerEarlierCrash());
    _refreshRooms();
    _roomTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _refreshRooms());
    _refreshInvites();
    _inviteTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _refreshInvites());
  }

  Future<void> _refreshRooms() async {
    try {
      final rooms = await widget.api.rooms();
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _roomsError = null;
      });
      _updateBadge();
    } catch (e) {
      log('rooms: $e');
      if (e is ApiException && e.status == 401) {
        final rejected = await widget.api.signInRejected();
        if (!mounted) return;
        if (rejected) {
          widget.onSignInExpired();
          return;
        }
      }
      if (mounted) setState(() => _roomsError = e);
    }
  }

  void _updateBadge() {
    _tray.setBadge(_focused ? 0 : dockUnread(_rooms ?? const []));
  }

  Future<void> _refreshInvites() async {
    try {
      final invites = await widget.api.federationInvites();
      _inviteFailureLogged = false;
      if (mounted) setState(() => _invites = invites);
    } catch (e) {
      // Servers without federation refuse this, so it isn't worth repeating.
      if (!_inviteFailureLogged) log('invites: $e');
      _inviteFailureLogged = true;
    }
  }

  Future<void> _answerInvite(FederationInvite invite, bool accept) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await (accept
          ? widget.api.acceptInvite(invite.id)
          : widget.api.declineInvite(invite.id));
    } catch (e) {
      log('invites: answering failed: $e');
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t answer that invitation.')),
      );
    }
    await _refreshInvites();
    await _refreshRooms();
  }

  Future<void> _newConversation() async {
    final messenger = ScaffoldMessenger.of(context);
    final person = await showDialog<Person>(
      context: context,
      builder: (_) => NewConversationDialog(
        search: widget.api.searchPeople,
        onInviteGuest: _newGuestConversation,
        onNewGroup: _newGroup,
      ),
    );
    if (person == null) return;
    try {
      final token = await widget.api.startOneToOne(person.id);
      await _refreshRooms();
      _select(token);
    } catch (e) {
      log('rooms: starting a conversation failed: $e');
      messenger.showSnackBar(SnackBar(
        content: Text('Couldn\'t start a conversation with ${person.name}.'),
      ));
    }
  }

  Future<void> _newGroup() async {
    final messenger = ScaffoldMessenger.of(context);
    final group = await showDialog<NewGroup>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NewGroupDialog(
        search: widget.api.searchPeople,
        create: widget.api.createGroup,
        add: widget.api.addMember,
      ),
    );
    if (group == null || !mounted) return;
    await _refreshRooms();
    if (!mounted) return;
    _select(group.token);
    if (group.notAdded.isNotEmpty) {
      final names = group.notAdded.map((p) => p.name).join(', ');
      messenger.showSnackBar(SnackBar(
        content: Text('The group was created, but $names couldn\'t be added. '
            'Try again from Members.'),
      ));
    }
  }

  Future<void> _showMembers(Room room) async {
    await showDialog<void>(
      context: context,
      builder: (_) => MembersDialog(
        name: room.name,
        selfId: room.selfId,
        canManage: room.canManage,
        avatars: widget.api.avatars,
        load: () => widget.api.members(room.token),
        search: widget.api.searchPeople,
        add: (id) => widget.api.addMember(room.token, id),
        remove: (id) => widget.api.removeMember(room.token, id),
        setModerator: (id, on) =>
            widget.api.setModerator(room.token, id, on),
      ),
    );
    // Leaving moderation, for one, changes what this user can do in it.
    if (mounted) await _refreshRooms();
  }

  Future<void> _renameRoom(Room room) async {
    final renamed = await showDialog<bool>(
      context: context,
      builder: (_) => RenameDialog(
        name: room.name,
        rename: (name) => widget.api.renameConversation(room.token, name),
      ),
    );
    if (renamed == true && mounted) await _refreshRooms();
  }

  Future<void> _search({Room? room}) async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => SearchDialog(
        search: widget.api.searchMessages,
        context: widget.api.chatContext,
        preview: widget.api.chatPreview,
        selfId: room?.selfId ?? _rooms?.firstOrNull?.selfId ?? '',
        conversation: room?.token,
        conversationName: room?.name,
        avatars: widget.api.avatars,
      ),
    );
    if (token != null && mounted) _select(token);
  }

  Future<void> _newGuestConversation() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) =>
          NewGuestConversationDialog(create: widget.api.createGuestConversation),
    );
    if (token == null || !mounted) return;
    await _refreshRooms();
    if (!mounted) return;
    _select(token);
    final room = _rooms?.where((r) => r.token == token).firstOrNull;
    if (room != null) await _showGuestLink(room);
  }

  Future<void> _showGuestLink(Room room) => showDialog<void>(
    context: context,
    builder: (_) => GuestLinkDialog(
      name: room.name,
      link: guestLink(widget.api.creds.server, room.token),
      hasPassword: room.hasPassword,
      canManage: room.isModerator,
      invite: (email) => widget.api.inviteByEmail(room.token, email),
      turnOff: () => _turnOffGuestLink(room),
    ),
  );

  Future<bool> _turnOffGuestLink(Room room) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off the guest link?'),
        content: Text(
          'The link to ${room.name} stops working and guests lose access. '
          'People with accounts stay in the conversation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    try {
      await widget.api.turnOffGuestLink(room.token);
    } catch (e) {
      log('rooms: turning off a guest link failed: $e');
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t turn off that link.')),
      );
      return false;
    }
    await _refreshRooms();
    return true;
  }

  Future<void> _setArchived(Room room, bool archived) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.api.setArchived(room.token, archived);
    } catch (e) {
      log('rooms: changing archive failed: $e');
      messenger.showSnackBar(SnackBar(
        content: Text('Couldn\'t ${archived ? 'archive' : 'unarchive'} '
            '${room.name}.'),
      ));
      return;
    }
    await _refreshRooms();
    messenger.showSnackBar(SnackBar(
      content: Text('${archived ? 'Archived' : 'Unarchived'} ${room.name}'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => _setArchived(room, !archived),
      ),
    ));
  }

  Future<void> _deleteRoom(Room room) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await confirmDeleteForEveryone(context, room.name)) return;
    try {
      await widget.api.deleteConversation(room.token);
    } catch (e) {
      log('rooms: deleting failed: $e');
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t delete that conversation.')),
      );
      return;
    }
    _drafts.remove(room.token);
    if (!mounted) return;
    if (_selected == room.token) setState(() => _selected = null);
    await _refreshRooms();
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
    newCrash.removeListener(_offerNewCrash);
    _tray.stop();
    _lifecycle.dispose();
    widget.api
      ..onChatNotes = null
      ..onConversationRead = null;
    _notifier.closeAll();
    _roomTimer?.cancel();
    _inviteTimer?.cancel();
    _tray.setBadge(0);
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
      builder: (_) => IncomingCallDialog(name: ring.name),
    );
    _dialogOpen = false;
    await _ringer.stop();
    if (accepted == true) {
      final note = await _incoming.accept();
      if (note != null) {
        await _openCall(
          Room(note.token, note.name, true, note.isOneToOne ? 1 : 2),
          answering: true,
        );
      }
    } else if (accepted == false) {
      await _incoming.decline();
    }
  }

  Room? _knownRoom(String token) =>
      _rooms?.where((r) => r.token == token).firstOrNull;

  /// A ring only carries a name and type, but chat needs to know who the user
  /// is in the room, so use the full room whenever the server will give it.
  Future<void> _openCall(Room room, {bool answering = false}) async {
    _incoming.suspended = true;
    if (_knownRoom(room.token) == null) await _refreshRooms();
    if (!mounted) return;
    final full = _knownRoom(room.token) ?? room;
    // The main chat comes off screen, so two panes never poll one conversation.
    setState(() {
      _callToken = room.token;
      _callChatOpen = widget.settings.callChatOpen;
    });
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CallPage(
          api: widget.api,
          room: full,
          answering: answering,
          settings: widget.settings,
          drafts: _drafts,
          onChatOpen: (open) => _callChatOpen = open,
        ),
      ),
    );
    _incoming.suspended = false;
    if (mounted) setState(() => _callToken = null);
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
          onArchive: (room) => _setArchived(room, !room.archived),
          settings: widget.settings,
          menu: AppMenu(
            settings: widget.settings,
            creds: widget.api.creds,
            onChangeAccount: widget.onChangeAccount,
          ),
          onNewConversation: _newConversation,
          onGuestLink: _showGuestLink,
          onDelete: _deleteRoom,
          onMembers: _showMembers,
          onRename: _renameRoom,
          onSearch: _search,
          avatars: widget.api.avatars,
          banner: _invites.isEmpty
              ? null
              : InviteBanners(
                  invites: _invites,
                  onAccept: (i) => _answerInvite(i, true),
                  onDecline: (i) => _answerInvite(i, false),
                ),
          conversation: selected == null || _callToken != null
              ? null
              : ConversationPane(
                  key: ValueKey(selected.token),
                  source: widget.api,
                  room: selected,
                  drafts: _drafts,
                  onBack: () => _select(null),
                  onCall: () => _openCall(selected!),
                  onMembers: () => _showMembers(selected!),
                  onSearch: () => _search(room: selected),
                  avatars: widget.api.avatars,
                ),
        ),
      ),
    );
  }
}

class IncomingCallDialog extends StatelessWidget {
  const IncomingCallDialog({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(name),
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
      );
}

class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.api,
    required this.room,
    required this.answering,
    required this.settings,
    required this.drafts,
    required this.onChatOpen,
  });
  final NcApi api;
  final Room room;

  /// Someone is already ringing, so the caller's tone isn't wanted.
  final bool answering;
  final AppSettings settings;
  final Map<String, String> drafts;
  final ValueChanged<bool> onChatOpen;
  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late final Call _call = Call(
    widget.api,
    widget.room,
    answering: widget.answering,
  )..start();

  /// Keeps the chat, with its scroll and any reply in progress, when resizing
  /// moves it between beside and under the video.
  final GlobalKey _chatKey = GlobalKey();

  void _toggleChat() {
    final open = !widget.settings.callChatOpen;
    widget.settings.callChatOpen = open;
    widget.onChatOpen(open);
    setState(() {});
  }

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
          body: CallLayout(
            // Cover crops to fill, whatever shape the other camera sends.
            others: FillGrid(children: [
              for (final r in _call.remotes)
                RTCVideoView(
                  r,
                  key: ObjectKey(r),
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
            ]),
            self: RTCVideoView(
              _call.localRenderer,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
            chat: widget.settings.callChatOpen
                ? ConversationPane(
                    key: _chatKey,
                    source: widget.api,
                    room: widget.room,
                    drafts: widget.drafts,
                    showHeader: false,
                    avatars: widget.api.avatars,
                    onBack: () {},
                    onCall: () {},
                  )
                : null,
            controls: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filled(
                    tooltip: _call.micOn ? 'Mute' : 'Unmute',
                    icon: Icon(_call.micOn ? Icons.mic : Icons.mic_off),
                    onPressed: _call.toggleMic),
                const SizedBox(width: 12),
                IconButton.filled(
                    tooltip:
                        _call.camOn ? 'Turn camera off' : 'Turn camera on',
                    icon: Icon(
                        _call.camOn ? Icons.videocam : Icons.videocam_off),
                    onPressed: _call.toggleCam),
                const SizedBox(width: 12),
                IconButton.filled(
                    tooltip: widget.settings.callChatOpen
                        ? 'Hide chat'
                        : 'Show chat',
                    icon: Icon(widget.settings.callChatOpen
                        ? Icons.chat
                        : Icons.chat_outlined),
                    onPressed: _toggleChat),
                const SizedBox(width: 12),
                IconButton.filled(
                    tooltip: 'Hang up',
                    style: IconButton.styleFrom(backgroundColor: Colors.red),
                    icon: const Icon(Icons.call_end),
                    onPressed: () => Navigator.of(context).pop()),
              ],
            ),
          ),
        ),
      );
}
