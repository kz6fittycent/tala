import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart' show ApiException;
import 'package:tala/src/nc_api.dart';

/// A loopback server, so these exercise the real HTTP requests.
class Server {
  late HttpServer http;
  final List<String> requests = [];
  final Map<String, List<int>> stored = {};
  final List<Map<String, dynamic>> shares = [];
  final Set<String> folders = {};
  final List<String?> ifNoneMatch = [];
  final List<String> bodies = [];
  bool rejectAll = false;

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen(_handle);
  }

  String get url => 'http://127.0.0.1:${http.port}';

  void _ocs(HttpResponse r, Object? data) =>
      r.write(jsonEncode({'ocs': {'data': data}}));

  Future<void> _handle(HttpRequest q) async {
    final r = q.response;
    final path = Uri.decodeFull(q.uri.path);
    requests.add('${q.method} ${q.uri}');
    final body = await q.fold<List<int>>([], (a, b) => a..addAll(b));
    if (rejectAll) {
      r.statusCode = 401;
      await r.close();
      return;
    }
    if (path.endsWith('/cloud/capabilities')) {
      _ocs(r, {
        'capabilities': {
          'spreed': {
            'config': {
              'attachments': {'allowed': true, 'folder': '/Talk'},
            },
          },
        },
      });
    } else if (path.endsWith('/cloud/user')) {
      _ocs(r, {'id': 'user id'});
    } else if (path.contains('/shares')) {
      shares.add(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
      _ocs(r, {});
    } else if (path.contains('/chat/')) {
      _ocs(r, {
        'id': 9,
        'systemMessage': 'message_edited',
        'message': '',
        'parent': {'id': 5, 'message': 'new text'},
      });
      bodies.add(utf8.decode(body));
    } else if (path.endsWith('/room/abc/participants') && q.method == 'GET') {
      _ocs(r, [
        {
          'attendeeId': 7,
          'actorType': 'users',
          'actorId': 'sam',
          'displayName': 'Sam',
          'participantType': 2,
        },
        {'attendeeId': 8, 'actorType': 'guests', 'actorId': 'x', 'participantType': 4},
      ]);
    } else if ((path.endsWith('/room/abc') && q.method == 'PUT') ||
        path.endsWith('/room/abc/attendees') ||
        path.endsWith('/room/abc/moderators')) {
      bodies.add(utf8.decode(body));
      _ocs(r, {});
    } else if (q.method == 'MKCOL') {
      folders.add(path);
      r.statusCode = 201;
    } else if (q.method == 'PUT') {
      ifNoneMatch.add(q.headers.value('if-none-match'));
      final parent = path.substring(0, path.lastIndexOf('/'));
      if (!folders.contains(parent)) {
        r.statusCode = 409;
      } else if (stored.containsKey(path)) {
        r.statusCode = 412;
      } else {
        stored[path] = body;
        r.statusCode = 201;
      }
    } else if (path.endsWith('/autocomplete/get')) {
      _ocs(r, [
        {'id': 'sam', 'label': 'Sam', 'source': 'users', 'subline': 'Sales'},
        {'id': 'user id', 'label': 'Me', 'source': 'users'},
        {'id': 'staff', 'label': 'Staff', 'source': 'groups'},
      ]);
    } else if (path.endsWith('/room/abc/participants') ||
        path.endsWith('/room/abc/public') ||
        path.endsWith('/room/abc')) {
      bodies.add(utf8.decode(body));
      _ocs(r, {});
    } else if (path.endsWith('/spreed/api/v4/room') && q.method == 'POST') {
      bodies.add(utf8.decode(body));
      _ocs(r, {'token': 'new-room'});
    } else if (path.endsWith('/federation/invitation')) {
      _ocs(r, [
        {'id': 1, 'state': 0, 'roomName': 'Pending'},
        {'id': 2, 'state': 1, 'roomName': 'Already accepted'},
      ]);
    } else if (path.contains('/federation/invitation/') ||
        path.endsWith('/archive') ||
        path.endsWith('/core/apppassword')) {
      _ocs(r, {});
    } else if (path.contains('/participants/self')) {
      _ocs(r, {});
    } else if (path.contains('/reaction/')) {
      _ocs(r, {});
    } else if (path.startsWith('/index.php/avatar/custom')) {
      r.headers.set('X-NC-IsCustomAvatar', '1');
      r.headers.contentType = ContentType('image', 'png');
      r.add([1, 2, 3]);
    } else if (path.startsWith('/index.php/avatar/generated')) {
      r.headers.set('X-NC-IsCustomAvatar', '0');
      r.headers.contentType = ContentType('image', 'png');
      r.add([4, 5]);
    } else if (path.endsWith('/room/pic/avatar')) {
      r.headers.contentType = ContentType('image', 'jpeg');
      r.add([6]);
    } else if (path.endsWith('/room/svg/avatar')) {
      r.headers.contentType = ContentType('image', 'svg+xml');
      r.write('<svg/>');
    } else if (path.endsWith('/room/broken/avatar')) {
      r.statusCode = 500;
    } else if (path.contains('/core/preview')) {
      r.add([1, 2, 3]);
    } else {
      r.statusCode = 404;
    }
    await r.close();
  }
}

void main() {
  late Server s;
  late NcApi api;
  late Directory dir;
  late String local;
  const talk = '/remote.php/dav/files/user id/Talk';

  setUp(() async {
    s = Server();
    await s.start();
    api = NcApi(Credentials(s.url, 'login', 'pw'));
    dir = await Directory.systemTemp.createTemp('tala-test');
    local = '${dir.path}/photo one.png';
    await File(local).writeAsBytes([9, 8, 7]);
  });

  tearDown(() async {
    await s.http.close(force: true);
    await dir.delete(recursive: true);
  });

  test('creates the folder once and stores under the user id', () async {
    final remote = await api.chatUpload(local);
    expect(remote, '/Talk/photo one.png');
    expect(s.stored['$talk/photo one.png'], [9, 8, 7]);
    expect(s.requests.where((r) => r.startsWith('MKCOL')).length, 1);
  });

  test('never overwrites: an existing name gets a new one', () async {
    s.folders.add(talk);
    s.stored['$talk/photo one.png'] = [1];
    s.stored['$talk/photo one (1).png'] = [2];
    final remote = await api.chatUpload(local);
    expect(remote, '/Talk/photo one (2).png');
    expect(s.stored['$talk/photo one.png'], [1]);
    expect(s.stored['$talk/photo one (1).png'], [2]);
    expect(s.ifNoneMatch.every((h) => h == '*'), isTrue);
  });

  test('sharing posts to the conversation with the reference', () async {
    await api.chatShareFile('tok', '/Talk/a.png', 'ref');
    expect(s.shares.single, {
      'shareType': 10,
      'shareWith': 'tok',
      'path': '/Talk/a.png',
      'referenceId': 'ref',
    });
  });

  test('uploads are allowed by the capability', () async {
    expect(await api.chatUploadsAllowed(), isTrue);
  });

  test('removing a reaction sends the emoji encoded', () async {
    await api.chatReact('tok', 5, '👍', remove: true);
    expect(
        s.requests.single,
        'DELETE /ocs/v2.php/apps/spreed/api/v1/reaction/tok/5'
        '?reaction=${Uri.encodeQueryComponent('👍')}');
  });

  test('editing sends the text and returns the changed message', () async {
    final m = await api.chatEdit('tok', 5, 'new text');
    expect(s.requests.single, 'PUT /ocs/v2.php/apps/spreed/api/v1/chat/tok/5');
    expect(jsonDecode(s.bodies.single), {'message': 'new text'});
    expect(m!.id, 5);
    expect(m.text, 'new text');
  });

  test('deleting targets the one message', () async {
    final m = await api.chatDelete('tok', 5);
    expect(
        s.requests.single, 'DELETE /ocs/v2.php/apps/spreed/api/v1/chat/tok/5');
    expect(m!.id, 5);
  });

  test('removing a chat leaves it, and never deletes the room', () async {
    await api.leaveConversation('tok');
    expect(s.requests.single,
        'DELETE /ocs/v2.php/apps/spreed/api/v4/room/tok/participants/self');
  });

  test('fetches preview bytes', () async {
    expect(await api.chatPreview(7), [1, 2, 3]);
    expect(s.requests.single.contains('fileId=7'), isTrue);
  });

  test('archiving and unarchiving use the same path', () async {
    await api.setArchived('tok', true);
    await api.setArchived('tok', false);
    expect(s.requests, [
      'POST /ocs/v2.php/apps/spreed/api/v4/room/tok/archive',
      'DELETE /ocs/v2.php/apps/spreed/api/v4/room/tok/archive',
    ]);
  });

  test('only pending invitations are offered', () async {
    final invites = await api.federationInvites();
    expect(invites.map((i) => i.roomName), ['Pending']);
  });

  test('answering an invitation names it', () async {
    await api.acceptInvite(1);
    await api.declineInvite(2);
    const path = '/ocs/v2.php/apps/spreed/api/v1/federation/invitation';
    expect(s.requests, ['POST $path/1', 'DELETE $path/2']);
  });

  test('removing the app password uses the core endpoint', () async {
    await api.revokeAppPassword();
    expect(s.requests.single, 'DELETE /ocs/v2.php/core/apppassword');
  });

  test('people search keeps other users, not groups or yourself', () async {
    final people = await api.searchPeople('s a');
    expect(people.map((p) => p.id), ['sam']);
    expect(people.single.detail, 'Sales');
    expect(s.requests.first, contains('search=s+a'));
    expect(s.requests.first, contains('itemType=call'));
  });

  test('starting a conversation asks for a one-to-one', () async {
    expect(await api.startOneToOne('sam'), 'new-room');
    expect(jsonDecode(s.bodies.single), {'roomType': 1, 'invite': 'sam'});
  });

  test('a guest conversation is public, and sends a password only if set',
      () async {
    expect(await api.createGuestConversation('Picnic', ''), 'new-room');
    expect(jsonDecode(s.bodies.last), {'roomType': 3, 'roomName': 'Picnic'});
    await api.createGuestConversation('Picnic', 'hunter22');
    expect(jsonDecode(s.bodies.last),
        {'roomType': 3, 'roomName': 'Picnic', 'password': 'hunter22'});
  });

  test('email invitations and turning a link off use the right calls',
      () async {
    await api.inviteByEmail('abc', 'pat@example.com');
    expect(s.requests.last, 'POST /ocs/v2.php/apps/spreed/api/v4/room/abc/participants');
    expect(jsonDecode(s.bodies.last),
        {'newParticipant': 'pat@example.com', 'source': 'emails'});
    await api.turnOffGuestLink('abc');
    expect(s.requests.last, 'DELETE /ocs/v2.php/apps/spreed/api/v4/room/abc/public');
  });

  test('deleting for everyone removes the whole conversation', () async {
    await api.deleteConversation('abc');
    expect(s.requests.last, 'DELETE /ocs/v2.php/apps/spreed/api/v4/room/abc');
  });

  test('a group is created by name, and members are added as users', () async {
    expect(await api.createGroup('Book club'), 'new-room');
    expect(jsonDecode(s.bodies.last), {'roomType': 2, 'roomName': 'Book club'});
    await api.addMember('abc', 'sam');
    expect(s.requests.last,
        'POST /ocs/v2.php/apps/spreed/api/v4/room/abc/participants');
    expect(jsonDecode(s.bodies.last),
        {'newParticipant': 'sam', 'source': 'users'});
  });

  test('members are read from the server\'s fields', () async {
    final members = await api.members('abc');
    expect(members.map((m) => m.attendeeId), [7, 8]);
    expect(members.first.displayName, 'Sam');
    expect(members.first.isModerator, isTrue);
    expect(members.last.displayName, 'Guest');
    expect(members.last.isGuest, isTrue);
  });

  test('removing, moderators and renaming use the right calls', () async {
    const room = '/ocs/v2.php/apps/spreed/api/v4/room/abc';
    await api.removeMember('abc', 7);
    expect(s.requests.last, 'DELETE $room/attendees?attendeeId=7');
    await api.setModerator('abc', 7, true);
    expect(s.requests.last, 'POST $room/moderators');
    expect(jsonDecode(s.bodies.last), {'attendeeId': 7});
    await api.setModerator('abc', 7, false);
    expect(s.requests.last, 'DELETE $room/moderators?attendeeId=7');
    await api.renameConversation('abc', 'New name');
    expect(s.requests.last, 'PUT $room');
    expect(jsonDecode(s.bodies.last), {'roomName': 'New name'});
  });

  test('only a picture someone chose counts as a user avatar', () async {
    expect(await api.userAvatar('custom'), [1, 2, 3]);
    expect(await api.userAvatar('generated'), isNull);
    expect(await api.userAvatar('nobody'), isNull, reason: 'a 404');
    expect(s.requests.first, 'GET /index.php/avatar/custom/128');
  });

  test('a user id is safe in the avatar address', () async {
    await api.userAvatar('a b/c');
    expect(s.requests.last, 'GET /index.php/avatar/a%20b%2Fc/128');
  });

  test('a conversation avatar must be something Tala can draw', () async {
    expect(await api.roomAvatar('pic'), [6]);
    expect(await api.roomAvatar('svg'), isNull);
    await expectLater(api.roomAvatar('broken'), throwsA(isA<ApiException>()));
  });

  test('only a 401 counts as a rejected sign-in', () async {
    expect(await api.signInRejected(), isFalse);
    s.rejectAll = true;
    expect(await api.signInRejected(), isTrue);
    await s.http.close(force: true);
    expect(await api.signInRejected(), isFalse);
    await s.start();
  });

  test('the server sees the version, not "prototype"', () async {
    final seen = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((q) async {
      seen.add(q.headers.value('user-agent'));
      q.response.write('{"ocs":{"data":{}}}');
      await q.response.close();
    });
    addTearDown(() => server.close(force: true));
    await NcApi(
      Credentials('http://127.0.0.1:${server.port}', 'u', 'p'),
    ).signInRejected();
    expect(seen.single, startsWith('Tala/'));
    expect(seen.single, isNot(contains('prototype')));
  });

  test('call flags are updated with PUT and the new flags', () async {
    late String method, path, body;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((q) async {
      method = q.method;
      path = q.uri.path;
      body = await utf8.decoder.bind(q).join();
      q.response.write('{"ocs":{"data":{}}}');
      await q.response.close();
    });
    addTearDown(() => server.close(force: true));
    await NcApi(
      Credentials('http://127.0.0.1:${server.port}', 'u', 'p'),
    ).updateCallFlags('abc', 3);
    expect(method, 'PUT');
    expect(path, endsWith('/spreed/api/v4/call/abc'));
    expect(body, contains('flags'));
    expect(body, contains('3'));
  });
}
