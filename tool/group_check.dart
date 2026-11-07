// Runs Tala's real group calls against a real Talk server. For a throwaway
// server only: it creates, changes and deletes conversations, and only ever as
// the account it's given. Never point it at a real account.
//
//   TALA_GROUP_CHECK_URL=http://127.0.0.1:8089 \
//   TALA_GROUP_CHECK_PASSWORD_FOR_ALICE=... TALA_GROUP_CHECK_PASSWORD_FOR_BOB=... \
//   flutter test tool/group_check.dart
//
// It isn't under test/, so the normal suite skips it. It logs in as alice, with
// bob and carol as existing users, and refuses an https address, which would
// suggest a real server.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart' show ApiException, SegmentKind;
import 'package:tala/src/mentions.dart';
import 'package:tala/src/nc_api.dart';

void main() {
  final env = Platform.environment;
  final url = env['TALA_GROUP_CHECK_URL'] ?? '';
  final skip = url.startsWith('http://127.0.0.1')
      ? null
      : 'set TALA_GROUP_CHECK_URL to a local throwaway server';

  NcApi as(String user, String key) =>
      NcApi(Credentials(url, user, env[key] ?? ''));

  test('a whole group, from creation to deletion', () async {
    final alice = as('alice', 'TALA_GROUP_CHECK_PASSWORD_FOR_ALICE');
    final bob = as('bob', 'TALA_GROUP_CHECK_PASSWORD_FOR_BOB');

    final found = await alice.searchPeople('bo');
    expect(found.map((p) => p.id), contains('bob'));

    final token = await alice.createGroup('Group check');
    Future<Room> roomOf(NcApi api) async =>
        (await api.rooms()).firstWhere((r) => r.token == token);

    var room = await roomOf(alice);
    expect(room.type, 2);
    expect(room.name, 'Group check');
    expect(room.hasMembers, isTrue);
    expect(room.canManage, isTrue, reason: 'the creator is its owner');

    await alice.addMember(token, 'bob');
    await alice.addMember(token, 'carol');
    await expectLater(
      alice.addMember(token, 'nobody-by-this-name'),
      throwsA(isA<ApiException>()),
    );

    Future<Member> find(String id) async =>
        (await alice.members(token)).firstWhere((m) => m.actorId == id);
    final members = await alice.members(token);
    expect(members.map((m) => m.actorId).toSet(), {'alice', 'bob', 'carol'});
    expect((await find('alice')).isOwner, isTrue);
    final bobId = (await find('bob')).attendeeId;
    final carolId = (await find('carol')).attendeeId;
    expect((await find('bob')).isModerator, isFalse);

    // A mention picked in the composer, as the server sees it.
    final options = await alice.chatMentions(token, 'bo');
    final bobOption = options.firstWhere((o) => o.id == 'bob');
    final everyone = (await alice.chatMentions(token, ''))
        .firstWhere((o) => o.isEveryone);
    expect(everyone.wireId, 'all');
    final picked = PickedMentions();
    final bobShown = picked.pick(bobOption);
    final allShown = picked.pick(everyone);
    final sent = await alice.chatSend(
      token,
      picked.expand('Hello $bobShown and $allShown, and @nobody'),
      'group-check-mention',
    );
    expect(
      sent.segments.where((s) => s.kind == SegmentKind.mention).length,
      2,
      reason: 'both picks reached the server as mentions',
    );
    expect(sent.text, contains('@nobody'));

    // Set up by hand on the container: bob has a chosen picture, alice doesn't.
    if (env['TALA_GROUP_CHECK_BOB_HAS_AVATAR'] == '1') {
      expect(await alice.userAvatar('bob'), isNotNull);
      expect(await alice.userAvatar('alice'), isNull);
      expect(await alice.userAvatar('nobody-by-this-name'), isNull);
      expect(await alice.roomAvatar(token), isNull, reason: 'a default SVG');
      final oneToOne = await alice.startOneToOne('bob');
      final room = (await alice.rooms()).firstWhere((r) => r.token == oneToOne);
      expect(room.otherUserId, 'bob');
      final image = alice.avatars.forRoom(room)!;
      await image.ready;
      expect(image.bytes, isNotNull);
    }

    // Bob sees it, but can't manage it.
    final bobRoom = await roomOf(bob);
    expect(bobRoom.canManage, isFalse);
    await expectLater(
      bob.removeMember(token, carolId),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)),
    );
    await expectLater(
      bob.renameConversation(token, 'Not allowed'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)),
    );

    await alice.setModerator(token, bobId, true);
    expect((await find('bob')).isModerator, isTrue);
    expect((await roomOf(bob)).canManage, isTrue);
    await alice.setModerator(token, bobId, false);
    expect((await find('bob')).isModerator, isFalse);
    expect((await roomOf(bob)).canManage, isFalse);

    await alice.renameConversation(token, 'Renamed check');
    room = await roomOf(alice);
    expect(room.name, 'Renamed check');

    await alice.removeMember(token, carolId);
    expect(
      (await alice.members(token)).map((m) => m.actorId).toSet(),
      {'alice', 'bob'},
    );

    await bob.leaveConversation(token);
    expect((await bob.rooms()).where((r) => r.token == token), isEmpty);

    // Alice is now alone, and the only moderator.
    room = await roomOf(alice);
    stdout.writeln('alone: canLeave ${room.canLeave}, '
        'offersDelete ${room.offersDelete}');
    await alice.deleteConversation(token);
    expect((await alice.rooms()).where((r) => r.token == token), isEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('a public conversation lists a guest-style member correctly', () async {
    final alice = as('alice', 'TALA_GROUP_CHECK_PASSWORD_FOR_ALICE');
    final token = await alice.createGuestConversation('Link check', '');
    await alice.inviteByEmail(token, 'someone@example.invalid');
    final members = await alice.members(token);
    final guest = members.firstWhere((m) => m.actorType == 'emails');
    stdout.writeln('email member: type ${guest.participantType}, '
        'role "${guest.role}", shown as a guest ${guest.isGuest}');
    expect(guest.isGuest, isTrue);
    expect(guest.canBeModerator, isTrue);
    await alice.setModerator(token, guest.attendeeId, true);
    expect(
      (await alice.members(token))
          .firstWhere((m) => m.attendeeId == guest.attendeeId)
          .isModerator,
      isTrue,
    );
    await alice.removeMember(token, guest.attendeeId);
    await alice.deleteConversation(token);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
