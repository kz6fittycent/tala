import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart';
import 'package:tala/src/chat_view.dart';
import 'package:tala/src/drafts.dart';
import 'package:tala/src/file_drop.dart';
import 'package:tala/src/mentions.dart';
import 'package:tala/src/app_colors.dart';
import 'package:tala/src/app_info.dart';
import 'package:tala/src/app_menu.dart';
import 'package:tala/src/settings.dart';
import 'package:tala/src/nc_api.dart';
import 'package:tala/src/new_conversation.dart';

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

/// Saves at once to a throwaway file, so no timer outlives a test.
DraftStore testDrafts({File? file, String account = 'me@https://cloud'}) =>
    DraftStore(
      account: account,
      file: file ??
          File('${Directory.systemTemp.createTempSync('tala-drafts').path}/d.json'),
      saveDelay: Duration.zero,
    );

class FakeSource implements ChatSource {
  List<ChatMessage> Function(int? beforeId) history = (_) => [];
  Object? historyError;
  final List<Completer<List<ChatMessage>>> waits = [];
  final List<int> waitAfter = [];
  final List<Completer<ChatMessage>> sends = [];
  final List<String> sent = [];
  final List<String> sentTexts = [];
  final List<int> marked = [];
  final List<int?> replies = [];
  final List<String> reacted = [];
  final List<String> uploads = [];
  final List<String> shares = [];
  bool uploadsAllowed = true;
  Object? uploadError, shareError, reactError;

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

  final List<String> edits = [];
  final List<int> deletes = [];
  ChatMessage? changed;
  Object? changeError;

  @override
  Future<ChatMessage?> chatEdit(String token, int id, String text) async {
    edits.add('$id:$text');
    final e = changeError;
    if (e != null) throw e;
    return changed;
  }

  @override
  Future<ChatMessage?> chatDelete(String token, int id) async {
    deletes.add(id);
    final e = changeError;
    if (e != null) throw e;
    return changed;
  }

  @override
  Future<bool> chatUploadsAllowed() async => uploadsAllowed;

  UploadControl? lastUpload;
  Completer<void>? uploadGate;

  @override
  Future<String> chatUpload(String localPath, {UploadControl? control}) async {
    uploads.add(localPath);
    lastUpload = control;
    control?.onProgress?.call(1, 4);
    final gate = uploadGate;
    if (gate != null) await gate.future;
    control?.throwIfCancelled();
    final e = uploadError;
    if (e != null) throw e;
    return '/Talk/f';
  }

  @override
  Future<void> chatShareFile(String token, String remote, String ref) async {
    shares.add(remote);
    final e = shareError;
    if (e != null) throw e;
  }

  @override
  Future<Uint8List> chatPreview(int fileId) async => Uint8List(0);

  List<MentionOption> mentionOptions = const [];
  final List<String> mentionSearches = [];
  Object? mentionError;

  @override
  Future<List<MentionOption>> chatMentions(String token, String search) async {
    mentionSearches.add(search);
    final e = mentionError;
    if (e != null) throw e;
    return mentionOptions;
  }

  @override
  Future<void> chatReact(String token, int id, String emoji,
      {required bool remove}) async {
    reacted.add('${remove ? '-' : '+'}$emoji');
    final e = reactError;
    if (e != null) throw e;
  }

  @override
  Future<ChatMessage> chatSend(String token, String text, String ref,
      {int? replyTo}) {
    sent.add(ref);
    sentTexts.add(text);
    replies.add(replyTo);
    final c = Completer<ChatMessage>();
    sends.add(c);
    return c.future;
  }

  @override
  Future<void> chatMarkRead(String token, int id) async => marked.add(id);

  int? lastCommonRead;

  @override
  int? chatLastCommonRead(String token) => lastCommonRead;
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

/// Never the user's real settings file.
AppSettings tempPrefs() => AppSettings(
  file: File('${Directory.systemTemp.createTempSync('tala').path}/s.json'),
);

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

    test('only previewable images get a preview', () {
      Segment file(Map<String, dynamic> extra) => parseMessage('{file}', {
            'file': {'type': 'file', 'name': 'x', 'id': '7', ...extra},
          }).single;
      expect(
          file({'mimetype': 'image/png', 'preview-available': 'yes'})
              .previewFileId,
          7);
      expect(
          file({'mimetype': 'image/png', 'preview-available': 'no'})
              .previewFileId,
          isNull);
      expect(
          file({'mimetype': 'application/pdf', 'preview-available': 'yes'})
              .previewFileId,
          isNull);
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

  group('editableText', () {
    test('puts mentions back in the form the server reads', () {
      expect(
          editableText('hi {mention-user1} and {mention-guest1}', {
            'mention-user1': {
              'type': 'user',
              'name': 'Ann Lee',
              'id': 'ann',
              'mention-id': 'ann lee',
            },
            'mention-guest1': {'type': 'guest', 'name': 'G', 'id': 'guest/x'},
          }),
          'hi @"ann lee" and @"guest/x"');
    });

    test('leaves text with braces alone', () {
      expect(editableText('use {foo} here', {}), 'use {foo} here');
    });
  });

  group('ChatMessage.fromJson', () {
    test('a file message cannot be edited but can be deleted', () {
      final m = ChatMessage.fromJson({
        'id': 1,
        'message': '{file}',
        'messageParameters': {
          'file': {'type': 'file', 'name': 'a.pdf'},
        },
      });
      expect(m.canEdit, isFalse);
      expect(m.canDelete, isTrue);
    });

    test('system and deleted messages cannot be changed', () {
      final sys = ChatMessage.fromJson(
          {'id': 1, 'message': 'x', 'systemMessage': 'call_ended'});
      final gone = ChatMessage.fromJson(
          {'id': 2, 'message': 'x', 'messageType': 'comment_deleted'});
      for (final m in [sys, gone]) {
        expect(m.canEdit, isFalse);
        expect(m.canDelete, isFalse);
      }
    });

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

    test('call arrivals and departures stay out of the chat', () async {
      src.history = (_) => [
            msg(1, system: 'call_started'),
            msg(2, system: 'call_joined'),
            msg(3, system: 'call_left'),
            msg(4, system: 'call_ended'),
          ];
      t.start();
      await settle();
      expect(t.messages.map((m) => m.id), [1, 4]);
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

    test('a reply carries the id of the message it answers', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      unawaited(t.send('yes', replyTo: 1));
      await settle();
      expect(src.replies.single, 1);
    });

    test('reacting shows immediately and toggles off', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      expect(await t.toggleReaction(1, '👍'), isTrue);
      expect(t.messages.single.reactions['👍'], 1);
      expect(t.messages.single.reactionsSelf, ['👍']);
      expect(await t.toggleReaction(1, '👍'), isTrue);
      expect(t.messages.single.reactions, isEmpty);
      expect(src.reacted, ['+👍', '-👍']);
    });

    test('a refused reaction is rolled back', () async {
      src
        ..history = ((_) => [msg(1)])
        ..reactError = ApiException(403, 'p');
      t.start();
      await settle();
      expect(await t.toggleReaction(1, '👍'), isFalse);
      expect(t.messages.single.reactions, isEmpty);
    });

    test('a live reaction update replaces the counts', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      src.waits.last.complete([
        ChatMessage.fromJson({
          'id': 2,
          'systemMessage': 'reaction',
          'message': '',
          'parent': {
            'id': 1,
            'message': 'hi',
            'reactions': {'🎉': 2},
            'reactionsSelf': ['🎉'],
          },
        }),
      ]);
      await settle();
      expect(t.messages.single.reactions, {'🎉': 2});
      expect(t.messages.single.reactionsSelf, ['🎉']);
    });

    test('a file uploads, then shares, then clears', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      await t.sendFile('/home/me/a.pdf');
      expect(src.uploads, ['/home/me/a.pdf']);
      expect(src.shares, ['/Talk/f']);
      expect(t.outgoing, isEmpty);
    });

    test('an upload reports progress and can be cancelled', () async {
      src
        ..history = ((_) => [msg(1)])
        ..uploadGate = Completer<void>();
      t.start();
      await settle();
      final sending = t.sendFile('/home/me/a.pdf');
      await settle();
      final o = t.outgoing.single;
      expect(o.progress, 0.25);
      t.cancelUpload(o);
      expect(t.outgoing, isEmpty);
      expect(src.lastUpload!.cancelled, isTrue);
      src.uploadGate!.complete();
      await sending;
      expect(src.shares, isEmpty);
      expect(t.outgoing, isEmpty);
    });

    test('retrying after a failed share does not upload again', () async {
      src
        ..history = ((_) => [msg(1)])
        ..shareError = ApiException(500, 'p');
      t.start();
      await settle();
      await t.sendFile('/home/me/a.pdf');
      final o = t.outgoing.single;
      expect(o.state, SendState.failed);
      expect(o.text, 'a.pdf');
      src.shareError = null;
      await t.retry(o);
      expect(src.uploads, hasLength(1));
      expect(src.shares, hasLength(2));
      expect(t.outgoing, isEmpty);
    });

    test('a failed upload explains a full server', () async {
      src
        ..history = ((_) => [msg(1)])
        ..uploadError = ApiException(507, 'p');
      t.start();
      await settle();
      await t.sendFile('/home/me/a.pdf');
      expect(t.outgoing.single.error, contains('storage'));
    });

    test('an edit replaces the message from the response', () async {
      src
        ..history = ((_) => [msg(1)])
        ..changed = msg(1, text: 'new');
      t.start();
      await settle();
      expect(await t.editMessage(1, ' new '), isNull);
      expect(src.edits, ['1:new']);
      expect(t.messages.single.text, 'new');
    });

    test('a refused edit explains why and changes nothing', () async {
      src
        ..history = ((_) => [msg(1)])
        ..changeError = ApiException(400, 'p');
      t.start();
      await settle();
      expect(await t.editMessage(1, 'new'), contains('24 hours'));
      expect(t.messages.single.text, 'hi');
    });

    test('an empty edit never reaches the server', () async {
      src.history = (_) => [msg(1)];
      t.start();
      await settle();
      expect(await t.editMessage(1, '  '), isNotNull);
      expect(src.edits, isEmpty);
    });

    test('a delete replaces the message and reports refusals', () async {
      src
        ..history = ((_) => [msg(1)])
        ..changed = msg(1, text: 'Message deleted by you');
      t.start();
      await settle();
      expect(await t.deleteMessage(1), isNull);
      expect(t.messages.single.text, 'Message deleted by you');
      src.changeError = ApiException(403, 'p');
      expect(await t.deleteMessage(1), contains('can\'t delete'));
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
              drafts: testDrafts(),
              onBack: () {},
              onCall: () {},
            ),
          ),
        );

    testWidgets('inside a call, chat fits a narrow panel with no header',
        (tester) async {
      final src = FakeSource()
        ..history = (_) => [
              msg(1),
              for (var i = 2; i < 6; i++)
                ChatMessage.fromJson({
                  'id': i,
                  'actorType': 'users',
                  'actorId': 'pat',
                  'actorDisplayName': 'A very long display name indeed, yes',
                  'timestamp': 1700000000 + i,
                  'message': 'https://example.com/${'long-link-' * 12} and '
                      '${'words ' * 40}',
                  'messageParameters': <String, dynamic>{},
                  'systemMessage': '',
                  'messageType': 'comment',
                }),
            ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              height: 400,
              child: ConversationPane(
                source: src,
                room: room(),
                drafts: testDrafts(),
                showHeader: false,
                onBack: () {},
                onCall: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Start a call'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    group('formatted messages', () {
      ChatMessage formatted(String raw) => ChatMessage.fromJson({
        'id': 1,
        'actorType': 'users',
        'actorId': 'x',
        'actorDisplayName': 'Xan',
        'timestamp': 1700000000,
        'markdown': true,
        'message': raw,
      });

      testWidgets('every block fits a narrow window', (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final src = FakeSource()
          ..history = ((_) => [
            formatted(
              '# A long heading that needs to wrap around the narrow bubble\n'
              '- A list item long enough that it has to wrap in a narrow one\n'
              '  - And a nested one, also long enough that it has to wrap\n'
              '> A quote long enough that it has to wrap in a narrow bubble\n'
              '---\n'
              '```\na very long line of code that cannot wrap and must scroll\n```',
            ),
          ]);
        await tester.pumpWidget(pane(src, room()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('A long heading', findRichText: true), findsOneWidget);
        expect(find.textContaining('must scroll', findRichText: true), findsOneWidget);
        expect(find.text('•'), findsNWidgets(2));
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('a link in a formatted message is tappable', (tester) async {
        final src = FakeSource()
          ..history = ((_) => [formatted('see [the map](https://x.example/m)')]);
        await tester.pumpWidget(pane(src, room()));
        await tester.pumpAndSettle();
        final text = tester.widget<RichText>(
          find.textContaining('the map', findRichText: true),
        );
        final spans = <TextSpan>[];
        text.text.visitChildren((s) {
          if (s is TextSpan) spans.add(s);
          return true;
        });
        final link = spans.firstWhere((s) => s.text == 'the map');
        expect(link.recognizer, isNotNull);
        expect(link.style?.decoration, TextDecoration.underline);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('the same words stay as typed when the server says plain', (
        tester,
      ) async {
        final src = FakeSource()
          ..history = ((_) => [
            ChatMessage.fromJson({
              'id': 1,
              'actorType': 'users',
              'actorId': 'x',
              'timestamp': 1700000000,
              'markdown': false,
              'message': '**not bold**',
            }),
          ]);
        await tester.pumpWidget(pane(src, room()));
        await tester.pumpAndSettle();
        expect(find.textContaining('**not bold**', findRichText: true), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    });

    group('mention suggestions', () {
      FakeSource source() => FakeSource()
        ..history = ((_) => [msg(1)])
        ..mentionOptions = const [
          MentionOption(id: 'me', label: 'Myself'),
          MentionOption(id: 'maya.c', label: 'Maya Chen', mentionId: 'maya.c'),
          MentionOption(id: 'marco', label: 'Marco Silva'),
          MentionOption(
            id: 'all',
            label: 'Family',
            source: 'calls',
            details: 'All 3 participants',
          ),
        ];

      Future<void> type(WidgetTester tester, String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();
      }

      testWidgets('@ offers people but not yourself, and picking inserts the '
          'name while the server gets the id', (tester) async {
        final src = source();
        await tester.pumpWidget(pane(src, room()));
        await tester.pump();
        await type(tester, 'hi @ma');
        expect(src.mentionSearches, ['ma']);
        expect(find.text('Maya Chen'), findsOneWidget);
        expect(find.text('All 3 participants'), findsOneWidget);
        expect(find.text('Myself'), findsNothing);
        await tester.tap(find.text('Maya Chen'));
        await tester.pump();
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, 'hi @Maya Chen ');
        expect(field.controller!.selection.baseOffset, 14);
        expect(find.text('Marco Silva'), findsNothing);
        await tester.enterText(find.byType(TextField), 'hi @Maya Chen, and you');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(src.sentTexts, ['hi @"maya.c", and you']);
        // Until the server's copy arrives, it reads as it was typed.
        expect(find.textContaining('@Maya Chen', findRichText: true), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('arrows choose, Enter picks instead of sending, Escape closes',
          (tester) async {
        final src = source();
        await tester.pumpWidget(pane(src, room()));
        await tester.pump();
        await type(tester, '@m');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(src.sentTexts, isEmpty);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, '@Marco Silva ');

        await type(tester, '@Marco Silva @x');
        expect(find.text('Maya Chen'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.text('Maya Chen'), findsNothing);
        // More typing in that same mention doesn't reopen the list.
        await type(tester, '@Marco Silva @xy');
        expect(find.text('Maya Chen'), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(src.sentTexts, ['@"marco" @xy']);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('an email address offers nothing, and a failed search is '
          'quiet', (tester) async {
        final src = source();
        await tester.pumpWidget(pane(src, room()));
        await tester.pump();
        await type(tester, 'pat@example.com');
        expect(src.mentionSearches, isEmpty);
        src.mentionError = ApiException(500, 'p');
        await type(tester, '@sam');
        expect(src.mentionSearches, ['sam']);
        expect(find.byType(ListTile), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('a name picked in a draft survives leaving the conversation',
          (tester) async {
        final src = source();
        final drafts = testDrafts();
        Widget open(Key key) => MaterialApp(
          home: Scaffold(
            body: ConversationPane(
              key: key,
              source: src,
              room: room(),
              drafts: drafts,
              onBack: () {},
              onCall: () {},
            ),
          ),
        );
        await tester.pumpWidget(open(const ValueKey(1)));
        await tester.pump();
        await type(tester, '@m');
        await tester.tap(find.text('Marco Silva'));
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(open(const ValueKey(2)));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(src.sentTexts, ['@"marco"']);
        await tester.pumpWidget(const SizedBox());
      });
    });

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

    testWidgets('a reply goes out with its target, then the bar clears',
        (tester) async {
      final src = FakeSource()
        ..history = (_) => [
              ChatMessage.fromJson({
                'id': 1,
                'actorDisplayName': 'Bob',
                'message': 'question',
                'isReplyable': true,
              }),
            ];
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      await tester.tap(find.byTooltip('Reply'));
      await tester.pump();
      expect(find.textContaining('Replying to Bob'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.textContaining('Replying to Bob'), findsNothing);
      await tester.tap(find.byTooltip('Reply'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'answer');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(src.replies.single, 1);
      expect(find.textContaining('Replying to Bob'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('system messages offer no reply or reaction', (tester) async {
      final src = FakeSource()
        ..history = (_) => [
              ChatMessage.fromJson({
                'id': 1,
                'systemMessage': 'call_ended',
                'messageType': 'system',
                'message': 'Call ended',
              }),
            ];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      expect(find.text('Call ended'), findsOneWidget);
      expect(find.byTooltip('Reply'), findsNothing);
      expect(find.byTooltip('Add a reaction'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    ChatMessage json(int id, String actor, String text) =>
        ChatMessage.fromJson({
          'id': id,
          'actorType': 'users',
          'actorId': actor,
          'actorDisplayName': actor,
          'message': text,
          'isReplyable': true,
        });

    Future<void> openMenu(WidgetTester tester, String text) async {
      await tester.tap(find.text(text), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    void wide(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('dropped files upload, folders are skipped, with a hint while '
        'dragging', (tester) async {
      wide(tester);
      final dir = Directory.systemTemp.createTempSync('tala-drop');
      final file = File('${dir.path}/notes.txt')..writeAsStringSync('x');
      final src = FakeSource()..history = (_) => [msg(1)];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      FileDrops.instance.hovering.value = true;
      await tester.pump();
      expect(find.text('Drop to send to Family'), findsOneWidget);
      FileDrops.instance.hovering.value = false;
      await tester.pump();
      expect(find.text('Drop to send to Family'), findsNothing);
      await tester.runAsync(() async {
        FileDrops.instance.deliver([file.path, dir.path]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(src.uploads, [file.path]);
      expect(find.text('Folders can\'t be sent, only files.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(FileDrops.instance.hasTarget, isFalse);
    });

    testWidgets('own messages show sent, then read once everyone has',
        (tester) async {
      wide(tester);
      final src = FakeSource()
        ..lastCommonRead = 1
        ..history = (_) => [
              json(1, 'me', 'first'),
              json(2, 'me', 'second'),
              json(3, 'bob', 'theirs'),
            ];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      expect(find.byTooltip('Read'), findsOneWidget);
      expect(find.byTooltip('Sent'), findsOneWidget);
      src.lastCommonRead = 3;
      src.waits.last.complete([]);
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip('Read'), findsNWidgets(2));
      expect(find.byTooltip('Sent'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      // The poll's pause after an empty answer.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('no marks when the server keeps read status private',
        (tester) async {
      wide(tester);
      final src = FakeSource()..history = (_) => [json(1, 'me', 'first')];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      expect(find.byTooltip('Read'), findsNothing);
      expect(find.byTooltip('Sent'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('right-click on your own message offers edit and delete',
        (tester) async {
      wide(tester);
      final src = FakeSource()..history = (_) => [json(1, 'me', 'mine')];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      await openMenu(tester, 'mine');
      for (final item in ['Reply', 'Copy text', 'Edit', 'Delete…']) {
        expect(find.text(item), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('right-click on someone else\'s offers neither',
        (tester) async {
      wide(tester);
      final src = FakeSource()..history = (_) => [json(1, 'bob', 'theirs')];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      await openMenu(tester, 'theirs');
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete…'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a moderator can delete others\' messages but not edit them',
        (tester) async {
      wide(tester);
      final src = FakeSource()..history = (_) => [json(1, 'bob', 'theirs')];
      final r = Room('t', 'Family', false, 2,
          selfId: 'me', lastRead: 1, isModerator: true);
      await tester.pumpWidget(pane(src, r));
      await tester.pump();
      await openMenu(tester, 'theirs');
      expect(find.text('Delete…'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('deleting asks first, and Cancel does nothing', (tester) async {
      wide(tester);
      final src = FakeSource()..history = (_) => [json(1, 'me', 'mine')];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      await openMenu(tester, 'mine');
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(src.deletes, isEmpty);
      await openMenu(tester, 'mine');
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(src.deletes, [1]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('editing saves with Enter and restores the draft',
        (tester) async {
      wide(tester);
      final src = FakeSource()..history = (_) => [json(1, 'me', 'mine')];
      await tester.pumpWidget(pane(src, room()));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'half typed');
      await openMenu(tester, 'mine');
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Editing your message'), findsOneWidget);
      TextField field() => tester.widget<TextField>(find.byType(TextField));
      expect(field().controller!.text, 'mine');
      await tester.enterText(find.byType(TextField), 'changed');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(src.edits, ['1:changed']);
      expect(src.sent, isEmpty);
      expect(find.text('Editing your message'), findsNothing);
      expect(field().controller!.text, 'half typed');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Escape cancels an edit without saving', (tester) async {
      wide(tester);
      final src = FakeSource()..history = (_) => [json(1, 'me', 'mine')];
      final drafts = testDrafts();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ConversationPane(
            source: src,
            room: room(),
            drafts: drafts,
            onBack: () {},
            onCall: () {},
          ),
        ),
      ));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'draft');
      await openMenu(tester, 'mine');
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(drafts['t'], 'draft');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(src.edits, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'draft');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('right-click on a conversation offers removal', (tester) async {
      wide(tester);
      Room? removed;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatLayout(
            rooms: [room()],
            roomsError: null,
            selected: null,
            onSelect: (_) {},
            onRefresh: () {},
            onRemove: (r) => removed = r,
            onArchive: (_) {},
            settings: tempPrefs(),
            conversation: null,
          ),
        ),
      ));
      await openMenu(tester, 'Family');
      await tester.tap(find.text('Remove chat…'));
      await tester.pumpAndSettle();
      expect(removed?.token, 't');
    });

    testWidgets('the last moderator cannot pick removal', (tester) async {
      wide(tester);
      Room? removed;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatLayout(
            rooms: [Room('t', 'Family', false, 2, canLeave: false)],
            roomsError: null,
            selected: null,
            onSelect: (_) {},
            onRefresh: () {},
            onRemove: (r) => removed = r,
            onArchive: (_) {},
            settings: tempPrefs(),
            conversation: null,
          ),
        ),
      ));
      await openMenu(tester, 'Family');
      await tester.tap(find.textContaining('only moderator'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(removed, isNull);
    });

    testWidgets('delete for everyone is on the menu when offered',
        (tester) async {
      wide(tester);
      Room? deleted;
      Widget app(Room r) => MaterialApp(
            home: Scaffold(
              body: ChatLayout(
                rooms: [r],
                roomsError: null,
                selected: null,
                onSelect: (_) {},
                onRefresh: () {},
                onRemove: (_) {},
                onArchive: (_) {},
                onDelete: (r) => deleted = r,
                settings: tempPrefs(),
                conversation: null,
              ),
            ),
          );
      await tester.pumpWidget(app(Room('t', 'Family', false, 2)));
      await openMenu(tester, 'Family');
      expect(find.text('Delete for everyone…'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(Room('t', 'Picnic', false, 3, canDelete: true)));
      await openMenu(tester, 'Picnic');
      await tester.tap(find.text('Delete for everyone…'));
      await tester.pumpAndSettle();
      expect(deleted?.token, 't');
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
                onRemove: (_) {},
                onArchive: (_) {},
            settings: tempPrefs(),
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

    group('menu', () {
      Widget app(AppSettings settings, {ValueChanged<Credentials>? changed}) =>
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                actions: [
                  AppMenu(
                    settings: settings,
                    creds: Credentials('https://cloud.example/nc', 'me', 'pw'),
                    onChangeAccount: changed ?? (_) {},
                  ),
                ],
              ),
            ),
          );

      Future<void> open(WidgetTester tester) async {
        await tester.tap(find.byTooltip('Menu'));
        await tester.pumpAndSettle();
      }

      testWidgets('shows the account and sets the theme', (tester) async {
        wide(tester);
        final settings = tempPrefs();
        await tester.pumpWidget(app(settings));
        await open(tester);
        expect(find.text('me'), findsOneWidget);
        expect(find.text('cloud.example/nc'), findsOneWidget);
        await tester.tap(find.text('Appearance…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dark'));
        await tester.pump();
        expect(settings.themeMode, ThemeMode.dark);
        await tester.tap(find.byTooltip('Teal'));
        await tester.pump();
        expect(settings.accent.name, 'teal');
      });

      testWidgets('start at login shows the real state and changes it',
          (tester) async {
        wide(tester);
        const channel = MethodChannel('tala/tray');
        var enabled = true;
        final messenger =
            tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAutostart') return enabled;
          if (call.method == 'setAutostart') {
            enabled = call.arguments as bool;
            return true;
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.pumpWidget(app(tempPrefs()));
        await tester.pump();
        await open(tester);
        expect(
          tester
              .widget<CheckedPopupMenuItem<dynamic>>(find.ancestor(
                of: find.text('Start at login'),
                matching: find.byWidgetPredicate(
                    (w) => w is CheckedPopupMenuItem),
              ))
              .checked,
          isTrue,
        );
        await tester.tap(find.text('Start at login'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(enabled, isFalse);
      });

      testWidgets('start at login is hidden where it is not built',
          (tester) async {
        wide(tester);
        await tester.pumpWidget(app(tempPrefs()));
        await tester.pump();
        await open(tester);
        expect(find.text('Start at login'), findsNothing);
      });

      testWidgets('the message sound can be turned off', (tester) async {
        wide(tester);
        final settings = tempPrefs();
        expect(settings.messageSound, isTrue);
        await tester.pumpWidget(app(settings));
        await open(tester);
        await tester.tap(find.text('Message sound'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(settings.messageSound, isFalse);
      });

      testWidgets('About states the license and independence', (tester) async {
        wide(tester);
        await tester.pumpWidget(app(tempPrefs()));
        await open(tester);
        await tester.tap(find.text('About Tala'));
        await tester.pumpAndSettle();
        expect(find.text('Version $appVersion'), findsOneWidget);
        expect(find.textContaining('Affero'), findsOneWidget);
        expect(find.textContaining('not affiliated'), findsOneWidget);
      });

      testWidgets('changing server asks for a sign-in and starts on the old one',
          (tester) async {
        wide(tester);
        await tester.pumpWidget(app(tempPrefs()));
        await open(tester);
        await tester.tap(find.text('me'));
        await tester.pumpAndSettle();
        expect(find.text('Server: cloud.example/nc'), findsOneWidget);
        await tester.tap(find.text('Change server…'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'https://cloud.example/nc',
        );
      });

      testWidgets('a finished sign-in hands over the new account',
          (tester) async {
        Credentials? got;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SignInForm(
              onSignedIn: (c) => got = c,
              signIn: (url, {isCancelled}) async =>
                  Credentials(url, 'new', 'pw2'),
            ),
          ),
        ));
        await tester.enterText(find.byType(TextField), 'other.example/ ');
        await tester.tap(find.text('Sign in'));
        await tester.pump();
        expect(got?.server, 'https://other.example');
      });

      testWidgets('a sign-in can be cancelled', (tester) async {
        final never = Completer<Credentials>();
        Credentials? got;
        bool Function()? check;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SignInForm(
              onSignedIn: (c) => got = c,
              signIn: (url, {isCancelled}) {
                check = isCancelled;
                return never.future;
              },
            ),
          ),
        ));
        await tester.enterText(find.byType(TextField), 'other.example');
        await tester.tap(find.text('Sign in'));
        await tester.pump();
        await tester.tap(find.text('Cancel sign-in'));
        await tester.pump();
        expect(check!(), isTrue);
        expect(find.text('Sign in'), findsOneWidget);
        never.complete(Credentials('x', 'y', 'z'));
        await tester.pump();
        expect(got, isNull);
      });

      test('the version shown matches pubspec.yaml', () {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        expect(pubspec, contains('version: $appVersion+'));
      });
    });

    group('new conversation', () {
      testWidgets('a labeled button sits at the top of the list',
          (tester) async {
        var pressed = 0;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: RoomList(
              rooms: const [],
              error: null,
              selected: null,
              onSelect: (_) {},
              onRefresh: () {},
              onRemove: (_) {},
              onArchive: (_) {},
              settings: tempPrefs(),
              onNewConversation: () => pressed++,
            ),
          ),
        ));
        await tester.tap(find.text('New conversation'));
        expect(pressed, 1);
      });

      Future<Person?> run(
        WidgetTester tester,
        Future<List<Person>> Function(String) search,
        Future<void> Function() act,
      ) async {
        Person? chosen;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  chosen = await showDialog<Person>(
                    context: context,
                    builder: (_) => NewConversationDialog(search: search),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        await act();
        return chosen;
      }

      testWidgets('searches after a pause and returns who was picked',
          (tester) async {
        final queries = <String>[];
        final chosen = await run(tester, (q) async {
          queries.add(q);
          return [Person('sam', 'Sam Rivers', 'Sales')];
        }, () async {
          await tester.enterText(find.byType(TextField), 'sa');
          await tester.pump(const Duration(milliseconds: 100));
          await tester.enterText(find.byType(TextField), 'sam');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(queries, ['sam'], reason: 'one search, for the final text');
          await tester.tap(find.text('Sam Rivers'));
          await tester.pumpAndSettle();
        });
        expect(chosen?.id, 'sam');
      });

      testWidgets('says when nobody matches or the search fails',
          (tester) async {
        var fail = false;
        await run(tester, (q) async {
          if (fail) throw ApiException(500, 'p');
          return const [];
        }, () async {
          await tester.enterText(find.byType(TextField), 'zzz');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(find.text('No one found.'), findsOneWidget);
          fail = true;
          await tester.enterText(find.byType(TextField), 'zzzz');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(find.textContaining('Couldn\'t search'), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        });
      });

      testWidgets('an older, slower search cannot replace a newer one',
          (tester) async {
        final slow = Completer<List<Person>>();
        await run(tester, (q) {
          if (q == 'a') return slow.future;
          return Future.value([Person('b', 'Newer', '')]);
        }, () async {
          await tester.enterText(find.byType(TextField), 'a');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.enterText(find.byType(TextField), 'b');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          slow.complete([Person('a', 'Older', '')]);
          await tester.pumpAndSettle();
          expect(find.text('Newer'), findsOneWidget);
          expect(find.text('Older'), findsNothing);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        });
      });
    });

    group('colors', () {
      double whiteContrast(Color c) => 1.05 / (c.computeLuminance() + 0.05);

      test('white letters are readable on every accent', () {
        for (final a in accents) {
          // Large bold text needs 3:1; only the icon's blue is under 4.5:1.
          expect(whiteContrast(a.color), greaterThan(a == accents.first ? 4 : 4.5),
              reason: a.name);
        }
      });

      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        return (la > lb ? la + .05 : lb + .05) / (la > lb ? lb + .05 : la + .05);
      }

      test('backgrounds are soft, and everything on them stays readable', () {
        for (final a in accents) {
          for (final b in Brightness.values) {
            final s = talaTheme(a, b).colorScheme;
            final name = '${a.name} ${b.name}';
            final l = HSLColor.fromColor(s.surface).lightness;
            if (b == Brightness.dark) {
              expect(l, greaterThan(.12), reason: 'too black: $name');
            } else {
              expect(l, lessThan(.91), reason: 'too glaring: $name');
            }
            for (final bg in [
              s.surface,
              s.surfaceContainerHigh,
              s.surfaceContainerHighest,
            ]) {
              expect(contrast(s.onSurface, bg), greaterThan(7), reason: name);
              expect(contrast(s.onSurfaceVariant, bg), greaterThan(4.5),
                  reason: name);
            }
            expect(contrast(s.primary, s.surface), greaterThan(4.5),
                reason: name);
            expect(contrast(s.onSurface, s.secondaryContainer), greaterThan(4.5),
                reason: name);
            expect(contrast(s.onSurface, s.primaryContainer), greaterThan(4.5),
                reason: 'own message bubble: $name');
            // A selected row has to be visible against the list.
            expect(contrast(s.secondaryContainer, s.surface), greaterThan(1.15),
                reason: 'selected row: $name');
          }
        }
      });

      test('nothing visible drifts to purple, in either brightness', () {
        bool purple(Color c) {
          final hsl = HSLColor.fromColor(c);
          return hsl.saturation > 0.12 && hsl.hue > 255 && hsl.hue < 320;
        }

        for (final a in accents) {
          for (final b in Brightness.values) {
            final s = talaTheme(a, b).colorScheme;
            for (final c in [
              s.primary,
              s.primaryContainer,
              s.secondary,
              s.secondaryContainer,
              s.surfaceContainerHigh,
            ]) {
              expect(purple(c), isFalse, reason: '${a.name} ${b.name} $c');
            }
          }
        }
      });

      test('an unknown saved accent falls back to the icon blue', () {
        expect(accentNamed('purple').color, talaBlue);
        expect(accentNamed(null).color, talaBlue);
      });

      testWidgets('conversation circles use the exact accent', (tester) async {
        Widget app(Accent accent) => MaterialApp(
          theme: talaTheme(accent, Brightness.light),
          home: Scaffold(
            body: RoomList(
              rooms: [Room('a', 'Family', false, 2)],
              error: null,
              selected: null,
              onSelect: (_) {},
              onRefresh: () {},
              onRemove: (_) {},
              onArchive: (_) {},
              settings: tempPrefs(),
            ),
          ),
        );
        Color? circle() => tester
            .widget<CircleAvatar>(find.byType(CircleAvatar))
            .backgroundColor;

        await tester.pumpWidget(app(accents.first));
        expect(circle(), const Color(0xFF0082C9));
        await tester.pumpWidget(app(accentNamed('rose')));
        await tester.pumpAndSettle();
        expect(circle(), accentNamed('rose').color);
      });
    });

    group('federation', () {
      test('a room knows where it lives', () {
        final room = Room.fromJson({
          'token': 't',
          'type': 2,
          'remoteServer': 'https://far.example',
        });
        expect(room.isFederated, isTrue);
        expect(Room.fromJson({'token': 't', 'type': 2}).isFederated, isFalse);
      });

      test('a call in a federated room joins with the remote details', () {
        final join = SignalingSettings({
          'federation': {
            'server': 'wss://sig.far.example/',
            'nextcloudServer': 'https://far.example/',
            'roomId': 'remote-token',
            'helloAuthParams': {'token': 'jwt'},
          },
        }).federationJoin;
        expect(join, {
          'signaling': 'wss://sig.far.example/',
          'url': 'https://far.example/ocs/v2.php/apps/spreed/api/v3/signaling/backend',
          'roomid': 'remote-token',
          'token': 'jwt',
        });
        expect(SignalingSettings({'federation': null}).federationJoin, isNull);
        expect(SignalingSettings({}).federationJoin, isNull);
      });

      testWidgets('invitations offer accept and decline', (tester) async {
        final invite = FederationInvite.fromJson({
          'id': 4,
          'roomName': 'Far room',
          'inviterDisplayName': 'Sam',
          'remoteServerUrl': 'https://far.example',
        });
        FederationInvite? accepted, declined;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: InviteBanners(
              invites: [invite],
              onAccept: (i) => accepted = i,
              onDecline: (i) => declined = i,
            ),
          ),
        ));
        expect(find.text('Far room'), findsOneWidget);
        expect(find.textContaining('far.example'), findsOneWidget);
        await tester.tap(find.text('Decline'));
        expect(declined?.id, 4);
        await tester.tap(find.text('Accept'));
        expect(accepted?.id, 4);
      });
    });

    group('archived conversations', () {
      Room? archivedRoom;
      setUp(() => archivedRoom = null);

      Widget list(AppSettings prefs, {String? selected}) => MaterialApp(
        home: Scaffold(
          body: RoomList(
            rooms: [
              Room('a', 'Family', false, 2, canArchive: true),
              Room('b', 'Old project', false, 2,
                  archived: true, canArchive: true, unread: 3),
              Room('c', 'Talk updates', false, 4, archived: true),
            ],
            error: null,
            selected: selected,
            onSelect: (_) {},
            onRefresh: () {},
            onRemove: (_) {},
            onArchive: (r) => archivedRoom = r,
            settings: prefs,
            menu: AppMenu(
              settings: prefs,
              creds: Credentials('https://cloud.example/nc', 'me', 'pw'),
              onChangeAccount: (_) {},
            ),
          ),
        ),
      );

      testWidgets('sit collapsed under their own section, with unread shown',
          (tester) async {
        await tester.pumpWidget(list(tempPrefs()));
        expect(find.text('Family'), findsOneWidget);
        expect(find.text('Archived (2)'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        expect(find.text('Old project'), findsNothing);
      });

      testWidgets('open when the section is tapped', (tester) async {
        await tester.pumpWidget(list(tempPrefs()));
        await tester.tap(find.text('Archived (2)'));
        await tester.pump();
        expect(find.text('Old project'), findsOneWidget);
        expect(find.text('Talk updates'), findsOneWidget);
        await tester.tap(find.text('Archived (2)'));
        await tester.pump();
        expect(find.text('Old project'), findsNothing);
      });

      testWidgets('the section can be hidden and brought back from the menu',
          (tester) async {
        final prefs = tempPrefs()..archivedOpen = true;
        await tester.pumpWidget(list(prefs));
        await tester.tap(find.byTooltip('Menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show archived'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(prefs.hideArchived, isTrue);
        expect(find.text('Archived (2)'), findsNothing);
        expect(find.text('Old project'), findsNothing);
        expect(find.text('Family'), findsOneWidget);

        await tester.tap(find.byTooltip('Menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show archived'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(prefs.hideArchived, isFalse);
        expect(find.text('Archived (2)'), findsOneWidget);
      });

      testWidgets('no section appears when nothing is archived',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: RoomList(
              rooms: [Room('a', 'Family', false, 2)],
              error: null,
              selected: null,
              onSelect: (_) {},
              onRefresh: () {},
              onRemove: (_) {},
              onArchive: (_) {},
              settings: tempPrefs(),
            ),
          ),
        ));
        expect(find.textContaining('Archived'), findsNothing);
      });

      testWidgets('a conversation can be archived and unarchived from its menu',
          (tester) async {
        final prefs = tempPrefs()..archivedOpen = true;
        await tester.pumpWidget(list(prefs));
        await openMenu(tester, 'Family');
        await tester.tap(find.text('Archive'));
        await tester.pumpAndSettle();
        expect(archivedRoom?.token, 'a');

        await openMenu(tester, 'Old project');
        await tester.tap(find.text('Unarchive'));
        await tester.pumpAndSettle();
        expect(archivedRoom?.token, 'b');
      });

      test('a server without the flag gets no archive option', () {
        final old = Room.fromJson({'token': 't', 'type': 2});
        expect(old.canArchive, isFalse);
        expect(
          Room.fromJson({'token': 't', 'type': 2, 'isArchived': false})
              .canArchive,
          isTrue,
        );
      });

      test('the server flag is read, and missing means not archived', () {
        Map<String, dynamic> json(Map<String, dynamic> extra) => {
          'token': 't',
          'type': 2,
          ...extra,
        };
        expect(Room.fromJson(json({'isArchived': true})).archived, isTrue);
        expect(Room.fromJson(json({'isArchived': false})).archived, isFalse);
        expect(Room.fromJson(json({})).archived, isFalse);
      });

      test('the dock count skips archived and muted conversations', () {
        expect(
          dockUnread([
            Room('a', 'A', false, 2, unread: 2),
            Room('b', 'B', false, 2, unread: 5, archived: true),
            Room('c', 'C', false, 2, unread: 9, muted: true),
            Room('d', 'D', false, 1, unread: 1),
          ]),
          3,
        );
      });

      test('the choices survive a restart, and a bad file is ignored', () {
        final file = File(
          '${Directory.systemTemp.createTempSync('tala').path}/s.json',
        );
        AppSettings(file: file)
          ..hideArchived = true
          ..archivedOpen = true
          ..themeMode = ThemeMode.dark
          ..accent = accentNamed('green')
          ..messageSound = false
          ..callChatOpen = false;
        final again = AppSettings(file: file);
        expect(again.callChatOpen, isFalse);
        expect(again.hideArchived, isTrue);
        expect(again.archivedOpen, isTrue);
        expect(again.themeMode, ThemeMode.dark);
        expect(again.accent.name, 'green');
        expect(again.messageSound, isFalse);
        file.writeAsStringSync('not json');
        expect(AppSettings(file: file).hideArchived, isFalse);
      });
    });
  });
}
