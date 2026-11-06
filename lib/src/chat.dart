import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'log.dart';

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
  const Segment(this.text, this.kind, [this.url]);
  final String text;
  final SegmentKind kind;

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
      out.add(Segment(name, SegmentKind.file, safeUrl(p['link'])));
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
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final parent = _map(j['parent']);
    final hasParent = parent['id'] is int;
    return ChatMessage(
      id: j['id'] as int? ?? 0,
      actorType: j['actorType'] as String? ?? '',
      actorId: j['actorId'] as String? ?? '',
      actorName: j['actorDisplayName'] as String? ?? '',
      timestamp: j['timestamp'] as int? ?? 0,
      segments: parseMessage(
          j['message'] as String? ?? '', _map(j['messageParameters'])),
      systemKind: j['systemMessage'] as String? ?? '',
      type: j['messageType'] as String? ?? 'comment',
      referenceId: j['referenceId'] as String? ?? '',
      parent: hasParent ? ChatMessage.fromJson(parent) : null,
      edited: (j['lastEditTimestamp'] as int? ?? 0) > 0,
      parentDeleted: parent['deleted'] == true,
    );
  }

  final int id;
  final String actorType;
  final String actorId;
  final String actorName;
  final int timestamp;
  final List<Segment> segments;
  final String systemKind;
  final String type;
  final String referenceId;
  final ChatMessage? parent;
  final bool edited;
  final bool parentDeleted;

  String get text => segments.map((s) => s.text).join();
  bool get isSystem => systemKind.isNotEmpty || type == 'system';
  bool get isDeleted => type == 'comment_deleted';

  /// Bookkeeping entries: they change another message rather than being one.
  bool get isHidden => _hiddenKinds.contains(systemKind);

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
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
  Future<ChatMessage> chatSend(String token, String text, String referenceId);
  Future<void> chatMarkRead(String token, int id);
}

enum SendState { sending, failed }

class OutgoingMessage {
  OutgoingMessage(this.text, this.referenceId);
  final String text;
  final String referenceId;
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
        if (got.isNotEmpty || recovered) _changed();
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
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final o = OutgoingMessage(trimmed, newReferenceId());
    _outgoing.add(o);
    _changed();
    await _attempt(o);
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
      final sent = await _source.chatSend(token, o.text, o.referenceId);
      if (_disposed) return;
      // The poll advances _newestId; doing it here could skip a message
      // someone else sent just before this one.
      _addVisible(sent);
      _outgoing.remove(o);
    } catch (e) {
      log('chat: send failed: $e');
      if (_disposed) return;
      o
        ..state = SendState.failed
        ..error = _statusOf(e) == 413 ? 'Message too long' : 'Not sent';
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
