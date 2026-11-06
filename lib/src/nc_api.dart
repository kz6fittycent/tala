import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'chat.dart';
import 'chat_alerts.dart';
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
  Room(
    this.token,
    this.name,
    this.hasCall,
    this.type, {
    this.unread = 0,
    this.unreadMention = false,
    this.lastRead = 0,
    this.lastActivity = 0,
    this.favorite = false,
    this.canChat = true,
    this.canCall = true,
    this.selfId = '',
    this.lastMessage,
    this.canLeave = true,
    this.isModerator = false,
  });

  factory Room.fromJson(Map<String, dynamic> r) {
    final type = r['type'] as int;
    final readOnly = r['readOnly'] == 1;
    final hasCall = r['hasCall'] == true;
    final last = r['lastMessage'];
    // Chat permission bit, from Talk's attendee permissions.
    const chatPermission = 128;
    final permissions = r['permissions'] as int?;
    return Room(
      r['token'] as String,
      (r['displayName'] ?? r['name'] ?? '?') as String,
      hasCall,
      type,
      unread: r['unreadMessages'] as int? ?? 0,
      unreadMention: r['unreadMention'] == true,
      lastRead: r['lastReadMessage'] as int? ?? 0,
      lastActivity: r['lastActivity'] as int? ?? 0,
      favorite: r['isFavorite'] == true,
      canChat: !readOnly &&
          (permissions == null || permissions & chatPermission != 0),
      // Talk updates (4) and Note to self (6) can't hold calls.
      canCall: !readOnly &&
          type != 4 &&
          type != 6 &&
          (hasCall || r['canStartCall'] != false),
      selfId: r['actorId'] as String? ?? '',
      // The last moderator has to promote someone before leaving.
      canLeave: r['canLeaveConversation'] != false,
      // Both people own a one-to-one, but neither can delete the other's words.
      isModerator:
          type != 1 && const {1, 2, 6}.contains(r['participantType']),
      lastMessage: last is Map && last['id'] is int
          ? ChatMessage.fromJson(last.cast<String, dynamic>())
          : null,
    );
  }

  final String token;
  final String name;
  final bool hasCall;
  final int type; // 1 one-to-one, 2 group, 3 public, 4 updates, 6 note to self
  final int unread;
  final bool unreadMention;
  final int lastRead;
  final int lastActivity;
  final bool favorite;
  final bool canChat;
  final bool canCall;
  final String selfId;
  final ChatMessage? lastMessage;
  final bool canLeave;
  final bool isModerator;
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

class NcApi implements CallSource, ChatSource {
  NcApi(this.creds);
  final Credentials creds;
  final HttpClient _http = HttpClient()..userAgent = 'Tala desktop prototype';
  final Map<String, Cookie> _cookies = {};

  static const _talkV4 = '/ocs/v2.php/apps/spreed/api/v4';
  static const _talkV3 = '/ocs/v2.php/apps/spreed/api/v3';
  static const _chatV1 = '/ocs/v2.php/apps/spreed/api/v1/chat';

  /// Reading never moves the read marker or clears notifications here; that
  /// happens only through [chatMarkRead].
  Future<List<ChatMessage>> _chatGet(String token, Map<String, String> query,
      {required Duration timeout}) async {
    final path = '$_chatV1/$token';
    final uri = Uri.parse('${creds.server}$path').replace(queryParameters: {
      'limit': '100',
      'setReadMarker': '0',
      'markNotificationsAsRead': '0',
      'includeLastKnown': '0',
      ...query,
    });
    final req = await _http.getUrl(uri);
    _authHeaders(req);
    req.cookies.addAll(_cookies.values);
    try {
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode == 304) return const [];
      if (res.statusCode >= 300) throw ApiException(res.statusCode, path);
      final data = (jsonDecode(text) as Map)['ocs']?['data'];
      return [
        for (final m in data as List)
          ChatMessage.fromJson((m as Map).cast<String, dynamic>()),
      ];
    } on TimeoutException {
      req.abort();
      rethrow;
    }
  }

  @override
  Future<List<ChatMessage>> chatHistory(String token, {int? beforeId}) =>
      _chatGet(
          token,
          {
            'lookIntoFuture': '0',
            if (beforeId != null) 'lastKnownMessageId': '$beforeId',
          },
          timeout: const Duration(seconds: 30));

  @override
  Future<List<ChatMessage>> chatWait(String token, int afterId) => _chatGet(
      token,
      {
        'lookIntoFuture': '1',
        'lastKnownMessageId': '$afterId',
        'timeout': '30',
      },
      timeout: const Duration(seconds: 45));

  @override
  Future<ChatMessage> chatSend(String token, String text, String referenceId,
      {int? replyTo}) async {
    final d = await _ocs('POST', '$_chatV1/$token', body: {
      'message': text,
      'referenceId': referenceId,
      'replyTo': ?replyTo,
    });
    return ChatMessage.fromJson((d as Map).cast<String, dynamic>());
  }

  /// The response is a hidden system message whose parent is the changed one.
  ChatMessage? _changedMessage(dynamic d) => d is Map
      ? ChatMessage.fromJson(d.cast<String, dynamic>()).parent
      : null;

  @override
  Future<ChatMessage?> chatEdit(
      String token, int messageId, String text) async {
    return _changedMessage(await _ocs('PUT', '$_chatV1/$token/$messageId',
        body: {'message': text}));
  }

  @override
  Future<ChatMessage?> chatDelete(String token, int messageId) async {
    return _changedMessage(await _ocs('DELETE', '$_chatV1/$token/$messageId'));
  }

  /// Removes only this user. The conversation carries on for everyone else.
  Future<void> leaveConversation(String token) =>
      _ocs('DELETE', '$_talkV4/room/$token/participants/self');

  /// Called with each fresh list of chat notifications.
  void Function(List<ChatNote> notes)? onChatNotes;

  /// Called after the read marker moves in a conversation.
  void Function(String token)? onConversationRead;

  @override
  Future<void> chatMarkRead(String token, int id) async {
    await _ocs('POST', '$_chatV1/$token/read', body: {'lastReadMessage': id});
    onConversationRead?.call(token);
  }

  @override
  Future<void> chatReact(String token, int messageId, String emoji,
      {required bool remove}) {
    final path = '/ocs/v2.php/apps/spreed/api/v1/reaction/$token/$messageId';
    return remove
        ? _ocs('DELETE',
            '$path?reaction=${Uri.encodeQueryComponent(emoji)}')
        : _ocs('POST', path, body: {'reaction': emoji});
  }

  Map<String, dynamic>? _attachmentConfig;
  String? _userId;

  Future<Map<String, dynamic>> _attachments() async {
    final known = _attachmentConfig;
    if (known != null) return known;
    final d = await _ocs('GET', '/ocs/v2.php/cloud/capabilities');
    final cfg = d['capabilities']?['spreed']?['config']?['attachments'];
    return _attachmentConfig =
        cfg is Map ? cfg.cast<String, dynamic>() : const {};
  }

  /// The login name can differ from the user id that file paths need.
  Future<String> _uid() async => _userId ??=
      (await _ocs('GET', '/ocs/v2.php/cloud/user'))['id'] as String;

  @override
  Future<bool> chatUploadsAllowed() async =>
      (await _attachments())['allowed'] == true;

  Uri _davUri(String uid, List<String> segments) {
    final base = Uri.parse(creds.server);
    return base.replace(pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      'remote.php',
      'dav',
      'files',
      uid,
      ...segments,
    ]);
  }

  /// `If-None-Match: *` makes the server refuse rather than overwrite a file
  /// that already has this name.
  Future<int> _davPut(Uri uri, File file, int length) async {
    final req = await _http.putUrl(uri);
    _authHeaders(req);
    req.followRedirects = false;
    req.headers
      ..set('If-None-Match', '*')
      ..contentLength = length
      ..contentType = ContentType.binary;
    await req.addStream(file.openRead());
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  }

  Future<void> _davMkdirs(String uid, List<String> folder) async {
    for (var i = 1; i <= folder.length; i++) {
      final uri = _davUri(uid, folder.sublist(0, i));
      final req = await _http.openUrl('MKCOL', uri);
      _authHeaders(req);
      final res = await req.close();
      await res.drain<void>();
      // 405 means the folder already exists.
      if (res.statusCode >= 300 && res.statusCode != 405) {
        throw ApiException(res.statusCode, 'creating attachment folder');
      }
    }
  }

  @override
  Future<String> chatUpload(String localPath) async {
    final cfg = await _attachments();
    if (cfg['allowed'] != true) throw ApiException(403, 'attachments');
    final uid = await _uid();
    final folder = '${cfg['folder'] ?? '/Talk'}'
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    final file = File(localPath);
    final length = await file.length();
    final name = localPath.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';

    var madeFolder = false;
    var attempt = 0;
    while (attempt < 100) {
      final candidate = attempt == 0 ? name : '$stem ($attempt)$ext';
      final status =
          await _davPut(_davUri(uid, [...folder, candidate]), file, length);
      if (status < 300) return '/${[...folder, candidate].join('/')}';
      if (status == 412) {
        attempt++;
      } else if ((status == 404 || status == 409) && !madeFolder) {
        madeFolder = true;
        await _davMkdirs(uid, folder);
      } else {
        throw ApiException(status, 'uploading a file');
      }
    }
    throw ApiException(412, 'uploading a file: too many name conflicts');
  }

  @override
  Future<void> chatShareFile(
      String token, String remotePath, String referenceId) async {
    await _ocs('POST', '/ocs/v2.php/apps/files_sharing/api/v1/shares', body: {
      'shareType': 10,
      'shareWith': token,
      'path': remotePath,
      'referenceId': referenceId,
    });
  }

  static const _maxPreviewBytes = 20 * 1024 * 1024;

  @override
  Future<Uint8List> chatPreview(int fileId) async {
    const path = '/index.php/core/preview';
    final uri = Uri.parse('${creds.server}$path').replace(queryParameters: {
      'fileId': '$fileId',
      'x': '960',
      'y': '720',
      'a': '1',
    });
    final req = await _http.getUrl(uri);
    _authHeaders(req);
    req.cookies.addAll(_cookies.values);
    final res = await req.close();
    if (res.statusCode >= 300) {
      await res.drain<void>();
      throw ApiException(res.statusCode, path);
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in res) {
      out.add(chunk);
      if (out.length > _maxPreviewBytes) {
        throw ApiException(413, path);
      }
    }
    return out.takeBytes();
  }

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
    onChatNotes?.call([
      for (final n in data)
        if (n['app'] == 'spreed' &&
            n['object_type'] == 'chat' &&
            n['shouldNotify'] != false)
          ChatNote(
            n['notification_id'] as int,
            // Some versions append the message id after a slash.
            (n['object_id'] as String).split('/').first,
            (n['subject'] ?? 'New message') as String,
            (n['message'] ?? '') as String,
          ),
    ]);
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
    final rooms = [
      for (final r in data) Room.fromJson((r as Map).cast<String, dynamic>()),
    ];
    return rooms
      ..sort((a, b) {
        if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
        return b.lastActivity.compareTo(a.lastActivity);
      });
  }

  /// Read-only check against the real server. Logs only counts and message
  /// kinds, never names or text.
  Future<void> chatCheck() async {
    final rooms = await this.rooms();
    log('check: ${rooms.length} conversations, '
        '${rooms.where((r) => r.lastMessage != null).length} with a last message, '
        'types ${rooms.map((r) => r.type).toSet()}, '
        'chat allowed ${rooms.where((r) => r.canChat).length}, '
        'calls allowed ${rooms.where((r) => r.canCall).length}');
    var total = 0, hidden = 0, withParent = 0;
    final kinds = <String>{}, types = <String>{};
    final segments = <SegmentKind>{};
    for (final r in rooms) {
      try {
        final got = await chatHistory(r.token);
        total += got.length;
        for (final m in got) {
          if (m.isHidden) hidden++;
          if (m.parent != null) withParent++;
          if (m.systemKind.isNotEmpty) kinds.add(m.systemKind);
          types.add(m.type);
          segments.addAll(m.segments.map((s) => s.kind));
        }
      } catch (e) {
        log('check: a conversation failed: $e');
      }
    }
    log('check: $total messages parsed, $hidden hidden, $withParent replies');
    log('check: types $types');
    log('check: system kinds $kinds');
    log('check: segments $segments');
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
