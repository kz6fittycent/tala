import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_info.dart';
import 'chat.dart';
import 'chat_alerts.dart';
import 'incoming_calls.dart';
import 'log.dart';
import 'mentions.dart';

/// Also the device name the server lists for Tala's app password.
const _userAgent = 'Tala/$appVersion';

/// Thrown when the user abandons a sign-in that's waiting on the browser.
class LoginCancelled implements Exception {}

class Credentials {
  Credentials(this.server, this.user, this.appPassword);
  final String server;
  final String user;
  final String appPassword;
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
    this.archived = false,
    this.canArchive = false,
    this.muted = false,
    this.remoteServer = '',
    this.hasPassword = false,
    this.canDelete = false,
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
      archived: r['isArchived'] == true,
      // Servers too old to archive don't send the field at all.
      canArchive: r.containsKey('isArchived'),
      muted: r['notificationLevel'] == 3,
      remoteServer: r['remoteServer'] as String? ?? '',
      hasPassword: r['hasPassword'] == true,
      canDelete: r['canDeleteConversation'] == true,
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
  final bool archived;
  final bool canArchive;
  final bool muted;

  /// Where a federated conversation really lives, or empty for a local one.
  final String remoteServer;

  /// Guests need a password as well as the link.
  final bool hasPassword;

  /// Conversations with a member list. One-to-ones always have the same two
  /// people, and the others are system conversations.
  bool get hasMembers => type == 2 || type == 3;

  /// Moderators manage a local conversation. A federated one's members and
  /// name belong to the server hosting it.
  bool get canManage => hasMembers && isModerator && remoteServer.isEmpty;

  /// A link lets people join without an account. Federated conversations
  /// aren't this server's to share.
  bool get hasGuestLink => type == 3 && remoteServer.isEmpty;

  /// The server's own answer on whether this user may delete it for everyone.
  final bool canDelete;

  /// Guest conversations, and groups the user can't otherwise leave, such as
  /// a guest conversation whose link was turned off. Other groups only offer
  /// leaving, so nobody deletes a shared conversation by accident.
  bool get offersDelete =>
      canDelete &&
      remoteServer.isEmpty &&
      (type == 3 || (type == 2 && !canLeave));
  bool get isFederated => remoteServer.isNotEmpty;
}

/// What the dock badge counts: conversations the user chose to quiet by
/// archiving or muting would otherwise keep it lit forever.
int dockUnread(Iterable<Room> rooms) => rooms
    .where((r) => !r.archived && !r.muted)
    .fold(0, (sum, r) => sum + r.unread);

/// Someone found on the server.
class Person {
  Person(this.id, this.name, this.detail);
  final String id;
  final String name;
  final String detail;
}

/// Someone in a conversation, as the server lists them.
class Member {
  Member({
    required this.attendeeId,
    required this.actorType,
    required this.actorId,
    required this.name,
    required this.participantType,
  });

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    attendeeId: j['attendeeId'] as int,
    actorType: j['actorType'] as String? ?? '',
    actorId: j['actorId'] as String? ?? '',
    name: j['displayName'] as String? ?? '',
    participantType: j['participantType'] as int? ?? 3,
  );

  final int attendeeId;

  /// users, guests, emails, groups, circles or federated_users.
  final String actorType;
  final String actorId;
  final String name;

  /// 1 owner, 2 moderator, 3 user, 4 guest, 5 joined by link, 6 guest moderator.
  final int participantType;

  bool get isOwner => participantType == 1;
  bool get isModerator => const {1, 2, 6}.contains(participantType);

  /// A whole group or circle is listed as one entry, and has no single person
  /// to promote.
  bool get canBeModerator =>
      !isOwner && const {'users', 'guests', 'emails'}.contains(actorType);

  bool get isGuest => actorType == 'guests' || actorType == 'emails';

  String get displayName => name.isNotEmpty
      ? name
      : isGuest
      ? 'Guest'
      : actorId;

  String get role {
    if (isOwner) return 'Owner';
    if (isModerator) return 'Moderator';
    return switch (actorType) {
      'guests' || 'emails' => 'Guest',
      'groups' => 'Group',
      'circles' => 'Team',
      'federated_users' => 'On another server',
      _ => '',
    };
  }
}

/// An invitation to a conversation on another server.
class FederationInvite {
  FederationInvite(this.id, this.roomName, this.inviter, this.server);

  factory FederationInvite.fromJson(Map<String, dynamic> j) => FederationInvite(
    j['id'] as int,
    j['roomName'] as String? ?? '?',
    j['inviterDisplayName'] as String? ?? j['inviterCloudId'] as String? ?? '?',
    j['remoteServerUrl'] as String? ?? '',
  );

  final int id;
  final String roomName;
  final String inviter;
  final String server;
}

class SignalingSettings {
  SignalingSettings(this.raw);
  final Map<String, dynamic> raw;
  String get server => (raw['server'] ?? '') as String;
  String get ticket => (raw['ticket'] ?? '') as String;
  String? get userId => raw['userId'] as String?;
  Map<String, dynamic>? get helloV2 =>
      (raw['helloAuthParams'] as Map?)?['2.0']?.cast<String, dynamic>();

  /// The room block's extra part when the conversation lives on another
  /// server, or null for a local one. Mirrors the official web client.
  Map<String, dynamic>? get federationJoin {
    final f = raw['federation'];
    if (f is! Map || (f['server'] as String? ?? '').isEmpty) return null;
    final server = (f['nextcloudServer'] as String).replaceAll(
      RegExp(r'/+$'),
      '',
    );
    return {
      'signaling': f['server'],
      'url': '$server/ocs/v2.php/apps/spreed/api/v3/signaling/backend',
      'roomid': f['roomId'],
      'token': f['helloAuthParams']?['token'],
    };
  }

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
  final HttpClient _http = HttpClient()..userAgent = _userAgent;
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

  /// Only this user's view changes. The conversation carries on for others.
  Future<void> setArchived(String token, bool archived) => _ocs(
    archived ? 'POST' : 'DELETE',
    '$_talkV4/room/$token/archive',
  );

  static const _invitesPath = '/ocs/v2.php/apps/spreed/api/v1/federation/invitation';

  /// Pending invitations only; the server also lists accepted ones.
  Future<List<FederationInvite>> federationInvites() async {
    final data = await _ocs('GET', _invitesPath);
    return [
      for (final i in data as List)
        if (i['state'] == 0)
          FederationInvite.fromJson((i as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> acceptInvite(int id) => _ocs('POST', '$_invitesPath/$id');
  Future<void> declineInvite(int id) => _ocs('DELETE', '$_invitesPath/$id');

  /// People to start a conversation with. Never includes the user themselves.
  Future<List<Person>> searchPeople(String query) async {
    final search = Uri.encodeQueryComponent(query);
    final data = await _ocs(
      'GET',
      '/ocs/v2.php/core/autocomplete/get?search=$search'
      '&itemType=call&itemId=new&shareTypes%5B%5D=0&limit=20',
    );
    final self = await _uid();
    return [
      for (final p in data as List)
        if (p['source'] == 'users' && p['id'] != self)
          Person(
            p['id'] as String,
            (p['label'] ?? p['id']) as String,
            (p['subline'] ?? p['shareWithDisplayNameUnique'] ?? '') as String,
          ),
    ];
  }

  /// Returns the conversation's token. The server gives back the existing one
  /// if these two already have a conversation.
  Future<String> startOneToOne(String userId) async {
    final d = await _ocs(
      'POST',
      '$_talkV4/room',
      body: {'roomType': 1, 'invite': userId},
    );
    return (d as Map)['token'] as String;
  }

  /// Creates a group with only the user in it. Members are added one at a time.
  Future<String> createGroup(String name) async {
    final d = await _ocs(
      'POST',
      '$_talkV4/room',
      body: {'roomType': 2, 'roomName': name},
    );
    return (d as Map)['token'] as String;
  }

  Future<List<Member>> members(String token) async {
    final data = await _ocs('GET', '$_talkV4/room/$token/participants');
    return [
      for (final m in data as List)
        Member.fromJson((m as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> addMember(String token, String userId) => _ocs(
    'POST',
    '$_talkV4/room/$token/participants',
    body: {'newParticipant': userId, 'source': 'users'},
  );

  /// Takes the id in the address, as the web client does: this is a DELETE, and
  /// a body on one isn't dependable.
  Future<void> removeMember(String token, int attendeeId) =>
      _ocs('DELETE', '$_talkV4/room/$token/attendees?attendeeId=$attendeeId');

  Future<void> setModerator(String token, int attendeeId, bool moderator) =>
      moderator
      ? _ocs(
          'POST',
          '$_talkV4/room/$token/moderators',
          body: {'attendeeId': attendeeId},
        )
      : _ocs(
          'DELETE',
          '$_talkV4/room/$token/moderators?attendeeId=$attendeeId',
        );

  Future<void> renameConversation(String token, String name) =>
      _ocs('PUT', '$_talkV4/room/$token', body: {'roomName': name});

  /// Creates a conversation people can join by link, without an account.
  Future<String> createGuestConversation(String name, String password) async {
    final d = await _ocs(
      'POST',
      '$_talkV4/room',
      body: {
        'roomType': 3,
        'roomName': name,
        if (password.isNotEmpty) 'password': password,
      },
    );
    return (d as Map)['token'] as String;
  }

  /// The server emails the invitation, with the conversation's link.
  Future<void> inviteByEmail(String token, String email) => _ocs(
    'POST',
    '$_talkV4/room/$token/participants',
    body: {'newParticipant': email, 'source': 'emails'},
  );

  /// The link stops working and guests lose access. Members stay.
  Future<void> turnOffGuestLink(String token) =>
      _ocs('DELETE', '$_talkV4/room/$token/public');

  /// Gone for every participant, guests included, with its messages.
  Future<void> deleteConversation(String token) =>
      _ocs('DELETE', '$_talkV4/room/$token');

  /// Whether the server has stopped accepting this app password, as opposed to
  /// one request being refused or the network being down.
  Future<bool> signInRejected() async {
    try {
      await _ocs('GET', '/ocs/v2.php/cloud/user');
      return false;
    } on ApiException catch (e) {
      return e.status == 401;
    } catch (_) {
      return false;
    }
  }

  /// Ends this device's sign-in. Only for when Tala has stopped using it.
  Future<void> revokeAppPassword() =>
      _ocs('DELETE', '/ocs/v2.php/core/apppassword');

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
  Future<List<MentionOption>> chatMentions(String token, String search) async {
    final q = Uri.encodeQueryComponent(search);
    final d = await _ocs('GET', '$_chatV1/$token/mentions?search=$q&limit=6');
    return [
      for (final o in d as List)
        MentionOption.fromJson((o as Map).cast<String, dynamic>()),
    ];
  }

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
      {Map<String, dynamic>? body, HttpClient? via}) async {
    final uri = Uri.parse('${creds.server}$path');
    final req = await (via ?? _http).openUrl(method, uri);
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
    log('check: people search found '
        '${(await searchPeople('a')).length}');
    log('check: ${rooms.length} conversations, '
        '${rooms.where((r) => r.archived).length} archived, '
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

  /// Internal signaling's long poll, which the server holds for up to 30s. The
  /// server finds the session through the cookies set when joining the room.
  Future<Object?> pullSignaling(String token, HttpClient client) =>
      _ocs('GET', '$_talkV3/signaling/$token', via: client)
          .timeout(const Duration(seconds: 45));

  Future<void> sendSignaling(String token, String messages) =>
      _ocs('POST', '$_talkV3/signaling/$token', body: {'messages': messages});

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

  /// Software versions and whether calls can work, for problem reports. Holds
  /// nothing that identifies the server.
  Future<String?> serverSummary() async {
    final d = await _ocs('GET', '/ocs/v2.php/cloud/capabilities') as Map;
    final version = (d['version'] as Map?)?['string'];
    final talk = ((d['capabilities'] as Map?)?['spreed'] as Map?)?['version'];
    return 'Nextcloud ${version ?? '?'}, Talk ${talk ?? '?'}';
  }

  /// Corrects what this participant said it's sending when it joined.
  Future<void> updateCallFlags(String token, int flags) =>
      _ocs('PUT', '$_talkV4/call/$token', body: {'flags': flags});

  Future<void> leaveCall(String token) =>
      _ocs('DELETE', '$_talkV4/call/$token');
}

/// Nextcloud Login Flow v2: the user approves in their browser and the server
/// issues an app password for this device. Passwords never pass through Tala.
/// The caller stores the result.
Future<Credentials> loginFlow(
  String server, {
  bool Function()? isCancelled,
}) async {
  final base = server.replaceAll(RegExp(r'/+$'), '');
  final http = HttpClient()..userAgent = _userAgent;
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
      if (isCancelled?.call() == true) throw LoginCancelled();
      final p = await http.postUrl(Uri.parse(endpoint));
      p.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      p.write('token=${Uri.encodeQueryComponent(token)}');
      final r = await p.close();
      final t = await r.transform(utf8.decoder).join();
      if (r.statusCode == 200) {
        final c = jsonDecode(t) as Map<String, dynamic>;
        log('login: approved');
        return Credentials(c['server'], c['loginName'], c['appPassword']);
      }
    }
    throw TimeoutException('Login was not approved in time');
  } finally {
    http.close();
  }
}
