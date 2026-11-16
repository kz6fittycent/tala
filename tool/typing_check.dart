// Runs Tala's typing sessions against a real Talk server without an HPB. For a
// throwaway server only: it creates and deletes a conversation, as alice, with
// bob as an existing user. Never point it at a real account.
//
//   TALA_TYPING_CHECK_URL=http://127.0.0.1:8089 \
//   TALA_TYPING_CHECK_PASSWORD_FOR_ALICE=... TALA_TYPING_CHECK_PASSWORD_FOR_BOB=... \
//   flutter test tool/typing_check.dart
//
// It isn't under test/, so the normal suite skips it, and it refuses anything
// but http://127.0.0.1.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/nc_api.dart';
import 'package:tala/src/typing.dart';

void main() {
  final env = Platform.environment;
  final url = env['TALA_TYPING_CHECK_URL'] ?? '';
  final skip = url.startsWith('http://127.0.0.1')
      ? null
      : 'set TALA_TYPING_CHECK_URL to a local throwaway server';

  NcApi as(String user) => NcApi(Credentials(
      url, user, env['TALA_TYPING_CHECK_PASSWORD_FOR_${user.toUpperCase()}'] ?? ''));

  /// Real timers, not the test's fake ones, so polls and joins happen.
  Future<void> until(bool Function() done, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 40));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  test('two people see each other type, and a call\'s session survives',
      () async {
    final alice = as('alice');
    final bob = as('bob');
    expect(await alice.typingAllowed(), isTrue);

    final token = await alice.createGroup('Typing check');
    try {
      await alice.addMember(token, Person('bob', 'Bob', ''));
      Future<Room> roomOf(NcApi api) async =>
          (await api.rooms()).firstWhere((r) => r.token == token);

      // A call-style session on alice's main cookies first.
      await alice.joinRoom(token);

      final a = TypingSession(alice, await roomOf(alice))..active = true;
      final b = TypingSession(bob, await roomOf(bob))..active = true;
      await until(() => a.connected && b.connected, 'both to connect');

      // Each needs the other in its usersInRoom before sending reaches them;
      // keep saying so until bob's side shows it.
      final names = <String>[];
      void onB() => names
        ..clear()
        ..addAll(b.names);
      b.addListener(onB);
      final end = DateTime.now().add(const Duration(seconds: 40));
      while (b.names.isEmpty && DateTime.now().isBefore(end)) {
        a.typing(false);
        a.typing(true);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(b.names, ['alice'], reason: 'bob sees alice typing, by name');

      a.typing(false);
      await until(() => b.names.isEmpty, 'alice to stop');

      // Alice leaving typing ends only that session: the call-style one on
      // her main cookies still pulls.
      a.active = false;
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(a.connected, isFalse);
      final client = HttpClient();
      final pulled = await alice.pullSignaling(token, client);
      client.close(force: true);
      expect(pulled, isA<List>());

      final members = await bob.members(token);
      final aliceMember = members.firstWhere((m) => m.actorId == 'alice');
      expect(aliceMember.sessionIds, hasLength(1),
          reason: 'the typing session left, the main one stayed');

      b.dispose();
      a.dispose();
      await alice.leaveRoom(token);
    } finally {
      await alice.deleteConversation(token);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
