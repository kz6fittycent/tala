import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
