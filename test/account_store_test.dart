import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/account_store.dart';
import 'package:tala/src/nc_api.dart';

class FakeSecrets implements SecretStore {
  final Map<String, String> items = {};
  KeyringException? failReads;
  KeyringException? failWrites;

  /// Simulates a keyring that accepts a write but returns something else.
  bool corruptReads = false;

  @override
  Future<String?> read(String item) async {
    if (failReads != null) throw failReads!;
    return corruptReads ? 'other' : items[item];
  }

  @override
  Future<void> write(String item, String label, String secret) async {
    if (failWrites != null) throw failWrites!;
    items[item] = secret;
  }

  @override
  Future<void> delete(String item) async => items.remove(item);
}

void main() {
  late File legacy;
  late FakeSecrets secrets;
  late AccountStore store;
  final down = KeyringException(locked: false, message: 'no service');
  final locked = KeyringException(locked: true, message: 'locked');
  final oldFile = jsonEncode(
    {'server': 'https://old', 'user': 'me', 'appPassword': 'pw'},
  );

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('tala');
    addTearDown(() => dir.deleteSync(recursive: true));
    legacy = File('${dir.path}/credentials.json');
    secrets = FakeSecrets();
    store = AccountStore(secrets: secrets, legacyFile: legacy);
  });

  test('nothing saved anywhere means not signed in', () async {
    expect(await store.load(), isNull);
  });

  test('a saved account comes back', () async {
    await store.save(Credentials('https://s', 'u', 'p'));
    final creds = await store.load();
    expect(creds?.server, 'https://s');
    expect(creds?.user, 'u');
    expect(creds?.appPassword, 'p');
  });

  test('the old file moves to the keyring and is removed', () async {
    legacy.writeAsStringSync(oldFile);
    final creds = await store.load();
    expect(creds?.appPassword, 'pw');
    expect(secrets.items['account'], contains('"appPassword":"pw"'));
    expect(legacy.existsSync(), isFalse);
  });

  test('a failed write keeps the old file and still signs in', () async {
    legacy.writeAsStringSync(oldFile);
    secrets.failWrites = down;
    expect((await store.load())?.appPassword, 'pw');
    expect(legacy.existsSync(), isTrue);
  });

  test('a read-back mismatch keeps the old file', () async {
    legacy.writeAsStringSync(oldFile);
    secrets.items['account'] = 'not json';
    final store2 = AccountStore(secrets: secrets, legacyFile: legacy);
    secrets.corruptReads = true;
    expect((await store2.load())?.appPassword, 'pw');
    expect(legacy.existsSync(), isTrue);
  });

  test('an unavailable keyring falls back to the old file, untouched',
      () async {
    legacy.writeAsStringSync(oldFile);
    secrets.failReads = down;
    expect((await store.load())?.appPassword, 'pw');
    expect(legacy.existsSync(), isTrue);
  });

  test('a keyring problem with no old file is reported, not "signed out"',
      () async {
    secrets.failReads = locked;
    await expectLater(
      store.load(),
      throwsA(isA<KeyringException>().having((e) => e.locked, 'locked', true)),
    );
  });

  test('the keyring wins and a leftover old file is removed', () async {
    await store.save(Credentials('https://new', 'u', 'newer'));
    legacy.writeAsStringSync(oldFile);
    expect((await store.load())?.appPassword, 'newer');
    expect(legacy.existsSync(), isFalse);
  });

  test('a damaged keyring entry falls through to the old file', () async {
    secrets.items['account'] = 'not json';
    legacy.writeAsStringSync(oldFile);
    expect((await store.load())?.appPassword, 'pw');
    expect(legacy.existsSync(), isFalse);
  });

  test('a damaged old file is left alone and means not signed in', () async {
    legacy.writeAsStringSync('not json');
    expect(await store.load(), isNull);
    expect(legacy.existsSync(), isTrue);
  });
}
