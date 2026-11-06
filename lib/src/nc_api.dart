import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'incoming_calls.dart';
import 'log.dart';

class Credentials {
  Credentials(this.server, this.user, this.appPassword);
  final String server;
  final String user;
  final String appPassword;

  static File get _file => File(
      '${Platform.environment['HOME']}/.config/tala-prototype/credentials.json');

  static Credentials? load() {
    if (!_file.existsSync()) return null;
    final d = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
    return Credentials(d['server'], d['user'], d['appPassword']);
  }

  /// Prototype only: a mode 600 file. The real app must use the keyring.
  Future<void> save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString('{}');
    await Process.run('chmod', ['600', _file.path]);
    await _file.writeAsString(jsonEncode(
        {'server': server, 'user': user, 'appPassword': appPassword}));
  }
}

class Room {
  Room(this.token, this.name, this.hasCall, this.type);
  final String token;
  final String name;
  final bool hasCall;
  final int type; // 1 one-to-one, 2 group, 3 public
}

class SignalingSettings {
  SignalingSettings(this.raw);
  final Map<String, dynamic> raw;
  String get server => (raw['server'] ?? '') as String;
  String get ticket => (raw['ticket'] ?? '') as String;
  String? get userId => raw['userId'] as String?;
  Map<String, dynamic>? get helloV2 =>
      (raw['helloAuthParams'] as Map?)?['2.0']?.cast<String, dynamic>();

  /// One entry per URL, because the plugin copies them into a fixed array of
  /// 8 on desktop and only reads a plain string `url` reliably.
  List<Map<String, dynamic>> get iceServers {
    final out = <Map<String, dynamic>>[];
    for (final s in (raw['stunservers'] as List? ?? const [])) {
      for (final u in (s['urls'] as List? ?? const [])) {
        out.add({'url': u});
      }
    }
    for (final s in (raw['turnservers'] as List? ?? const [])) {
      for (final u in (s['urls'] as List? ?? const [])) {
        out.add({
          'url': u,
          'username': s['username'],
          'credential': s['credential'],
        });
      }
    }
    if (out.length > 8) {
      log('ice: capping ${out.length} servers to 8');
      return out.sublist(0, 8);
    }
    return out;
  }
}

class ApiException implements Exception {
  ApiException(this.status, this.path);
  final int status;
  final String path;
  @override
  String toString() => 'HTTP $status on $path';
}

class NcApi implements CallSource {
  NcApi(this.creds);
  final Credentials creds;
  final HttpClient _http = HttpClient()..userAgent = 'Tala desktop prototype';
  final Map<String, Cookie> _cookies = {};

  static const _talkV4 = '/ocs/v2.php/apps/spreed/api/v4';
  static const _talkV3 = '/ocs/v2.php/apps/spreed/api/v3';

  Future<dynamic> _ocs(String method, String path,
      {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${creds.server}$path');
    final req = await _http.openUrl(method, uri);
    req.headers
      ..set('OCS-APIRequest', 'true')
      ..set('Accept', 'application/json')
      ..set('Authorization',
          'Basic ${base64.encode(utf8.encode('${creds.user}:${creds.appPassword}'))}');
    req.cookies.addAll(_cookies.values);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    for (final c in res.cookies) {
      _cookies[c.name] = c;
    }
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 300) throw ApiException(res.statusCode, path);
    if (text.isEmpty) return null;
    return (jsonDecode(text) as Map)['ocs']?['data'];
  }

  String? _notificationsEtag;

  @override
  Future<List<CallNote>?> callNotifications() async {
    const path = '/ocs/v2.php/apps/notifications/api/v2/notifications';
    final req = await _http.getUrl(Uri.parse('${creds.server}$path'));
    _authHeaders(req);
    if (_notificationsEtag != null) {
      req.headers.set('If-None-Match', _notificationsEtag!);
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode == 304) return null;
    if (res.statusCode >= 300) throw ApiException(res.statusCode, path);
    _notificationsEtag = res.headers.value('etag');
    final data = (jsonDecode(text) as Map)['ocs']['data'] as List;
    return [
      for (final n in data)
        if (n['app'] == 'spreed' &&
            n['object_type'] == 'call' &&
            n['shouldNotify'] != false)
          CallNote(
            n['notification_id'] as int,
            n['object_id'] as String,
            (n['subjectRichParameters']?['call']?['name'] ?? 'Someone')
                as String,
            n['subjectRichParameters']?['call']?['call-type'] == 'one2one',
          ),
    ];
  }

  /// 200 means ringing and not yet joined, 201 missed, 404 already joined.
  @override
  Future<CallState> callState(String token) async {
    final path = '$_talkV4/call/$token/notification-state';
    final req = await _http.getUrl(Uri.parse('${creds.server}$path'));
    _authHeaders(req);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) return CallState.joined;
    if (res.statusCode >= 300 && res.statusCode != 304) {
      throw ApiException(res.statusCode, path);
    }
    final code = (jsonDecode(text) as Map)['ocs']?['meta']?['statuscode'];
    return (code == 201 || res.statusCode == 201)
        ? CallState.missed
        : CallState.pending;
  }

  @override
  Future<void> dismissNotification(int id) async {
    await _ocs('DELETE', '/ocs/v2.php/apps/notifications/api/v2/notifications/$id');
  }

  void _authHeaders(HttpClientRequest req) {
    req.headers
      ..set('OCS-APIRequest', 'true')
      ..set('Accept', 'application/json')
      ..set('Authorization',
          'Basic ${base64.encode(utf8.encode('${creds.user}:${creds.appPassword}'))}');
  }

  Future<List<Room>> rooms() async {
    final data = await _ocs('GET', '$_talkV4/room') as List;
    return [
      for (final r in data)
        // Read-only conversations such as Talk updates can't hold calls.
        if (r['readOnly'] != 1)
          Room(r['token'], r['displayName'] ?? r['name'] ?? '?',
              (r['hasCall'] ?? false) as bool, r['type'] as int)
    ];
  }

  Future<SignalingSettings> signalingSettings(String token) async =>
      SignalingSettings((await _ocs(
              'GET', '$_talkV3/signaling/settings?token=$token') as Map)
          .cast<String, dynamic>());

  String get signalingBackendUrl => '${creds.server}$_talkV3/signaling/backend';

  /// Returns the Nextcloud session id.
  Future<String> joinRoom(String token) async {
    final d = await _ocs('POST', '$_talkV4/room/$token/participants/active',
        body: {'force': true});
    return d['sessionId'] as String;
  }

  Future<void> leaveRoom(String token) =>
      _ocs('DELETE', '$_talkV4/room/$token/participants/active');

  Future<void> joinCall(String token, int flags) =>
      _ocs('POST', '$_talkV4/call/$token', body: {'flags': flags});

  Future<void> leaveCall(String token) =>
      _ocs('DELETE', '$_talkV4/call/$token');
}

/// Nextcloud Login Flow v2: the user approves in their browser and the server
/// issues an app password for this device. Passwords never pass through Tala.
Future<Credentials> loginFlow(String server) async {
  final base = server.replaceAll(RegExp(r'/+$'), '');
  final http = HttpClient()..userAgent = 'Tala desktop prototype';
  try {
    final init = await http.postUrl(Uri.parse('$base/index.php/login/v2'));
    final res = await init.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'login/v2');
    final d = jsonDecode(body) as Map<String, dynamic>;
    final loginUrl = d['login'] as String;
    final endpoint = d['poll']['endpoint'] as String;
    final token = d['poll']['token'] as String;
    await Process.run('xdg-open', [loginUrl]);
    log('login: waiting for browser approval');

    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final p = await http.postUrl(Uri.parse(endpoint));
      p.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      p.write('token=${Uri.encodeQueryComponent(token)}');
      final r = await p.close();
      final t = await r.transform(utf8.decoder).join();
      if (r.statusCode == 200) {
        final c = jsonDecode(t) as Map<String, dynamic>;
        final creds = Credentials(c['server'], c['loginName'], c['appPassword']);
        await creds.save();
        log('login: approved');
        return creds;
      }
    }
    throw TimeoutException('Login was not approved in time');
  } finally {
    http.close();
  }
}
