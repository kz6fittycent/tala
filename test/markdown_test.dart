import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart';
import 'package:tala/src/markdown.dart';

List<MdBlock> blocks(String raw, [Map<String, dynamic> params = const {}]) =>
    parseMarkdown(raw, params)!;

/// Each run as text with its style, like `b:bold` or `plain:rest`.
List<String> runs(String raw, [Map<String, dynamic> params = const {}]) => [
  for (final s in blocks(raw, params).expand((b) => b.segments))
    '${[if (s.style.bold) 'b', if (s.style.italic) 'i', if (s.style.strike) 's', if (s.style.code) 'c', if (s.kind == SegmentKind.link) 'link', if (s.kind == SegmentKind.mention) 'mention'].join('+')}:${s.text}',
];

const mention = {
  'mention-user1': {'type': 'user', 'id': 'maya', 'name': 'Maya Chen'},
};

void main() {
  group('inline', () {
    test('the common forms', () {
      expect(runs('**a** b'), ['b:a', ': b']);
      expect(runs('__a__'), ['b:a']);
      expect(runs('*a*'), ['i:a']);
      expect(runs('_a_'), ['i:a']);
      expect(runs('~~a~~'), ['s:a']);
      expect(runs('`a`'), ['c:a']);
      expect(runs('***a***'), ['b+i:a']);
    });

    test('nesting', () {
      expect(runs('**a *b* c**'), ['b:a ', 'b+i:b', 'b: c']);
    });

    test('things that only look like formatting stay as typed', () {
      for (final plain in [
        'snake_case_name',
        '2 * 3 * 4',
        '* not closed',
        'a ** b',
        '**not closed',
        '~~not closed',
        '`not closed',
        '__init__py_',
        'a_b *',
      ]) {
        final text = parseMarkdown(plain, const {}) == null
            ? plain
            : flattenMarkdown(blocks(plain)).map((s) => s.text).join();
        expect(text.replaceFirst('• ', '* '), plain, reason: plain);
      }
    });

    test('a backslash keeps a character literal', () {
      expect(runs(r'\*not italic\*'), [':*not italic*']);
    });

    test('formatting characters inside code are left alone', () {
      expect(runs('`**a** _b_`'), ['c:**a** _b_']);
    });

    test('a bare address keeps its underscores and asterisks', () {
      expect(runs('see https://x.example/a_b_c/d*e*f now'), [
        ':see ',
        'link:https://x.example/a_b_c/d*e*f',
        ': now',
      ]);
    });

    test('bold around a bare address closes outside it', () {
      expect(runs('**https://x.example/a**'), ['b+link:https://x.example/a']);
    });

    test('a mention keeps working inside formatting', () {
      expect(runs('**hi {mention-user1}**', mention), [
        'b:hi ',
        'b+mention:Maya Chen',
      ]);
    });

    test('a placeholder with underscores isn\'t emphasis', () {
      expect(runs('{a_b} and {c_d}', {
        'a_b': {'type': 'user', 'name': 'A'},
        'c_d': {'type': 'user', 'name': 'C'},
      }), ['mention:A', ': and ', 'mention:C']);
    });
  });

  group('links', () {
    test('http and https links show their label and open their address', () {
      final s = blocks('[the map](https://x.example/m)').single.segments.single;
      expect(s.kind, SegmentKind.link);
      expect(s.text, 'the map');
      expect(s.url, 'https://x.example/m');
    });

    test('nothing else can be opened', () {
      for (final bad in [
        '[click](javascript:alert(1))',
        '[click](file:///etc/passwd)',
        '[click](data:text/html,x)',
        '[click](ftp://x.example)',
        '[click](/relative)',
      ]) {
        final all = flattenMarkdown(blocks(bad));
        expect(all.where((s) => s.url != null), isEmpty, reason: bad);
        expect(all.map((s) => s.text).join(), bad, reason: bad);
      }
    });

    test('a label loses its formatting characters', () {
      expect(blocks('[**a**](https://x.example)').single.segments.single.text, 'a');
    });
  });

  group('blocks', () {
    test('headings, with their level', () {
      final b = blocks('# One\n### Three ###');
      expect(b.map((x) => x.kind), [MdKind.heading, MdKind.heading]);
      expect(b.map((x) => x.level), [1, 3]);
      expect(b.last.segments.single.text, 'Three');
    });

    test('a hashtag isn\'t a heading', () {
      expect(blocks('#notheading [x').single.kind, MdKind.paragraph);
    });

    test('lists keep their markers and indent', () {
      final b = blocks('- a\n* b\n  - c\n3. d\n4) e');
      expect(b.map((x) => x.marker), ['•', '•', '•', '3.', '4.']);
      expect(b.map((x) => x.level), [0, 0, 1, 0, 0]);
    });

    test('task lists', () {
      final b = blocks('- [ ] todo\n- [x] done');
      expect(b.map((x) => x.marker), ['☐', '☑']);
      expect(b.first.segments.single.text, 'todo');
    });

    test('consecutive quote lines are one quote', () {
      final b = blocks('> a\n> b\n\nc');
      expect(b.first.kind, MdKind.quote);
      expect(b.first.segments.single.text, 'a\nb');
      expect(b.last.kind, MdKind.paragraph);
    });

    test('a fence holds text exactly, closed or not', () {
      final closed = blocks('```dart\n**a**\n  b\n```\nafter');
      expect(closed.first.kind, MdKind.code);
      expect(closed.first.segments.single.text, '**a**\n  b');
      expect(closed.last.segments.single.text, 'after');
      expect(blocks('```\nno end').single.segments.single.text, 'no end');
    });

    test('rules', () {
      expect(blocks('---').single.kind, MdKind.rule);
      expect(blocks('***').single.kind, MdKind.rule);
    });

    test('lines in a paragraph stay separate', () {
      expect(blocks('*a*\nb').single.kind, MdKind.paragraph);
      expect(blocks('*a*\nb').single.segments.last.text, '\nb');
    });

    test('a table stays as typed', () {
      expect(parseMarkdown('| a | b |\n|---|---|', const {}), isNull);
      expect(blocks('| **a** | b |\n|---|---|').single.kind, MdKind.paragraph);
    });
  });

  group('the message', () {
    ChatMessage message(String raw, {bool? markdown}) => ChatMessage.fromJson({
      'id': 1,
      'message': raw,
      'markdown': ?markdown,
      'messageParameters': mention,
    });

    test('formats only when the server says to', () {
      expect(message('**a**', markdown: true).blocks, isNotNull);
      expect(message('**a**', markdown: false).blocks, isNull);
      expect(message('**a**').blocks, isNull, reason: 'an older server');
      expect(message('**a**').text, '**a**');
    });

    test('plain chat skips the parser', () {
      expect(message('hello there', markdown: true).blocks, isNull);
    });

    test('previews and copying get clean text, editing gets the source', () {
      final m = message('**hi** {mention-user1}\n- item', markdown: true);
      expect(m.text, 'hi Maya Chen\n• item');
      expect(m.editSource, '**hi** @"maya"\n- item');
    });

    test('an image preview survives formatting', () {
      final m = ChatMessage.fromJson({
        'id': 1,
        'message': '**look** {file}',
        'markdown': true,
        'messageParameters': {
          'file': {
            'type': 'file',
            'id': '7',
            'name': 'a.png',
            'mimetype': 'image/png',
            'preview-available': 'yes',
          },
        },
      });
      expect(m.segments.last.previewFileId, 7);
    });

    test('reacting keeps the layout', () {
      final m = message('**a**', markdown: true).withOwnReaction('👍', add: true);
      expect(m.blocks, isNotNull);
    });
  });

  test('messages built to be slow aren\'t', () {
    final watch = Stopwatch()..start();
    for (final raw in [
      '*a ' * 11000,
      '_a ' * 11000,
      '**a ' * 8000,
      '`a ' * 11000,
      '[a](' * 8000,
      '*' * 32000,
      '~' * 32000,
      '**' * 16000,
      '> ' * 16000,
      '- ' * 16000,
      '*a' * 16000,
      '**a*' * 8000,
      '\\*' * 16000,
      '${'*a' * 2000}${'a*' * 2000}',
    ]) {
      parseMarkdown(raw, const {});
    }
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
