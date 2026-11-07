import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/call.dart';
import 'package:tala/src/internal_signaling.dart';

void main() {
  group('who starts a direct connection', () {
    MeshRole role(
      String mine,
      String theirs, {
      bool self = true,
      bool them = true,
    }) => meshRole(
      mine: mine,
      theirs: theirs,
      selfHasStreams: self,
      theyHaveStreams: them,
    );

    test('the larger session id offers, and the other waits', () {
      expect(role('b', 'a'), MeshRole.offer);
      expect(role('a', 'b'), MeshRole.wait);
    });

    test('exactly one side offers, whatever the ids', () {
      for (final (x, y) in [
        ('a', 'b'),
        ('Z', 'a'),
        ('abc', 'abd'),
        ('a+b', 'a/b'),
      ]) {
        expect({role(x, y), role(y, x)}, {MeshRole.offer, MeshRole.wait});
      }
    });

    test('someone sending nothing can only be offered to', () {
      expect(role('a', 'b', them: false), MeshRole.offer);
      expect(role('a', 'b', self: false), MeshRole.none);
      expect(role('b', 'a', self: false), MeshRole.none);
      expect(role('a', 'b', self: false, them: false), MeshRole.none);
    });
  });

  group('messages held while the camera opens', () {
    Map<String, dynamic> m(String type, String from, String sid) => {
      'type': type,
      'from': from,
      'sid': sid,
    };

    test('only the newest offer from each person survives, in order', () {
      final fresh = freshMeshMessages([
        m('offer', 'a', '1'),
        m('candidate', 'a', '1'),
        m('offer', 'b', '7'),
        m('offer', 'a', '2'),
        m('candidate', 'b', '7'),
        m('candidate', 'a', '2'),
      ]);
      expect(fresh.map((x) => '${x['type']} ${x['from']} ${x['sid']}'), [
        'offer b 7',
        'offer a 2',
        'candidate b 7',
        'candidate a 2',
      ]);
    });

    test('a shared screen is kept apart from the same person\'s camera', () {
      Map<String, dynamic> screen(String type, String sid) => {
        ...m(type, 'a', sid),
        'roomType': 'screen',
      };
      final fresh = freshMeshMessages([
        m('offer', 'a', '1'),
        screen('offer', 's1'),
        screen('offer', 's2'),
        m('candidate', 'a', '1'),
        screen('candidate', 's1'),
        screen('candidate', 's2'),
      ]);
      expect(
        fresh.map(
          (x) => '${x['type']} ${x['roomType'] ?? 'video'} ${x['sid']}',
        ),
        [
          'offer video 1',
          'offer screen s2',
          'candidate video 1',
          'candidate screen s2',
        ],
      );
    });

    test('messages from someone with no offer pass through', () {
      final held = [
        {'type': 'mute', 'from': 'a'},
        m('candidate', 'c', '9'),
      ];
      expect(freshMeshMessages(held), held);
    });

    test('nothing held gives nothing', () {
      expect(freshMeshMessages(const []), isEmpty);
    });
  });

  group('reading a long poll', () {
    final messages = <Map<String, dynamic>>[];
    final users = <List<SignalingUser>>[];
    setUp(() {
      messages.clear();
      users.clear();
    });
    void read(Object? data) =>
        readPull(data, onMessage: messages.add, onUsers: users.add);

    test('decodes messages that arrive as JSON text, in order', () {
      read([
        {
          'type': 'message',
          'data': jsonEncode({'type': 'offer', 'from': 'a'}),
        },
        {
          'type': 'usersInRoom',
          'data': [
            {'sessionId': 'a', 'inCall': 7},
            {'sessionId': 'b', 'inCall': 0},
          ],
        },
      ]);
      expect(messages.single['from'], 'a');
      expect(users.single.map((u) => (u.sessionId, u.inCall)), [
        ('a', 7),
        ('b', 0),
      ]);
    });

    test('ignores what it does not recognize', () {
      read(null);
      read('nope');
      read([
        'x',
        {'type': 'other', 'data': 1},
        {'type': 'message', 'data': '[1]'},
        {'type': 'usersInRoom', 'data': 'x'},
        {
          'type': 'usersInRoom',
          'data': [
            {'inCall': 1},
            {'sessionId': 'a', 'inCall': true},
          ],
        },
      ]);
      expect(messages, isEmpty);
      expect(users.single.single.inCall, 1);
    });
  });

  test('retries start quick and settle at 10 seconds', () {
    expect(
      [for (var i = 1; i <= 6; i++) pullRetryDelay(i).inSeconds],
      [1, 2, 4, 8, 10, 10],
    );
  });

  test('only some failures end the call', () {
    expect(pullFailureEnds(409), contains('somewhere else'));
    expect(pullFailureEnds(404), contains('no longer available'));
    expect(pullFailureEnds(403), contains('no longer available'));
    expect(pullFailureEnds(400), contains('stopped using'));
    expect(pullFailureEnds(500), isNull);
    expect(pullFailureEnds(null), isNull);
  });
}
