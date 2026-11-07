import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/mentions.dart';

MentionQuery? at(String text, [int? cursor]) => mentionQueryAt(
  text,
  TextSelection.collapsed(offset: cursor ?? text.length),
);

void main() {
  group('finding the mention being typed', () {
    test('at the start, or after a space or new line', () {
      expect(at('@')?.text, '');
      expect(at('@ma')?.text, 'ma');
      expect(at('@ma')?.start, 0);
      expect(at('hi @ma')?.start, 3);
      expect(at('hi\n@ma')?.text, 'ma');
    });

    test('only up to the cursor', () {
      expect(at('@maya', 3)?.text, 'ma');
      expect(at('@a b', 4), isNull);
    });

    test('not in an email address, after a space, or a raw mention', () {
      expect(at('pat@example.com'), isNull);
      expect(at('@maya chen'), isNull);
      expect(at('hello'), isNull);
      expect(at('@"maya'), isNull);
      expect(at(''), isNull);
    });

    test('not with text selected', () {
      expect(
        mentionQueryAt(
          '@maya',
          const TextSelection(baseOffset: 1, extentOffset: 3),
        ),
        isNull,
      );
      expect(mentionQueryAt('@maya', const TextSelection.collapsed(offset: -1)),
          isNull);
    });
  });

  test('inserting replaces the query and keeps the text around it', () {
    const value = TextEditingValue(
      text: 'hi @ma, bye',
      selection: TextSelection.collapsed(offset: 6),
    );
    final out = insertMention(value, const MentionQuery(3, 'ma'), '@Maya Chen');
    expect(out.text, 'hi @Maya Chen , bye');
    expect(out.selection.baseOffset, 14);
  });

  group('turning picked names into ids', () {
    const maya = MentionOption(id: 'maya', label: 'Maya Chen');

    PickedMentions picked(List<MentionOption> options) {
      final p = PickedMentions();
      options.forEach(p.pick);
      return p;
    }

    test('nothing picked leaves text alone', () {
      expect(PickedMentions().expand('@Maya Chen'), '@Maya Chen');
    });

    test('a picked name becomes the id, however often, with punctuation', () {
      expect(
        picked([maya]).expand('@Maya Chen, hi. (@Maya Chen)\n@Maya Chen!'),
        '@"maya", hi. (@Maya Chen)\n@"maya"!',
      );
    });

    test('a name must stand alone', () {
      const sam = MentionOption(id: 'sam', label: 'Sam');
      final p = picked([sam]);
      expect(p.expand('@Samantha'), '@Samantha');
      expect(p.expand('me@Sam'), 'me@Sam');
      expect(p.expand('Sam'), 'Sam');
      expect(p.expand('@Sam-Lee'), '@Sam-Lee');
      expect(p.expand('@Sam'), '@"sam"');
    });

    test('the longest name wins', () {
      final p = picked([
        const MentionOption(id: 'a', label: 'Sam'),
        const MentionOption(id: 'b', label: 'Sam Lee'),
      ]);
      expect(p.expand('@Sam Lee and @Sam'), '@"b" and @"a"');
    });

    test('names with regex characters are taken literally', () {
      const odd = MentionOption(id: 'x', label: 'A.B (C)');
      expect(picked([odd]).expand('@A.B (C)'), '@"x"');
      expect(picked([odd]).expand('@AxB (C)'), '@AxB (C)');
    });

    test('the second of two people with one name goes in by id', () {
      final p = PickedMentions();
      expect(p.pick(const MentionOption(id: 'a', label: 'Sam')), '@Sam');
      expect(p.pick(const MentionOption(id: 'b', label: 'Sam')), '@"b"');
      expect(p.pick(const MentionOption(id: 'a', label: 'Sam')), '@Sam');
      expect(p.expand('@Sam @"b"'), '@"a" @"b"');
    });

    test('federated ids are sent, not the local one', () {
      const remote = MentionOption(
        id: 'local',
        label: 'Remote',
        mentionId: 'federated_user/x@y',
      );
      expect(picked([remote]).expand('@Remote'), '@"federated_user/x@y"');
    });
  });
}
