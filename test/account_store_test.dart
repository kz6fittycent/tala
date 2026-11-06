import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/account_store.dart';
import 'package:tala/src/nc_api.dart';

class FakeSecrets implements SecretStore {
  final Map<String, String> items = {};
  KeyringException? failure;

  @override
  Future<String?> read(String item) async {
    if (failure != null) throw failure!;
    return items[item];
  }

  @override
  Future<void> write(String item, String label, String secret) async {
    if (failure != null) throw failure!;
    items[item] = secret;
  }

  @override
  Future<void> delete(String item) async => items.remove(item);
}

void main() {
  late FakeSecrets secrets;
  late AccountStore store;

  setUp(() {
    secrets = FakeSecrets();
    store = AccountStore(secrets: secrets);
  });

  test('nothing saved means not signed in', () async {
    expect(await store.load(), isNull);
  });

  test('a saved account comes back', () async {
    await store.save(Credentials('https://s', 'u', 'p'));
    final creds = await store.load();
    expect(creds?.server, 'https://s');
    expect(creds?.user, 'u');
    expect(creds?.appPassword, 'p');
  });

  test('a keyring problem is reported, not "signed out"', () async {
    secrets.failure = KeyringException(locked: true, message: 'locked');
    await expectLater(
      store.load(),
      throwsA(isA<KeyringException>().having((e) => e.locked, 'locked', true)),
    );
  });

  test('a saving problem is reported', () async {
    secrets.failure = KeyringException(locked: false, message: 'no service');
    await expectLater(
      store.save(Credentials('https://s', 'u', 'p')),
      throwsA(isA<KeyringException>()),
    );
  });

  test('a damaged entry means not signed in', () async {
    secrets.items['account'] = 'not json';
    expect(await store.load(), isNull);
    secrets.items['account'] = '{"server": 1}';
    expect(await store.load(), isNull);
  });
}
