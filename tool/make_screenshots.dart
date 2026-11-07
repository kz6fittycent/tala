// Renders the screenshots for the README and wiki from the app's real widgets,
// with made-up people and messages, so no real account shows. Fonts come from
// the Flutter SDK, because tests have none of their own. There's no title bar,
// and no call screen, which needs real video.
//
//   XDG_CONFIG_HOME=$(mktemp -d) flutter test tool/make_screenshots.dart
//
// Writes docs/screenshots/*.png. Copy them to the wiki's images/ folder too.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/main.dart';
import 'package:tala/src/app_colors.dart';
import 'package:tala/src/app_menu.dart';
import 'package:tala/src/chat.dart';
import 'package:tala/src/chat_view.dart';
import 'package:tala/src/guest_link.dart';
import 'package:tala/src/nc_api.dart';
import 'package:tala/src/new_conversation.dart';
import 'package:tala/src/report.dart';
import 'package:tala/src/report_view.dart';
import 'package:tala/src/settings.dart';

const _out = 'docs/screenshots';
final _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

ChatMessage _message(
  int id,
  String actorId,
  String name,
  String text,
  int minutesAgo, {
  ChatMessage? parent,
  Map<String, int> reactions = const {},
}) => ChatMessage(
  id: id,
  actorType: 'users',
  actorId: actorId,
  actorName: name,
  timestamp: _now - minutesAgo * 60,
  segments: [Segment(text, SegmentKind.text)],
  isReplyable: true,
  parent: parent,
  reactions: reactions,
);

final _question = _message(
  103,
  'maya',
  'Maya Chen',
  'Is everyone still good for the trailhead at 8 on Saturday?',
  42,
);

final _chat = [
  _message(101, 'daniel', 'Daniel Ortiz', 'The forecast looks clear now.', 58),
  _message(
    102,
    'sam',
    'Sam Rivers',
    'Great, I\'ll bring the maps and some extra water.',
    51,
  ),
  _question,
  _message(104, 'sam', 'Sam Rivers', 'Works for me.', 39, parent: _question),
  _message(
    105,
    'daniel',
    'Daniel Ortiz',
    'I\'ll be there. Can we call tonight and sort out who\'s driving?',
    12,
  ),
  _message(106, 'maya', 'Maya Chen', 'Sure, how about 7?', 3),
];

class _DemoSource implements ChatSource {
  @override
  Future<List<ChatMessage>> chatHistory(String t, {int? beforeId}) async =>
      beforeId == null ? _chat : [];
  @override
  Future<List<ChatMessage>> chatWait(String t, int afterId) =>
      Completer<List<ChatMessage>>().future;
  @override
  Future<ChatMessage> chatSend(String t, String x, String r, {int? replyTo}) =>
      throw UnimplementedError();
  @override
  Future<void> chatMarkRead(String t, int id) async {}
  @override
  Future<void> chatReact(
    String t,
    int m,
    String e, {
    required bool remove,
  }) async {}
  @override
  Future<ChatMessage?> chatEdit(String t, int m, String x) async => null;
  @override
  Future<ChatMessage?> chatDelete(String t, int m) async => null;
  @override
  Future<bool> chatUploadsAllowed() async => true;
  @override
  Future<String> chatUpload(String p) => throw UnimplementedError();
  @override
  Future<void> chatShareFile(String t, String p, String r) async {}
  @override
  Future<Uint8List> chatPreview(int f) => throw UnimplementedError();
}

final _hike = Room(
  'hike',
  'Weekend hike',
  false,
  2,
  selfId: 'sam',
  lastRead: 106,
  lastActivity: _now - 180,
  lastMessage: _chat.last,
  canArchive: true,
);

Room _room(
  String token,
  String name,
  int type,
  String text,
  int minutesAgo, {
  int unread = 0,
  bool hasCall = false,
  String? from,
}) => Room(
  token,
  name,
  hasCall,
  type,
  selfId: 'sam',
  unread: unread,
  lastActivity: _now - minutesAgo * 60,
  lastMessage: type == 6
      ? _message(1, 'sam', 'Sam Rivers', text, minutesAgo)
      : _message(1, from ?? token, from ?? name, text, minutesAgo),
  canArchive: true,
);

final _rooms = [
  _hike,
  _room('priya', 'Priya Nair', 1, 'Sending the photos over now', 25, unread: 2),
  _room(
    'book',
    'Book club',
    3,
    'Next month\'s pick is up to you',
    95,
    from: 'Marco Silva',
  ),
  _room('jordan', 'Jordan Lee', 1, 'Thanks for your help today!', 240),
  _room(
    'team',
    'Garden project',
    2,
    'The seeds arrived',
    1500,
    from: 'Maya Chen',
  ),
  _room('note', 'Note to self', 6, 'Renew the parking permit', 4000),
];

final _demoCreds = Credentials('https://cloud.example.com', 'sam', 'x');

final _rootKey = GlobalKey();

Widget _app(Widget home, {Brightness brightness = Brightness.dark}) =>
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: talaTheme(accents.first, brightness),
        home: home,
      ),
    );

Widget _main() {
  final settings = AppSettings();
  return Scaffold(
    body: ChatLayout(
      rooms: _rooms,
      roomsError: null,
      selected: _hike,
      onSelect: (_) {},
      onRefresh: () {},
      onRemove: (_) {},
      onArchive: (_) {},
      settings: settings,
      menu: AppMenu(
        settings: settings,
        creds: _demoCreds,
        onChangeAccount: (_) {},
      ),
      onNewConversation: () {},
      conversation: ConversationPane(
        source: _DemoSource(),
        room: _hike,
        drafts: {},
        onBack: () {},
        onCall: () {},
      ),
    ),
  );
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary =
        _rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _loadFont(String family, List<String> files) async {
  final dir =
      '${Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/snap/flutter/common/flutter'}'
      '/bin/cache/artifacts/material_fonts';
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File('$dir/$f').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

void main() {
  // The menu only offers Start at login once the native side answers.
  TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('tala/tray'), (call) async {
        return call.method == 'getAutostart' ? false : null;
      });

  setUpAll(() async {
    await _loadFont('Roboto', [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
    ]);
    await _loadFont('MaterialIcons', ['MaterialIcons-Regular.otf']);
  });

  Future<void> scene(
    WidgetTester tester,
    String name,
    Widget home, {
    Brightness brightness = Brightness.dark,
    Size size = const Size(1100, 700),
    Future<void> Function()? then,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    // Real shadows. The test framework insists on its setting at the end.
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(home, brightness: brightness));
    await _settle(tester);
    if (then != null) await then();
    await _settle(tester);
    await _shot(tester, name);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    debugDisableShadows = true;
  }

  testWidgets('main, dark', (t) => scene(t, 'main-dark', _main()));

  testWidgets(
    'main, light',
    (t) => scene(t, 'main-light', _main(), brightness: Brightness.light),
  );

  testWidgets('sign in', (t) {
    return scene(
      t,
      'sign-in',
      LoginPage(onSignedIn: (_) {}),
      size: const Size(800, 500),
    );
  });

  testWidgets('menu', (t) {
    return scene(
      t,
      'menu',
      _main(),
      then: () async {
        await t.tap(find.byTooltip('Menu'));
      },
    );
  });

  Future<void> dialog(WidgetTester t, Widget d) async {
    unawaited(
      showDialog<void>(
        context: t.element(find.byType(ChatLayout)),
        builder: (_) => d,
      ),
    );
  }

  testWidgets('appearance', (t) {
    return scene(
      t,
      'appearance',
      _main(),
      then: () => dialog(t, AppearanceDialog(settings: AppSettings())),
    );
  });

  testWidgets('new conversation', (t) {
    return scene(
      t,
      'new-conversation',
      _main(),
      then: () async {
        await dialog(
          t,
          NewConversationDialog(
            search: (_) async => [
              Person('maya', 'Maya Chen', ''),
              Person('marco', 'Marco Silva', ''),
            ],
            onInviteGuest: () {},
          ),
        );
        await _settle(t);
        await t.enterText(find.byType(TextField).last, 'ma');
        await t.pump(const Duration(milliseconds: 400));
      },
    );
  });

  testWidgets('guest link', (t) {
    return scene(
      t,
      'guest-link',
      _main(),
      then: () => dialog(
        t,
        GuestLinkDialog(
          name: 'Book club',
          link: 'https://cloud.example.com/index.php/call/x7k2mq9p',
          hasPassword: false,
          canManage: true,
          invite: (_) async {},
          turnOff: () async => false,
        ),
      ),
    );
  });

  testWidgets('incoming call', (t) {
    return scene(
      t,
      'incoming-call',
      _main(),
      then: () => dialog(t, const IncomingCallDialog(name: 'Daniel Ortiz')),
    );
  });

  testWidgets('report a problem', (t) {
    return scene(
      t,
      'report',
      _main(),
      size: const Size(1100, 800),
      then: () => dialog(
        t,
        ReportDialog(
          facts: Future.value('Tray host: yes'),
          send: (_) async => const ReportOutcome(ReportResult.sent),
        ),
      ),
    );
  });
}
