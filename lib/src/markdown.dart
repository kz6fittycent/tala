import 'chat.dart';

/// Inline formatting on a run of text.
class MdStyle {
  const MdStyle({
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.code = false,
  });
  final bool bold;
  final bool italic;
  final bool strike;
  final bool code;

  bool get isPlain => !bold && !italic && !strike && !code;

  MdStyle plus(MdStyle o) => MdStyle(
    bold: bold || o.bold,
    italic: italic || o.italic,
    strike: strike || o.strike,
    code: code || o.code,
  );
}

enum MdKind { paragraph, heading, quote, listItem, code, rule }

/// One block of a formatted message.
class MdBlock {
  const MdBlock(
    this.kind,
    this.segments, {
    this.level = 0,
    this.marker = '',
  });
  final MdKind kind;
  final List<Segment> segments;

  /// A heading's level from 1, or a list item's indent from 0.
  final int level;

  /// A list item's bullet, number or checkbox.
  final String marker;
}

/// Anything that could be formatting. Most chat has none, and skips the parser.
final _mayBeFormatted = RegExp(
  r'[*_~`\[\\]|^\s*(#{1,6}\s|>|[-+]\s|\d+[.)]\s|[-_*]{3,}\s*$)',
  multiLine: true,
);

/// Null if [raw] has nothing to format. Covers what chat commonly uses: bold,
/// italic, strikethrough, code, links, headings, quotes, lists, task lists and
/// rules. Tables stay as typed text, which still reads as a table.
List<MdBlock>? parseMarkdown(String raw, Map<String, dynamic> params) {
  if (!_mayBeFormatted.hasMatch(raw)) return null;
  return _Parser(params).blocks(raw);
}

/// The blocks as one run of text, for previews, quotes and copying.
List<Segment> flattenMarkdown(List<MdBlock> blocks) {
  final out = <Segment>[];
  for (final b in blocks) {
    if (b.kind == MdKind.rule) continue;
    if (out.isNotEmpty) out.add(const Segment('\n', SegmentKind.text));
    if (b.kind == MdKind.listItem) {
      out.add(Segment('${b.marker} ', SegmentKind.text));
    }
    out.addAll(b.segments);
  }
  return out;
}

final _fence = RegExp(r'^ {0,3}(```+|~~~+)');
final _heading = RegExp(r'^ {0,3}(#{1,6})\s+(.*?)(\s+#+)?\s*$');
final _rule = RegExp(r'^ {0,3}([-_*])(\s*\1){2,}\s*$');
final _quote = RegExp(r'^ {0,3}>\s?(.*)$');
final _bullet = RegExp(r'^(\s*)[-+*]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d{1,9})[.)]\s+(.*)$');
final _task = RegExp(r'^\[([ xX])\]\s+(.*)$');

final _placeholder = RegExp(r'\{[A-Za-z0-9_\-]+\}');
final _bareUrl = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);
final _inlineLink = RegExp(r'\[([^\]\n]+)\]\(([^()\s]+)\)');
final _word = RegExp(r'[\p{L}\p{N}]', unicode: true);

const _escapable = r'\`*_{}[]()#+-.!~>|';

/// Longest first, so `***` isn't read as `**` and `*`.
const _delimiters = <(String, MdStyle)>[
  ('***', MdStyle(bold: true, italic: true)),
  ('**', MdStyle(bold: true)),
  ('__', MdStyle(bold: true)),
  ('~~', MdStyle(strike: true)),
  ('*', MdStyle(italic: true)),
  ('_', MdStyle(italic: true)),
];

class _Parser {
  _Parser(this.params);
  final Map<String, dynamic> params;

  static const _maxDepth = 8;

  List<MdBlock> blocks(String raw) {
    final lines = raw.split('\n');
    final out = <MdBlock>[];
    final paragraph = <String>[];
    void endParagraph() {
      if (paragraph.isEmpty) return;
      out.add(MdBlock(MdKind.paragraph, _inline(paragraph.join('\n'))));
      paragraph.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fence = _fence.firstMatch(line);
      if (fence != null) {
        endParagraph();
        final marker = fence.group(1)!;
        final code = <String>[];
        // An unclosed fence runs to the end of the message.
        for (i++; i < lines.length; i++) {
          if (lines[i].trim().startsWith(marker) &&
              lines[i].trim().replaceAll(marker[0], '').isEmpty) {
            break;
          }
          code.add(lines[i]);
        }
        out.add(MdBlock(MdKind.code, _literal(code.join('\n'))));
        continue;
      }
      if (line.trim().isEmpty) {
        endParagraph();
        continue;
      }
      if (_rule.hasMatch(line)) {
        endParagraph();
        out.add(const MdBlock(MdKind.rule, []));
        continue;
      }
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        endParagraph();
        out.add(
          MdBlock(
            MdKind.heading,
            _inline(heading.group(2)!),
            level: heading.group(1)!.length,
          ),
        );
        continue;
      }
      if (_quote.hasMatch(line)) {
        endParagraph();
        final quoted = <String>[];
        for (; i < lines.length; i++) {
          final m = _quote.firstMatch(lines[i]);
          if (m == null) break;
          quoted.add(m.group(1)!);
        }
        i--;
        out.add(MdBlock(MdKind.quote, _inline(quoted.join('\n'))));
        continue;
      }
      final bullet = _bullet.firstMatch(line);
      if (bullet != null) {
        endParagraph();
        final task = _task.firstMatch(bullet.group(2)!);
        out.add(
          MdBlock(
            MdKind.listItem,
            _inline(task?.group(2) ?? bullet.group(2)!),
            level: _indent(bullet.group(1)!),
            marker: task == null
                ? '•'
                : task.group(1) == ' '
                ? '☐'
                : '☑',
          ),
        );
        continue;
      }
      final numbered = _numbered.firstMatch(line);
      if (numbered != null) {
        endParagraph();
        out.add(
          MdBlock(
            MdKind.listItem,
            _inline(numbered.group(3)!),
            level: _indent(numbered.group(1)!),
            marker: '${numbered.group(2)}.',
          ),
        );
        continue;
      }
      paragraph.add(line);
    }
    endParagraph();
    return out;
  }

  int _indent(String space) => (space.length ~/ 2).clamp(0, 6);

  /// Mentions and files by name, with nothing else interpreted.
  List<Segment> _literal(String text) => [
    for (final s in parseMessage(text, params))
      s.kind == SegmentKind.link
          ? Segment.styled(
              s.text,
              SegmentKind.text,
              null,
              null,
              const MdStyle(code: true),
            )
          : s.withStyle(const MdStyle(code: true)),
  ];

  bool _isSpace(String s, int i) => s[i].trim().isEmpty;
  bool _isWord(String s, int i) =>
      i >= 0 && i < s.length && _word.hasMatch(s[i]);

  /// Where [d] closes after [from], or -1.
  int _closer(String s, String d, int from) {
    final single = d == '*' || d == '_';
    for (var j = s.indexOf(d, from); j != -1; j = s.indexOf(d, j + 1)) {
      if (j == from || _isSpace(s, j - 1) || s[j - 1] == r'\') continue;
      final after = j + d.length;
      // A lone * shouldn't close on half of a **.
      if (single &&
          ((after < s.length && s[after] == d) || s[j - 1] == d)) {
        continue;
      }
      if (d[0] == '_' && _isWord(s, after)) continue;
      return j;
    }
    return -1;
  }

  List<Segment> _inline(
    String s, [
    MdStyle style = const MdStyle(),
    int depth = 0,
  ]) {
    final out = <Segment>[];
    final text = StringBuffer();
    void flush() {
      if (text.isEmpty) return;
      for (final seg in parseMessage(text.toString(), params)) {
        out.add(seg.withStyle(style));
      }
      text.clear();
    }

    // A delimiter with no closer from here has none from anywhere later, which
    // keeps a long message full of them from taking quadratic time.
    final unclosed = <String>{};
    var i = 0;
    outer:
    while (i < s.length) {
      final c = s[i];
      if (c == r'\' && i + 1 < s.length && _escapable.contains(s[i + 1])) {
        text.write(s[i + 1]);
        i += 2;
        continue;
      }
      if (c == '{') {
        final m = _placeholder.matchAsPrefix(s, i);
        if (m != null) {
          text.write(m.group(0));
          i = m.end;
          continue;
        }
      }
      if ((c == 'h' || c == 'H') && !_isWord(s, i - 1)) {
        final m = _bareUrl.matchAsPrefix(s, i);
        if (m != null) {
          // Formatting right after a link closes around it, not inside it.
          final url = m.group(0)!.replaceFirst(RegExp(r'[*_~`]+$'), '');
          text.write(url);
          i += url.length;
          continue;
        }
      }
      if (c == '`') {
        var run = 1;
        while (i + run < s.length && s[i + run] == '`') {
          run++;
        }
        final tick = '`' * run;
        final end = s.indexOf(tick, i + run);
        if (end > i + run) {
          flush();
          out.addAll(
            _literal(s.substring(i + run, end)).map(
              (seg) => seg.withStyle(style),
            ),
          );
          i = end + run;
        } else {
          text.write(tick);
          i += run;
        }
        continue;
      }
      if (c == '[') {
        final m = _inlineLink.matchAsPrefix(s, i);
        final url = m == null ? null : safeUrl(m.group(2));
        if (m != null && url != null) {
          flush();
          final label = depth < _maxDepth
              ? _inline(m.group(1)!, style, depth + 1).map((x) => x.text).join()
              : m.group(1)!;
          out.add(Segment.styled(label, SegmentKind.link, url, null, style));
          i = m.end;
          continue;
        }
      }
      if (depth < _maxDepth) {
        for (final (d, added) in _delimiters) {
          if (!s.startsWith(d, i)) continue;
          final inner = i + d.length;
          final opens =
              inner < s.length &&
              !_isSpace(s, inner) &&
              !(d[0] == '_' && _isWord(s, i - 1));
          if (opens && !unclosed.contains(d)) {
            final end = _closer(s, d, inner);
            if (end == -1) {
              unclosed.add(d);
            } else {
              flush();
              out.addAll(
                _inline(s.substring(inner, end), style.plus(added), depth + 1),
              );
              i = end + d.length;
              continue outer;
            }
          }
          text.write(d);
          i = inner;
          continue outer;
        }
      }
      text.write(c);
      i++;
    }
    flush();
    return out;
  }
}
