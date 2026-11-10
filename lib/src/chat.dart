import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'log.dart';
import 'markdown.dart';
import 'mentions.dart';

class ApiException implements Exception {
  ApiException(this.status, this.path);
  final int status;
  final String path;
  @override
  String toString() => 'HTTP $status on $path';
}

enum SegmentKind { text, mention, file, link }

/// One styled run of a message's text.
class Segment {
  const Segment(this.text, this.kind, [this.url, this.previewFileId])
    : style = const MdStyle();
  const Segment.styled(
    this.text,
    this.kind,
    this.url,
    this.previewFileId,
    this.style,
  );
  final String text;
  final SegmentKind kind;

  /// Bold and so on, from a Markdown message.
  final MdStyle style;

  Segment withStyle(MdStyle added) => style.isPlain && added.isPlain
      ? this
      : Segment.styled(text, kind, url, previewFileId, style.plus(added));

  /// Set on an image file the server can show a preview of.
  final int? previewFileId;

  /// Only ever http or https, so a message can't launch anything else.
  final String? url;
}

const _mentionTypes = {
  'user',
  'guest',
  'call',
  'group',
  'user-group',
  'email',
  'circle',
  'team',
  'federated_user',
};

final _placeholder = RegExp(r'\{([A-Za-z0-9_\-]+)\}');
final _urlPattern = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);

String? safeUrl(Object? url) {
  if (url is! String) return null;
  final uri = Uri.tryParse(url);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
      ? url
      : null;
}

List<Segment> _linkify(String text) {
  final out = <Segment>[];
  var at = 0;
  for (final m in _urlPattern.allMatches(text)) {
    var url = m.group(0)!;
    // Sentence punctuation after a link isn't part of it.
    final trimmed = url.replaceFirst(RegExp(r'[.,;:!?)\]]+$'), '');
    if (safeUrl(trimmed) == null || trimmed.isEmpty) continue;
    url = trimmed;
    if (m.start > at) {
      out.add(Segment(text.substring(at, m.start), SegmentKind.text));
    }
    out.add(Segment(url, SegmentKind.link, url));
    at = m.start + url.length;
  }
  if (at < text.length) {
    out.add(Segment(text.substring(at), SegmentKind.text));
  }
  return out;
}

/// Splits Talk's "{mention-user1} see {file}" form into runs. A placeholder
/// with no matching parameter stays as typed.
List<Segment> parseMessage(String message, Map<String, dynamic> params) {
  final out = <Segment>[];
  var at = 0;
  for (final m in _placeholder.allMatches(message)) {
    final p = params[m.group(1)];
    if (p is! Map || p['name'] is! String) continue;
    if (m.start > at) out.addAll(_linkify(message.substring(at, m.start)));
    final name = p['name'] as String;
    final type = p['type'];
    if (type == 'file') {
      final id = int.tryParse('${p['id']}');
      final image = '${p['mimetype']}'.startsWith('image/') &&
          p['preview-available'] == 'yes';
      out.add(Segment(
          name, SegmentKind.file, safeUrl(p['link']), image ? id : null));
    } else if (_mentionTypes.contains(type)) {
      out.add(Segment(name, SegmentKind.mention));
    } else {
      out.add(Segment(name, SegmentKind.text));
    }
    at = m.end;
  }
  if (at < message.length) out.addAll(_linkify(message.substring(at)));
  return out;
}

/// The text to put back in the composer for editing. Mentions must return to
/// the `@"id"` form the server reads, or saving would turn them into plain text.
String editableText(String message, Map<String, dynamic> params) =>
    message.replaceAllMapped(_placeholder, (m) {
      final p = params[m.group(1)];
      if (p is! Map || p['name'] is! String) return m.group(0)!;
      if (_mentionTypes.contains(p['type'])) {
        final id = p['mention-id'] ?? p['id'];
        if (id is String) return '@"$id"';
      }
      return p['name'] as String;
    });

/// The server sends an empty JSON list instead of an empty object here.
Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const {};

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.actorType,
    required this.actorId,
    required this.actorName,
    required this.timestamp,
    required this.segments,
    this.systemKind = '',
    this.type = 'comment',
    this.referenceId = '',
    this.parent,
    this.edited = false,
    this.parentDeleted = false,
    this.isReplyable = false,
    this.reactions = const {},
    this.reactionsSelf = const [],
    this.editSource = '',
    this.blocks,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final parent = _map(j['parent']);
    final raw = j['message'] as String? ?? '';
    final params = _map(j['messageParameters']);
    final hasParent = parent['id'] is int;
    // The server's call: system messages and old servers' messages aren't.
    final blocks = j['markdown'] == true ? parseMarkdown(raw, params) : null;
    return ChatMessage(
      id: j['id'] as int? ?? 0,
      actorType: j['actorType'] as String? ?? '',
      actorId: j['actorId'] as String? ?? '',
      actorName: j['actorDisplayName'] as String? ?? '',
      timestamp: j['timestamp'] as int? ?? 0,
      segments: blocks != null
          ? flattenMarkdown(blocks)
          : parseMessage(raw, params),
      blocks: blocks,
      editSource: editableText(raw, params),
      systemKind: j['systemMessage'] as String? ?? '',
      type: j['messageType'] as String? ?? 'comment',
      referenceId: j['referenceId'] as String? ?? '',
      parent: hasParent ? ChatMessage.fromJson(parent) : null,
      edited: (j['lastEditTimestamp'] as int? ?? 0) > 0,
      parentDeleted: parent['deleted'] == true,
      isReplyable: j['isReplyable'] == true,
      reactions: {
        for (final e in _map(j['reactions']).entries)
          if (e.value is int && (e.value as int) > 0) e.key: e.value as int,
      },
      reactionsSelf: [
        for (final r in (j['reactionsSelf'] as List? ?? const []))
          if (r is String) r,
      ],
    );
  }

  final int id;
  final String actorType;
  final String actorId;
  final String actorName;
  final int timestamp;
  final List<Segment> segments;

  /// How to lay out a formatted message. Null means [segments] as one paragraph.
  final List<MdBlock>? blocks;
  final String systemKind;
  final String type;
  final String referenceId;
  final ChatMessage? parent;
  final bool edited;
  final bool parentDeleted;
  final bool isReplyable;
  final Map<String, int> reactions;
  final List<String> reactionsSelf;
  final String editSource;

  String get text => segments.map((s) => s.text).join();
  bool get isSystem => systemKind.isNotEmpty || type == 'system';
  bool get isDeleted => type == 'comment_deleted';

  /// Bookkeeping entries: they change another message rather than being one.
  bool get isHidden => _hiddenKinds.contains(systemKind);

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);

  bool get canReact => !isSystem && !isDeleted;

  /// Whether this kind of message can be deleted. The server still checks who
  /// is asking.
  bool get canDelete => !isSystem && !isDeleted;

  /// Attachments are left out: only their caption could change, and Tala
  /// doesn't add captions.
  bool get canEdit =>
      type == 'comment' &&
      !isSystem &&
      segments.every((s) => s.kind != SegmentKind.file);

  /// A copy with the user's own [emoji] added or removed.
  ChatMessage withOwnReaction(String emoji, {required bool add}) {
    final counts = {...reactions};
    final count = (counts[emoji] ?? 0) + (add ? 1 : -1);
    if (count > 0) {
      counts[emoji] = count;
    } else {
      counts.remove(emoji);
    }
    return ChatMessage(
      id: id,
      actorType: actorType,
      actorId: actorId,
      actorName: actorName,
      timestamp: timestamp,
      segments: segments,
      blocks: blocks,
      systemKind: systemKind,
      type: type,
      referenceId: referenceId,
      parent: parent,
      edited: edited,
      parentDeleted: parentDeleted,
      isReplyable: isReplyable,
      editSource: editSource,
      reactions: counts,
      reactionsSelf: add
          ? [...reactionsSelf, emoji]
          : reactionsSelf.where((e) => e != emoji).toList(),
    );
  }
}

const _hiddenKinds = {
  'reaction',
  'reaction_deleted',
  'reaction_revoked',
  'message_deleted',
  'message_edited',
  'poll_voted',
};

abstract class ChatSource {
  /// The latest page of messages, in any order. [beforeId] pages backward.
  Future<List<ChatMessage>> chatHistory(String token, {int? beforeId});

  /// Waits on the server for anything after [afterId]; empty when none came.
  Future<List<ChatMessage>> chatWait(String token, int afterId);
  Future<ChatMessage> chatSend(String token, String text, String referenceId,
      {int? replyTo});
  Future<void> chatMarkRead(String token, int id);
  Future<void> chatReact(String token, int messageId, String emoji,
      {required bool remove});

  /// These return the changed message, when the server includes it.
  Future<ChatMessage?> chatEdit(String token, int messageId, String text);
  Future<ChatMessage?> chatDelete(String token, int messageId);

  /// Whether this server lets the user attach files to chats.
  Future<bool> chatUploadsAllowed();

  /// Stores a local file in the user's attachment folder and returns its path
  /// there. Never overwrites an existing file.
  Future<String> chatUpload(String localPath);

  /// Posts an uploaded file to the conversation.
  Future<void> chatShareFile(
      String token, String remotePath, String referenceId);

  /// A preview of an image the user can already access.
  Future<Uint8List> chatPreview(int fileId);

  /// Who can be mentioned here whose name matches [search], which may be empty.
  Future<List<MentionOption>> chatMentions(String token, String search);

  /// The newest message everyone has read, from the last fetch of [token].
  /// Null when the server doesn't say, which it doesn't if the user keeps
  /// their own read status private.
  int? chatLastCommonRead(String token);
}

enum SendState { sending, failed }

class OutgoingMessage {
  OutgoingMessage(
    this.text,
    this.referenceId, {
    this.replyTo,
    this.filePath,
    String? wireText,
  }) : wireText = wireText ?? text;

  /// What's shown while sending.
  final String text;

  /// What the server gets, which holds mentions as ids.
  final String wireText;
  final String referenceId;
  final int? replyTo;

  /// Set when this is a file rather than a text message.
  final String? filePath;

  /// Kept after a successful upload, so retrying only redoes the share and
  /// doesn't leave a second copy of the file.
  String? remotePath;
  SendState state = SendState.sending;
  String? error;
}

/// The server asks for a random 64 character hex reference.
String newReferenceId() {
  final r = Random.secure();
  return List.generate(64, (_) => r.nextInt(16).toRadixString(16)).join();
}

/// One conversation's messages, kept current by long polling. It marks the
/// conversation read only while [active], so an unfocused window leaves new
/// messages unread.
class ChatThread extends ChangeNotifier {
  ChatThread(this._source, this.token,
      {int lastRead = 0,
      this.retryStart = const Duration(seconds: 2),
      this.retryMax = const Duration(seconds: 30),
      this.minPollGap = const Duration(seconds: 1)})
      : _lastMarked = lastRead;

  final ChatSource _source;
  final String token;
  final Duration retryStart;
  final Duration retryMax;
  final Duration minPollGap;

  final Map<int, ChatMessage> _byId = {};
  final List<OutgoingMessage> _outgoing = [];
  int _newestId = 0;
  int _oldestId = 0;
  int _lastMarked;
  bool _disposed = false;
  bool _active = false;
  bool _loadingOlder = false;

  bool loading = true;
  bool hasOlder = true;

  /// Own messages up to this one have been read by everyone. Null if unknown.
  int? lastCommonRead;

  /// Whether the read point moved; the caller notifies.
  bool _takeLastCommonRead() {
    final got = _source.chatLastCommonRead(token);
    if (got == null || got == lastCommonRead) return false;
    lastCommonRead = got;
    return true;
  }

  /// Set while the connection is failing; retries continue underneath.
  String? problem;

  /// True when the user can no longer read this conversation.
  bool gone = false;

  List<ChatMessage> get messages =>
      _byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  List<OutgoingMessage> get outgoing => List.unmodifiable(_outgoing);
  bool get loadingOlder => _loadingOlder;

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    _markReadIfActive();
  }

  void start() => unawaited(_run());

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _track(ChatMessage m) {
    if (m.id > _newestId) _newestId = m.id;
    if (_oldestId == 0 || m.id < _oldestId) _oldestId = m.id;
  }

  void _addVisible(ChatMessage m) {
    if (!m.isHidden && m.id > 0) _byId[m.id] = m;
  }

  void _ingestHistory(List<ChatMessage> got) {
    for (final m in got) {
      _track(m);
      _addVisible(m);
    }
  }

  void _ingestLive(List<ChatMessage> got) {
    final ascending = [...got]..sort((a, b) => a.id.compareTo(b.id));
    for (final m in ascending) {
      _track(m);
      if (m.systemKind == 'history_cleared') _byId.clear();
      // An edit or delete carries the changed message as its parent.
      final parent = m.parent;
      if (parent != null && m.isHidden && _byId.containsKey(parent.id)) {
        _byId[parent.id] = parent;
      }
      _addVisible(m);
      if (m.referenceId.isNotEmpty) {
        _outgoing.removeWhere((o) => o.referenceId == m.referenceId);
      }
    }
  }

  Future<void> _run() async {
    var delay = retryStart;
    while (!_disposed && !gone && loading) {
      try {
        final got = await _source.chatHistory(token);
        if (_disposed) return;
        _ingestHistory(got);
        _takeLastCommonRead();
        if (got.isEmpty) hasOlder = false;
        loading = false;
        problem = null;
        _changed();
        _markReadIfActive();
      } catch (e) {
        if (_disposed) return;
        _fail(e);
        if (gone) return;
        await Future<void>.delayed(delay);
        delay = _next(delay);
      }
    }
    delay = retryStart;
    while (!_disposed && !gone) {
      final clock = Stopwatch()..start();
      try {
        final got = await _source.chatWait(token, _newestId);
        if (_disposed) return;
        delay = retryStart;
        final recovered = problem != null;
        problem = null;
        if (got.isNotEmpty) {
          _ingestLive(got);
          _markReadIfActive();
        }
        final readMoved = _takeLastCommonRead();
        if (got.isNotEmpty || recovered || readMoved) _changed();
        // A server that answers instantly shouldn't turn this into a spin.
        if (got.isEmpty && clock.elapsed < minPollGap) {
          await Future<void>.delayed(minPollGap);
        }
      } catch (e) {
        if (_disposed) return;
        _fail(e);
        if (gone) return;
        await Future<void>.delayed(delay);
        delay = _next(delay);
      }
    }
  }

  Duration _next(Duration d) {
    final doubled = d * 2;
    return doubled > retryMax ? retryMax : doubled;
  }

  void _fail(Object e) {
    final status = _statusOf(e);
    if (status == 403 || status == 404) {
      log('chat: conversation unavailable ($status)');
      gone = true;
      loading = false;
      problem = null;
    } else {
      if (problem == null) log('chat: connection problem: $e');
      problem = 'Connection lost. Retrying…';
    }
    _changed();
  }

  int? _statusOf(Object e) => e is ApiException ? e.status : null;

  Future<void> loadOlder() async {
    if (_loadingOlder || loading || !hasOlder || _oldestId == 0) return;
    _loadingOlder = true;
    _changed();
    try {
      final got = await _source.chatHistory(token, beforeId: _oldestId);
      if (_disposed) return;
      if (got.isEmpty) hasOlder = false;
      _ingestHistory(got);
    } catch (e) {
      log('chat: loading older messages failed: $e');
    } finally {
      _loadingOlder = false;
      _changed();
    }
  }

  /// Returns once the attempt finishes. A failure stays listed for retry.
  /// [wireText] is what the server gets, when that differs from what's shown
  /// until the server's copy arrives, as with mentions.
  Future<void> send(String text, {int? replyTo, String? wireText}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final o = OutgoingMessage(
      trimmed,
      newReferenceId(),
      replyTo: replyTo,
      wireText: wireText?.trim(),
    );
    _outgoing.add(o);
    _changed();
    await _attempt(o);
  }

  /// Uploads and posts a local file. A failure stays listed for retry.
  Future<void> sendFile(String path) async {
    final name = path.split(Platform.pathSeparator).last;
    final o = OutgoingMessage(name, newReferenceId(), filePath: path);
    _outgoing.add(o);
    _changed();
    await _attempt(o);
  }

  /// Adds or removes the user's reaction, showing it immediately. Returns
  /// false, with the message restored, if the server refused.
  Future<bool> toggleReaction(int messageId, String emoji) async {
    final before = _byId[messageId];
    if (before == null) return false;
    final remove = before.reactionsSelf.contains(emoji);
    final shown = before.withOwnReaction(emoji, add: !remove);
    _byId[messageId] = shown;
    _changed();
    try {
      await _source.chatReact(token, messageId, emoji, remove: remove);
      return true;
    } catch (e) {
      log('chat: reaction failed: $e');
      if (_disposed) return false;
      // Leave it alone if a newer version arrived from the server meanwhile.
      if (identical(_byId[messageId], shown)) _byId[messageId] = before;
      _changed();
      return false;
    }
  }

  /// Saves new text for a message. Returns why it failed, or null on success.
  Future<String?> editMessage(int messageId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'A message can\'t be empty.';
    if (trimmed == _byId[messageId]?.editSource.trim()) return null;
    try {
      _applyChange(await _source.chatEdit(token, messageId, trimmed));
      return null;
    } catch (e) {
      log('chat: edit failed: $e');
      return switch (_statusOf(e)) {
        400 => 'This message can\'t be edited. It may be over 24 hours old.',
        403 => 'You can\'t edit this message.',
        404 => 'This message no longer exists.',
        _ => 'Couldn\'t save the change.',
      };
    }
  }

  /// Deletes a message for everyone. Returns why it failed, or null on success.
  Future<String?> deleteMessage(int messageId) async {
    try {
      _applyChange(await _source.chatDelete(token, messageId));
      return null;
    } catch (e) {
      log('chat: delete failed: $e');
      return switch (_statusOf(e)) {
        400 => 'This message is too old to delete.',
        403 => 'You can\'t delete this message.',
        404 => 'This message no longer exists.',
        _ => 'Couldn\'t delete the message.',
      };
    }
  }

  void _applyChange(ChatMessage? changed) {
    if (changed == null || _disposed || !_byId.containsKey(changed.id)) return;
    _byId[changed.id] = changed;
    _changed();
  }

  Future<void> retry(OutgoingMessage o) async {
    if (o.state != SendState.failed) return;
    o
      ..state = SendState.sending
      ..error = null;
    _changed();
    await _attempt(o);
  }

  void discard(OutgoingMessage o) {
    _outgoing.remove(o);
    _changed();
  }

  Future<void> _attempt(OutgoingMessage o) async {
    try {
      final file = o.filePath;
      if (file != null) {
        final remote = o.remotePath ??= await _source.chatUpload(file);
        await _source.chatShareFile(token, remote, o.referenceId);
        if (_disposed) return;
        // The poll delivers the resulting message.
      } else {
        final sent = await _source.chatSend(token, o.wireText, o.referenceId,
            replyTo: o.replyTo);
        if (_disposed) return;
        // The poll advances _newestId; doing it here could skip a message
        // someone else sent just before this one.
        _addVisible(sent);
      }
      _outgoing.remove(o);
    } catch (e) {
      log('chat: send failed: $e');
      if (_disposed) return;
      o
        ..state = SendState.failed
        ..error = switch (_statusOf(e)) {
          413 => o.filePath != null ? 'File too large' : 'Message too long',
          507 => 'Not enough storage on the server',
          _ => 'Not sent',
        };
    }
    _changed();
  }

  void _markReadIfActive() {
    if (!_active || loading || _newestId <= _lastMarked) return;
    final id = _newestId;
    _lastMarked = id;
    _source.chatMarkRead(token, id).catchError((Object e) {
      log('chat: marking read failed: $e');
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
