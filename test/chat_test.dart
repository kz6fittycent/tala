import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart';
import 'package:tala/src/chat_view.dart';
import 'package:tala/src/nc_api.dart';

ChatMessage msg(int id,
        {String text = 'hi',
        String system = '',
        String ref = '',
        ChatMessage? parent}) =>
    ChatMessage(
      id: id,
      actorType: 'users',
      actorId: 'bob',
      actorName: 'Bob',
      timestamp: 1000 + id,
      segments: [Segment(text, SegmentKind.text)],
      systemKind: system,
      referenceId: ref,
      parent: parent,
    );

class FakeSource implements ChatSource {
  List<ChatMessage> Function(int? beforeId) history = (_) => [];
  Object? historyError;
  final List<Completer<List<ChatMessage>>> waits = [];
  final List<int> waitAfter = [];
  final List<Completer<ChatMessage>> sends = [];
  final List<String> sent = [];
  final List<int> marked = [];

  @override
  Future<List<ChatMessage>> chatHistory(String token, {int? beforeId}) async {
    final e = historyError;
    if (e != null) throw e;
    return history(beforeId);
  }

  @override
  Future<List<ChatMessage>> chatWait(String token, int afterId) {
    waitAfter.add(afterId);
    final c = Completer<List<ChatMessage>>();
    waits.add(c);
    return c.future;
  }

  @override
  Future<ChatMessage> chatSend(String token, String text, String ref) {
    sent.add(ref);
    final c = Completer<ChatMessage>();
    sends.add(c);
    return c.future;
  }

  @override
  Future<void> chatMarkRead(String token, int id) async => marked.add(id);
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('parseMessage', () {
    test('fills mentions and files, and tolerates an empty list of params', () {
      final s = parseMessage('{mention-user1} see {file}', {
        'mention-user1': {'type': 'user', 'name': 'Ann'},
        'file': {'type': 'file', 'name': 'a.pdf', 'link': 'https://x/f/1'},
      });
      expect(s.map((e) => e.kind),
          [SegmentKind.mention, SegmentKind.text, SegmentKind.file]);
      expect(s.last.url, 'https://x/f/1');
      expect(s.first.text, 'Ann');
    });

    test('leaves unknown placeholders as typed', () {
      expect(parseMessage('use {foo} here', {}).single.text, 'use {foo} here');
    });

    test('finds links without trailing punctuation', () {
      final s = parseMessage('see https://a.b/c, ok', {});
      expect(s[1].url, 'https://a.b/c');
      expect(s[2].text, ', ok');
    });

    test('never makes other schemes clickable', () {
      expect(
          parseMessage('javascript:alert(1) file:///etc/passwd', {})
              .every((s) => s.url == null),
          isTrue);
      final f = parseMessage('{file}', {
        'file': {'type': 'file', 'name': 'x', 'link': 'file:///etc/passwd'},
      });
      expect(f.single.url, isNull);
    });
  });

  group('ChatMessage.fromJson', () {
    test('handles the server sending empty lists where objects go', () {
      final m = ChatMessage.fromJson({
        'id': 5,
        'message': 'hello',
        'messageParameters': <dynamic>[],
        'parent': <dynamic>[],
        'reactions': <dynamic>[],
      });
      expect(m.text, 'hello');
      expect(m.parent, isNull);
    });

    test('reads a reply and a deleted parent', () {
      final m = ChatMessage.fromJson({
        'id': 6,
        'message': 'x',
        'parent': {'id': 2, 'deleted': true, 'message': 'gone'},
      });
      expect(m.parent!.id, 2);
      expect(m.parentDeleted, isTrue);
    });
  });

  group('Room.fromJson', () {
    Room room(Map<String, dynamic> extra) => Room.fromJson({
          'token': 't',
          'displayName': 'n',
          'type': 2,
          'lastMessage': <dynamic>[],
          ...extra,
        });

    test('tolerates an empty last message', () {
      expect(room({}).lastMessage, isNull);
    });

    test('read-only conversations allow neither chat nor calls', () {
      final r = room({'readOnly': 1});
      expect(r.canChat, isFalse);
      expect(r.canCall, isFalse);
    });

    test('Note to self has chat but no calls', () {
      final r = room({'type': 6});
      expect(r.canChat, isTrue);
      expect(r.canCall, isFalse);
    });

    test('missing chat permission blocks sending', () {
      expect(room({'permissions': 1}).canChat, isFalse);
      expect(room({'permissions': 128}).canChat, isTrue);
    });
  });

  group('ChatThread', () {
    late FakeSource src;
    late ChatThread t;

    setUp(() {
      src = FakeSource();
      t = ChatThread(src, 'tok',
          retryStart: Duration.zero,
          retryMax: Duration.zero,
          minPollGap: Duration.zero);
    });
    tearDown(() => t.dispose());

    test('loads history in order, then waits after the newest id', () async {
      src.history = (_) => [msg(3), msg(1), msg(2)];
      t.start();
      await settle();
      expect(t.messages.map((m) => m.id), [1, 2, 3]);
      expect(t.loading, isFalse);
      expect(src.waitAfter, [3]);
    });

    test('bookkeeping entries stay hidden but advance the position', () async {
      src.history = (_) => [msg(1), msg(2, system: 'reaction')];
      t.start();
      await settle();
      expect(t.messages.map((m) => m.id), [1]);
      expect(src.waitAfter, [2]);
    });

    test('a live delete replaces the original message', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      src.waits.last.complete([
        msg(2, system: 'message_deleted', parent: msg(1, text: 'removed')),
      ]);
      await settle();
      expect(t.messages.single.text, 'removed');
      expect(src.waitAfter.last, 2);
    });

    test('a stale snapshot in old history does not overwrite', () async {
      src.history = (before) => before == null
          ? [msg(5, text: 'current')]
          : [msg(4, system: 'message_edited', parent: msg(5, text: 'stale'))];
      t.start();
      await settle();
      await t.loadOlder();
      expect(t.messages.single.text, 'current');
    });

    test('history_cleared empties the list', () async {
      src.history = (_) => [msg(1), msg(2)];
      t.start();
      await settle();
      src.waits.last.complete([msg(3, system: 'history_cleared')]);
      await settle();
      expect(t.messages.map((m) => m.id), [3]);
    });

    test('paging older stops once the server has no more', () async {
      src.history = (before) => before == null ? [msg(5), msg(6)] : [];
      t.start();
      await settle();
      await t.loadOlder();
      expect(t.hasOlder, isFalse);
    });

    test('a sent message appears once when the poll arrives first', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      unawaited(t.send('new'));
      await settle();
      expect(t.outgoing, hasLength(1));
      final ref = src.sent.single;
      src.waits.last.complete([msg(2, text: 'new', ref: ref)]);
      await settle();
      expect(t.outgoing, isEmpty);
      src.sends.single.complete(msg(2, text: 'new', ref: ref));
      await settle();
      expect(t.messages.where((m) => m.text == 'new'), hasLength(1));
    });

    test('sending does not skip a message that came just before it', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      unawaited(t.send('mine'));
      await settle();
      src.sends.single.complete(msg(5, text: 'mine'));
      await settle();
      src.waits.last.complete([msg(4, text: 'theirs'), msg(5, text: 'mine')]);
      await settle();
      expect(t.messages.map((m) => m.id), [1, 4, 5]);
      expect(src.waitAfter, [1, 5]);
    });

    test('a failed send stays for retry with the same reference', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      unawaited(t.send('x'));
      await settle();
      src.sends.single.completeError(ApiException(500, 'p'));
      await settle();
      final o = t.outgoing.single;
      expect(o.state, SendState.failed);
      unawaited(t.retry(o));
      await settle();
      expect(o.state, SendState.sending);
      expect(src.sent[0], src.sent[1]);
      src.sends.last.complete(msg(2, text: 'x'));
      await settle();
      expect(t.outgoing, isEmpty);
    });

    test('blank messages are not sent', () async {
      await t.send('  \n ');
      expect(src.sent, isEmpty);
    });

    test('marks read only while active', () async {
      t = ChatThread(src, 'tok', lastRead: 1, minPollGap: Duration.zero);
      src.history = (_) => [msg(1), msg(2)];
      t.start();
      await settle();
      expect(src.marked, isEmpty);
      src.waits.last.complete([msg(3)]);
      await settle();
      expect(src.marked, isEmpty);
      t.active = true;
      expect(src.marked, [3]);
      src.waits.last.complete([msg(4)]);
      await settle();
      expect(src.marked, [3, 4]);
    });

    test('already read messages are not marked again', () async {
      t = ChatThread(src, 'tok', lastRead: 2, minPollGap: Duration.zero);
      src.history = (_) => [msg(1), msg(2)];
      t.active = true;
      t.start();
      await settle();
      expect(src.marked, isEmpty);
    });

    test('a removed conversation stops polling', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      src.waits.last.completeError(ApiException(404, 'p'));
      await settle();
      expect(t.gone, isTrue);
      expect(src.waits, hasLength(1));
    });

    test('a connection failure reports, retries, and recovers', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      src.waits.last.completeError(ApiException(502, 'p'));
      await settle();
      expect(t.problem, isNotNull);
      await settle();
      expect(src.waits, hasLength(2));
      src.waits.last.complete([msg(2)]);
      await settle();
      expect(t.problem, isNull);
      expect(t.messages, hasLength(2));
    });

    test('a failing first load retries instead of hanging', () async {
      src.historyError = ApiException(502, 'p');
      t.start();
      await settle();
      expect(t.problem, isNotNull);
      expect(t.loading, isTrue);
      src
        ..historyError = null
        ..history = (_) => [msg(1)];
      await settle();
      await settle();
      expect(t.loading, isFalse);
      expect(t.problem, isNull);
    });
  });

  group('screens', () {
    Room room({bool canChat = true, int unread = 0}) => Room('t', 'Family', false, 2,
        canChat: canChat, unread: unread, selfId: 'me', lastRead: 1);

    Widget pane(FakeSource src, Room r) => MaterialApp(
          home: Scaffold(
            body: ConversationPane(
              source: src,
              room: r,
              drafts: {},
              onBack: () {},
              onCall: () {},
            ),
          ),
        );

    testWidgets('Enter sends and Shift+Enter does not', (tester) async {
      final src = FakeSource()..history = (_) => [msg(1)];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(src.sent, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(src.sent, hasLength(1));
      expect(find.text('Sending…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no composer when chat is not allowed', (tester) async {
      final src = FakeSource()..history = (_) => [msg(1)];
      await tester.pumpWidget(pane(src, room(canChat: false)));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('You can\'t send messages here.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('marks where new messages start', (tester) async {
      final src = FakeSource()..history = (_) => [msg(1), msg(2)];
      await tester.pumpWidget(pane(src, room(unread: 1)));
      await tester.pump();
      expect(find.text('New messages'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    Widget layout(double width, {bool withConversation = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(width, 700)),
            child: Scaffold(
              body: ChatLayout(
                rooms: [room()],
                roomsError: null,
                selected: null,
                onSelect: (_) {},
                onRefresh: () {},
                conversation:
                    withConversation ? const Text('conversation') : null,
              ),
            ),
          ),
        );

    testWidgets('the conversation list stays visible at 800 wide',
        (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(layout(800, withConversation: true));
      expect(find.text('Conversations'), findsOneWidget);
      expect(find.text('conversation'), findsOneWidget);
    });

    testWidgets('a narrow window shows one pane at a time', (tester) async {
      tester.view.physicalSize = const Size(500, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(layout(500, withConversation: true));
      expect(find.text('Conversations'), findsNothing);
      expect(find.text('conversation'), findsOneWidget);
    });
  });
}
