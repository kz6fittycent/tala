import 'package:flutter/services.dart' show TextEditingValue, TextSelection;

/// Someone, or everyone, who can be mentioned in a conversation.
class MentionOption {
  const MentionOption({
    required this.id,
    required this.label,
    this.source = 'users',
    this.details = '',
    this.mentionId,
  });

  factory MentionOption.fromJson(Map<String, dynamic> j) => MentionOption(
    id: j['id'] as String? ?? '',
    label: j['label'] as String? ?? '',
    source: j['source'] as String? ?? 'users',
    details: j['details'] as String? ?? '',
    mentionId: j['mentionId'] as String?,
  );

  final String id;
  final String label;

  /// users, federated_users, group, guests, or calls for the whole conversation.
  final String source;

  /// The server's own description, such as how many people "all" reaches.
  final String details;
  final String? mentionId;

  /// What goes in a message. Older servers send only [id].
  String get wireId => mentionId ?? id;

  bool get isEveryone => source == 'calls';
  bool get isGroup => source == 'group' || source == 'groups';
}

/// A mention being typed: the `@` at [start], and the [text] after it so far.
class MentionQuery {
  const MentionQuery(this.start, this.text);
  final int start;
  final String text;
}

/// The mention being typed at the cursor, if any. An `@` only starts one at the
/// beginning of a word, so email addresses don't. Stops at a space, so someone
/// is found by their first word.
MentionQuery? mentionQueryAt(String text, TextSelection selection) {
  if (!selection.isValid || !selection.isCollapsed) return null;
  final cursor = selection.baseOffset;
  if (cursor > text.length) return null;
  for (var i = cursor - 1; i >= 0; i--) {
    final c = text[i];
    if (c == '@') {
      if (i > 0 && !_isSpace(text[i - 1])) return null;
      return MentionQuery(i, text.substring(i + 1, cursor));
    }
    if (_isSpace(c) || c == '"') return null;
  }
  return null;
}

bool _isSpace(String c) => c.trim().isEmpty;

/// The composer's text with the mention being typed replaced by [shown], and
/// the cursor after the space that follows it.
TextEditingValue insertMention(
  TextEditingValue value,
  MentionQuery query,
  String shown,
) {
  final before = value.text.substring(0, query.start);
  final after = value.text.substring(value.selection.baseOffset);
  final inserted = '$shown ';
  return TextEditingValue(
    text: '$before$inserted$after',
    selection: TextSelection.collapsed(
      offset: before.length + inserted.length,
    ),
  );
}

/// The ids behind the names picked in a composer. Two people can share a name,
/// so the second one picked goes in by id rather than being remembered here.
class PickedMentions {
  PickedMentions();

  /// From [toJson]; anything malformed is skipped.
  PickedMentions.fromJson(Map<dynamic, dynamic> j) {
    for (final MapEntry(:key, :value) in j.entries) {
      if (key is String && value is String) _idByLabel[key] = value;
    }
  }

  final Map<String, String> _idByLabel = {};

  Map<String, String> toJson() => {..._idByLabel};

  bool get isEmpty => _idByLabel.isEmpty;

  /// What to show in the composer for someone just picked.
  String pick(MentionOption option) {
    final known = _idByLabel[option.label];
    if (known != null && known != option.wireId) return '@"${option.wireId}"';
    _idByLabel[option.label] = option.wireId;
    return '@${option.label}';
  }

  void clear() => _idByLabel.clear();

  /// [text] as the server reads it: each picked `@Name` becomes `@"id"`. A name
  /// must stand as its own word, so picking Sam leaves "@Samantha" alone.
  String expand(String text) {
    if (_idByLabel.isEmpty) return text;
    final labels = _idByLabel.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final pattern = RegExp(
      '(?<!\\S)@(${labels.map(RegExp.escape).join('|')})(?![\\p{L}\\p{N}_-])',
      unicode: true,
    );
    return text.replaceAllMapped(
      pattern,
      (m) => '@"${_idByLabel[m.group(1)]}"',
    );
  }
}
