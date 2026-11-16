import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/internal_signaling.dart';
import 'package:tala/src/nc_api.dart';
import 'package:tala/src/typing.dart';

class FakeLink implements TypingLink {
  FakeLink(this.sessionId);
  @override
  final String? sessionId;
  final sent = <(String, String)>[];
  bool closed = false;
  @override
  void send(String to, Map<String, dynamic> data) {
    expectSync(data['to'], to);
    sent.add((to, data['type'] as String));
  }

  @override
  Future<void> close() async => closed = true;
}

Room room() => Room.fromJson({
      'token': 'tok',
      'type': 2,
      'displayName': 'Weekend hike',
      'actorId': 'sam',
    });

void main() {
  test('the line names up to three, then counts', () {
    expect(typingLine([]), isNull);
    expect(typingLine(['Maya']), 'Maya is typing…');
    expect(typingLine(['Maya', 'Daniel']), 'Maya and Daniel are typing…');
    expect(typingLine(['Maya', 'Daniel', 'Priya']),
        'Maya, Daniel and Priya are typing…');
    expect(typingLine(['Maya', 'Daniel', 'Priya', 'Jordan', 'Marco']),
        'Maya, Daniel and 3 others are typing…');
  });

  group('session', () {
    late FakeLink link;
    late int connects;
    TypingSession make() {
      connects = 0;
      return TypingSession(null, room(), connect: (_) async {
        connects++;
        return link = FakeLink('me');
      });
    }

    testWidgets('joins only after a moment of focus, leaves at once',
        (tester) async {
      final s = make();
      s.active = true;
      await tester.pump(const Duration(milliseconds: 500));
      s.active = false;
      await tester.pump(const Duration(seconds: 2));
      expect(connects, 0);
      s.active = true;
      await tester.pump(TypingSession.joinDelay);
      expect(connects, 1);
      expect(s.connected, isTrue);
      s.active = false;
      await tester.pump();
      expect(link.closed, isTrue);
      expect(s.connected, isFalse);
      s.dispose();
    });

    testWidgets('internal: others typing show, self and own devices do not',
        (tester) async {
      final s = make();
      s.active = true;
      await tester.pump(TypingSession.joinDelay);
      s.handleUsersInRoom(const [
        SignalingUser('me', 0, userId: 'sam'),
        SignalingUser('phone', 0, userId: 'sam'),
        SignalingUser('maya', 0, userId: 'maya'),
        SignalingUser('guest', 0),
      ], ownSession: 'me');
      var heard = 0;
      s.addListener(() => heard++);
      s.handleMessage({'type': 'startedTyping', 'from': 'phone', 'to': 'me'});
      expect(s.names, isEmpty);
      s.handleMessage({'type': 'startedTyping', 'from': 'maya', 'to': 'me'});
      s.handleMessage({'type': 'startedTyping', 'from': 'guest', 'to': 'me'});
      // No HPB name and no server to ask.
      expect(s.names, ['Someone', 'Someone']);
      s.handleMessage({'type': 'stoppedTyping', 'from': 'guest', 'to': 'me'});
      expect(s.names, hasLength(1));
      // Leaving the room stops their typing.
      s.handleUsersInRoom(const [SignalingUser('me', 0, userId: 'sam')],
          ownSession: 'me');
      expect(s.names, isEmpty);
      expect(heard, 4);
      s.dispose();
    });

    testWidgets('HPB: names come with the join, leave clears',
        (tester) async {
      final s = make();
      s.active = true;
      await tester.pump(TypingSession.joinDelay);
      s.handleEvent({
        'target': 'room',
        'type': 'join',
        'join': [
          {'sessionid': 'me', 'roomsessionid': 'r0', 'userid': 'sam'},
          {
            'sessionid': 's1',
            'roomsessionid': 'r1',
            'userid': 'maya',
            'user': {'displayname': 'Maya Chen'},
          },
        ],
      });
      s.handleMessage({
        'sender': {'type': 'session', 'sessionid': 's1'},
        'data': {'type': 'startedTyping', 'to': 'me'},
      });
      expect(s.names, ['Maya Chen']);
      // Someone not in the room is ignored.
      s.handleMessage({
        'sender': {'type': 'session', 'sessionid': 'stranger'},
        'data': {'type': 'startedTyping'},
      });
      expect(s.names, ['Maya Chen']);
      s.handleEvent({'target': 'room', 'type': 'leave', 'leave': ['s1']});
      expect(s.names, isEmpty);
      s.dispose();
    });

    testWidgets('the user typing tells everyone, once, and stops when idle',
        (tester) async {
      final s = make();
      s.active = true;
      await tester.pump(TypingSession.joinDelay);
      s.handleUsersInRoom(const [
        SignalingUser('me', 0, userId: 'sam'),
        SignalingUser('maya', 0, userId: 'maya'),
      ], ownSession: 'me');
      s.typing(true);
      s.typing(true);
      expect(link.sent, [('maya', 'startedTyping')]);
      // Someone arriving mid-message hears about it.
      s.handleUsersInRoom(const [
        SignalingUser('me', 0, userId: 'sam'),
        SignalingUser('maya', 0, userId: 'maya'),
        SignalingUser('daniel', 0, userId: 'daniel'),
      ], ownSession: 'me');
      expect(link.sent.last, ('daniel', 'startedTyping'));
      link.sent.clear();
      await tester.pump(TypingSession.idleStop);
      expect(link.sent, unorderedEquals([
        ('maya', 'stoppedTyping'),
        ('daniel', 'stoppedTyping'),
      ]));
      s.dispose();
    });

    testWidgets('nothing is sent or shown before connecting', (tester) async {
      final s = make();
      s.typing(true);
      s.handleMessage({'type': 'startedTyping', 'from': 'maya'});
      expect(s.names, isEmpty);
      s.dispose();
      await tester.pump(TypingSession.idleStop);
    });
  });
}
