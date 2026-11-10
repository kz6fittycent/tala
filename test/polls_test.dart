import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart';
import 'package:tala/src/polls.dart';

Map<String, dynamic> pollJson({
  int status = 0,
  int resultMode = 0,
  int maxVotes = 1,
  List<int> votedSelf = const [],
  Map<String, int> votes = const {},
  String actorId = 'bob',
}) => {
  'id': 7,
  'question': 'Where to?',
  'options': ['Lake', 'Hills'],
  'votes': votes,
  'numVoters': votes.values.fold(0, (a, b) => a + b),
  'votedSelf': votedSelf,
  'status': status,
  'resultMode': resultMode,
  'maxVotes': maxVotes,
  'actorType': 'users',
  'actorId': actorId,
  'actorDisplayName': 'Bob',
};

void main() {
  test('a poll is read from the server\'s fields', () {
    final p = Poll.fromJson(
      pollJson(votes: {'option-1': 3}, votedSelf: [1], status: 1),
    );
    expect(p.options, ['Lake', 'Hills']);
    expect(p.votes, {1: 3});
    expect(p.voted, isTrue);
    expect(p.closed, isTrue);
    expect(p.showsResults, isTrue);
  });

  test('hidden results stay hidden until the poll closes', () {
    expect(
      Poll.fromJson(pollJson(resultMode: 1, votedSelf: [0])).showsResults,
      isFalse,
    );
    expect(
      Poll.fromJson(pollJson(resultMode: 1, status: 1)).showsResults,
      isTrue,
    );
  });

  test('a poll message knows its poll and can\'t be edited', () {
    final m = ChatMessage.fromJson({
      'id': 1,
      'message': '{object}',
      'messageParameters': {
        'object': {'type': 'talk-poll', 'id': '7', 'name': 'Where to?'},
      },
    });
    expect(m.pollId, 7);
    expect(m.text, 'Where to?');
    expect(m.canEdit, isFalse);
  });

  Future<void> show(WidgetTester tester, Widget dialog) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(context: context, builder: (_) => dialog),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  PollSource source({
    required Map<String, dynamic> Function() current,
    List<String>? calls,
  }) => PollSource(
    load: (_, _) async => Poll.fromJson(current()),
    vote: (_, id, options) async {
      calls?.add('vote $id $options');
      return Poll.fromJson(pollJson(
        votedSelf: options,
        votes: {for (final o in options) 'option-$o': 1},
      ));
    },
    close: (_, id) async {
      calls?.add('close $id');
      return Poll.fromJson(pollJson(status: 1));
    },
    create: (_, _, _, {required hidden, required multiple}) async {},
  );

  testWidgets('voting picks one answer, then shows results', (tester) async {
    final calls = <String>[];
    await show(
      tester,
      PollDialog(
        source: source(current: pollJson, calls: calls),
        token: 't',
        pollId: 7,
        selfId: 'me',
        isModerator: false,
        canVote: true,
      ),
    );
    expect(find.text('Where to?'), findsOneWidget);
    expect(find.text('End poll'), findsNothing);
    await tester.tap(find.text('Hills'));
    await tester.pump();
    await tester.tap(find.text('Vote'));
    await tester.pumpAndSettle();
    expect(calls, ['vote 7 [1]']);
    expect(find.bySemanticsLabel('Your vote'), findsOneWidget);
    expect(find.text('Change vote'), findsOneWidget);
  });

  testWidgets('the person who asked can end it', (tester) async {
    final calls = <String>[];
    await show(
      tester,
      PollDialog(
        source: source(
          current: () => pollJson(actorId: 'me'),
          calls: calls,
        ),
        token: 't',
        pollId: 7,
        selfId: 'me',
        isModerator: false,
        canVote: true,
      ),
    );
    await tester.tap(find.text('End poll'));
    await tester.pumpAndSettle();
    expect(calls, ['close 7']);
    expect(find.textContaining('Closed'), findsOneWidget);
  });

  testWidgets('a new poll needs a question and two answers', (tester) async {
    final posted = <String>[];
    await show(
      tester,
      CreatePollDialog(
        create: (q, options, {required hidden, required multiple}) async =>
            posted.add('$q $options $hidden $multiple'),
      ),
    );
    FilledButton post() => tester.widget(find.byType(FilledButton));
    await tester.enterText(find.widgetWithText(TextField, 'Question'), 'Lunch?');
    await tester.enterText(find.widgetWithText(TextField, 'Answer 1'), 'Soup');
    await tester.pump();
    expect(post().onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Answer 2'), 'Salad');
    await tester.tap(find.text('Allow more than one answer'));
    await tester.pump();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();
    expect(posted, ['Lunch? [Soup, Salad] false true']);
  });
}
