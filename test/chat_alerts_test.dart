import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat_alerts.dart';
import 'package:tala/src/desktop_notify.dart';

void main() {
  late List<String> shown, hidden;
  late List<int> dismissed;
  late String? viewing;
  late ChatAlerts a;
  ChatNote n(int id, String token) => ChatNote(id, token, 'title', 'body');

  setUp(() {
    shown = [];
    hidden = [];
    dismissed = [];
    viewing = null;
    a = ChatAlerts(
      isViewing: (t) => t == viewing,
      show: (note) => shown.add(note.token),
      hide: hidden.add,
      dismiss: dismissed.add,
    );
  });

  test('stays quiet about notifications from before startup', () {
    a.update([n(1, 'a')]);
    expect(shown, isEmpty);
  });

  test('shows a new one once', () {
    a.update([]);
    a.update([n(1, 'a')]);
    a.update([n(1, 'a')]);
    expect(shown, ['a']);
  });

  test('the open, focused conversation clears instead of alerting', () {
    a.update([]);
    viewing = 'a';
    a.update([n(1, 'a'), n(2, 'b')]);
    expect(shown, ['b']);
    expect(dismissed, [1]);
  });

  test('hides the popup when another device clears it', () {
    a.update([]);
    a.update([n(1, 'a')]);
    a.update([]);
    expect(hidden, ['a']);
  });

  test('keeps the popup while the conversation has another notification', () {
    a.update([]);
    a.update([n(1, 'a'), n(2, 'a')]);
    a.update([n(2, 'a')]);
    expect(hidden, isEmpty);
  });

  test('reading a conversation clears its notifications and popup', () {
    a.update([]);
    a.update([n(1, 'a'), n(2, 'b')]);
    a.conversationRead('a');
    expect(hidden, ['a']);
    expect(dismissed, [1]);
  });

  test('message text cannot become options or markup', () {
    final args = notifyArgs('--title', '--evil <b>x</b> & y');
    final split = args.indexOf('--');
    expect(args.sublist(split + 1),
        ['--title', '--evil &lt;b&gt;x&lt;/b&gt; &amp; y']);
  });

  test('the sound goes as a hint, before the end of the options', () {
    final args = notifyArgs('t', 'b', soundFile: '/a/message.wav');
    expect(
      args.indexOf('--hint=string:sound-file:/a/message.wav'),
      lessThan(args.indexOf('--')),
    );
    expect(notifyArgs('t', 'b').any((a) => a.startsWith('--hint')), isFalse);
  });
}
