import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/drafts.dart';
import 'package:tala/src/mentions.dart';

void main() {
  late File file;
  setUp(() {
    file = File('${Directory.systemTemp.createTempSync('tala-drafts').path}/d.json');
  });

  DraftStore open({String account = 'me@https://a'}) =>
      DraftStore(account: account, file: file, saveDelay: Duration.zero);

  test('text and picked mentions survive a restart', () {
    final first = open();
    first.picked('t').pick(const MentionOption(id: 'maya', label: 'Maya Chen'));
    first['t'] = 'hi @Maya Chen';
    final again = open();
    expect(again['t'], 'hi @Maya Chen');
    expect(again.picked('t').expand(again['t']!), 'hi @"maya"');
  });

  test('only the user can read the file', () {
    open()['t'] = 'secret plans';
    final mode = file.statSync().mode & 0x1ff;
    expect(mode, 0x180); // 0600
  });

  test('clearing a draft removes it', () {
    final first = open();
    first['t'] = 'hello';
    first['t'] = '';
    expect(open()['t'], isNull);
    first['u'] = 'x';
    first.remove('u');
    expect(open()['u'], isNull);
  });

  test('another account starts empty', () {
    open()['t'] = 'hello';
    expect(open(account: 'me@https://b')['t'], isNull);
  });

  test('a damaged file is ignored', () {
    file.writeAsStringSync('{not json');
    expect(open()['t'], isNull);
    file.writeAsStringSync('{"account":"me@https://a","drafts":{"t":5}}');
    expect(open()['t'], isNull);
  });

  test('a delay batches saves until it passes', () async {
    final store = DraftStore(
      account: 'a',
      file: file,
      saveDelay: const Duration(milliseconds: 20),
    );
    store['t'] = 'one';
    expect(file.existsSync(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(file.readAsStringSync(), contains('one'));
  });
}
