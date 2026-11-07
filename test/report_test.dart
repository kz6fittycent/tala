import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/app_info.dart';
import 'package:tala/src/nc_api.dart';
import 'package:tala/src/report.dart';
import 'package:tala/src/report_view.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tala-report'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('masking', () {
    String mask(String s) => maskReportText(
      s,
      server: 'https://cloud.example.org/nc',
      user: 'alice',
      password: 'sEcReT-pass',
    );

    test('the account and server', () {
      final out = mask('alice at cloud.example.org with sEcReT-pass, not malice');
      expect(out, '[user] at [server] with [password], not malice');
    });

    test('URLs of any kind, and other hosts', () {
      expect(
        mask('failed https://signal.other.net/spreed/x'),
        'failed https://[host]/spreed/x',
      );
      expect(mask('wss://signal.other.net/ws'), 'wss://[host]/ws');
      expect(mask('turn:turn.other.net:3478'), 'turn://[host]');
      expect(
        mask("SocketException: Failed host lookup: 'files.other.net'"),
        "SocketException: Failed host lookup: '[host]'",
      );
    });

    test('room tokens', () {
      expect(
        mask('GET /ocs/v2.php/apps/spreed/api/v4/room/ab12cd34/participants'),
        'GET /ocs/v2.php/apps/spreed/api/v4/room/[token]/participants',
      );
      expect(mask('/api/v4/call/ab12cd34'), '/api/v4/call/[token]');
      expect(mask('/settings?token=ab12cd34'), '/settings?token=[token]');
    });

    test('email, IP addresses and home folders', () {
      expect(mask('from bob@mail.other.net'), 'from [email]');
      expect(mask('peer 192.168.1.20 port 80'), 'peer [ip] port 80');
      expect(mask('peer 2001:db8:0:0:1:2:3:4 up'), 'peer [ip] up');
      expect(mask('peer fe80::1 up'), 'peer [ip] up');
      expect(mask('open /home/alice/snap/tala/x'), 'open ~/snap/tala/x');
      expect(mask('open /home/bob/x'), 'open ~/x');
    });

    test('what helps with diagnosis stays', () {
      for (final keep in [
        '18:05:43.121 call: Joining',
        'at package:tala/src/call.dart:12',
        'org.freedesktop.secrets was not provided',
        'io.github.kz6fittycent.tala',
        'read log.previous.txt and ring.wav',
        'Tala 0.2.1 starting',
        'hello ok, version 2.0, mcu=true',
      ]) {
        expect(mask(keep), keep);
      }
    });

    test('a very short username does not eat ordinary words', () {
      expect(maskReportText('a cat', user: 'a'), 'a cat');
    });
  });

  group('fingerprint', () {
    test('matches XBTune and the relay format', () {
      expect(reportFingerprint('signal|SIGSEGV'), '27c8dcf0f79a');
      expect(reportFingerprint('x'), matches(RegExp(r'^[0-9a-f]{12}$')));
    });

    test('the same bug matches despite different numbers', () {
      final a = describeError(StateError('index 3 of 9'), null);
      final b = describeError(StateError('index 12 of 40'), null);
      final c = describeError(ArgumentError('index 3 of 9'), null);
      expect(a.fingerprint, b.fingerprint);
      expect(a.fingerprint, isNot(c.fingerprint));
    });
  });

  group('crashes', () {
    test('network trouble is not treated as a bug', () {
      expect(isNetworkError(const SocketException('x')), isTrue);
      expect(isNetworkError(TimeoutException('x')), isTrue);
      expect(isNetworkError(StateError('x')), isFalse);
    });

    test('a saved crash is found, then forgotten', () {
      expect(previousCrash(dir: dir), isNull);
      final crash = describeError(StateError('boom'), null);
      File('${dir.path}/crash.json').writeAsStringSync(
        jsonEncode(crash.toJson()),
      );
      expect(previousCrash(dir: dir)!.fingerprint, crash.fingerprint);
      forgetCrash(dir: dir);
      expect(previousCrash(dir: dir), isNull);
    });

    test('a fatal signal is found; forgetting keeps the file open-able', () {
      final fatal = File('${dir.path}/fatal.log')
        ..writeAsStringSync('fatal signal SIGSEGV\n');
      final crash = previousCrash(dir: dir)!;
      expect(crash.summary, 'fatal signal SIGSEGV');
      expect(crash.fingerprint, '27c8dcf0f79a');
      forgetCrash(dir: dir);
      expect(fatal.existsSync(), isTrue);
      expect(previousCrash(dir: dir), isNull);
    });

    test('an empty fatal log and a corrupt crash file mean no crash', () {
      File('${dir.path}/fatal.log').writeAsStringSync('');
      File('${dir.path}/crash.json').writeAsStringSync('{half');
      expect(previousCrash(dir: dir), isNull);
    });
  });

  group('building a report', () {
    test('masks the log, facts and error, and keeps the newest log', () {
      File('${dir.path}/log.previous.txt').writeAsStringSync(
        '${'old line\n' * 8000}last old line\n',
      );
      File('${dir.path}/log.txt').writeAsStringSync(
        'rooms: failed https://cloud.example.org/x as alice\n',
      );
      final r = buildReport(
        description: '  it broke \n',
        contact: '',
        facts: 'Server host cloud.example.org',
        crash: describeError(StateError('alice lost it'), null),
        creds: Credentials('https://cloud.example.org', 'alice', 'pw-secret'),
        dir: dir,
      );
      final j = r.toJson();
      expect(j['description'], 'it broke');
      expect(j.containsKey('contact'), isFalse);
      expect(j['version'], appVersion);
      expect(j['facts'], 'Server host [server]');
      expect(j['error'], contains('[user] lost it'));
      expect(j['fingerprint'], matches(RegExp(r'^[0-9a-f]{12}$')));
      final text = j['log'] as String;
      expect(text, contains('https://[host]/x as [user]'));
      expect(text, contains('last old line'));
      expect(text.length, lessThan(46000));
      expect(jsonEncode(j), isNot(contains('alice')));
      expect(jsonEncode(j), isNot(contains('example.org')));
    });

    test('the user\'s own words go as written, within limits', () {
      final r = buildReport(
        description: 'x' * 6000,
        contact: 'alice@example.org',
        facts: '',
        creds: Credentials('https://example.org', 'alice', 'p'),
        dir: dir,
      );
      expect(r.description.length, maxDescriptionChars);
      expect(r.contact, 'alice@example.org');
      expect(r.toJson().containsKey('facts'), isFalse);
    });
  });

  test('relay answers are understood', () {
    expect(
      classifyReply(201, '{"issue":4,"duplicate":false}').result,
      ReportResult.sent,
    );
    expect(
      classifyReply(200, '{"issue":4,"duplicate":true}').result,
      ReportResult.duplicate,
    );
    final refused = classifyReply(400, '{"error":"too long"}');
    expect(refused.result, ReportResult.rejected);
    expect(refused.message, 'too long');
    expect(classifyReply(429, '{}').result, ReportResult.failed);
    expect(classifyReply(502, 'not json').result, ReportResult.failed);
  });

  group('sending', () {
    // Widget tests replace HttpClient with one that makes no real requests.
    setUp(() => HttpOverrides.global = null);

    Report sample() => Report(
      description: 'd',
      version: 'v',
      platform: 'p',
      facts: 'f',
      log: 'l',
    );

    Future<(String, List<String>)> relay(int status, String body) async {
      final got = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((q) async {
        got.add(await utf8.decoder.bind(q).join());
        q.response
          ..statusCode = status
          ..write(body);
        await q.response.close();
      });
      return ('http://127.0.0.1:${server.port}/report', got);
    }

    Future<String> deadUrl() async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      return 'http://127.0.0.1:$port/report';
    }

    test('posts the JSON the relay expects', () async {
      final (url, got) = await relay(201, '{"issue":7}');
      final o = await sendReport(sample(), url: url, dir: dir);
      expect(o.result, ReportResult.sent);
      expect(jsonDecode(got.single), sample().toJson());
      expect(pendingReports(dir: dir), isEmpty);
    });

    test('a failed send is saved, then goes on a later try', () async {
      final o = await sendReport(sample(), url: await deadUrl(), dir: dir);
      expect(o.result, ReportResult.failed);
      expect(pendingReports(dir: dir), hasLength(1));

      await sendPendingReports(url: await deadUrl(), dir: dir);
      expect(pendingReports(dir: dir), hasLength(1));

      final (url, got) = await relay(201, '{"issue":7}');
      await sendPendingReports(url: url, dir: dir);
      expect(got, hasLength(1));
      expect(pendingReports(dir: dir), isEmpty);
    });

    test('a refused report is not kept', () async {
      final (url, _) = await relay(400, '{"error":"no"}');
      final o = await sendReport(sample(), url: url, dir: dir);
      expect(o.result, ReportResult.rejected);
      expect(pendingReports(dir: dir), isEmpty);
    });

    test('at most five are kept', () async {
      final dead = await deadUrl();
      for (var i = 0; i < 7; i++) {
        await sendReport(sample(), url: dead, dir: dir);
      }
      expect(pendingReports(dir: dir), hasLength(5));
    });

    test('an unreadable saved report is dropped', () async {
      final pending = Directory('${dir.path}/pending')..createSync();
      File('${pending.path}/1.json').writeAsStringSync('{half');
      final (url, got) = await relay(201, '{}');
      await sendPendingReports(url: url, dir: dir);
      expect(got, isEmpty);
      expect(pendingReports(dir: dir), isEmpty);
    });
  });

  group('dialog', () {
    Future<void> open(
      WidgetTester tester, {
      required Future<ReportOutcome> Function(Report) send,
      Crash? crash,
      bool earlier = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportDialog(
              facts: Future.value('Tray host: yes'),
              send: send,
              crash: crash,
              earlier: earlier,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('sends only on click, and says the issue is public', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      var sent = <Report>[];
      await open(
        tester,
        send: (r) async {
          sent.add(r);
          return const ReportOutcome(ReportResult.sent);
        },
      );
      expect(find.textContaining('public issue'), findsOneWidget);
      expect(sent, isEmpty);
      await tester.enterText(find.byType(TextField).first, 'it broke');
      await tester.runAsync(() async {
        await tester.tap(find.text('Send report'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(sent.single.description, 'it broke');
      expect(sent.single.facts, 'Tray host: yes');
      expect(find.text('Thank you'), findsOneWidget);
    });

    testWidgets('a failure says it was saved', (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      await open(
        tester,
        send: (_) async => const ReportOutcome(ReportResult.failed, 'x'),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Send report'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Saved for later'), findsOneWidget);
    });

    testWidgets('a crash names itself and offers not sending', (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      await open(
        tester,
        send: (_) async => const ReportOutcome(ReportResult.sent),
        crash: describeError(StateError('boom'), null),
        earlier: true,
      );
      expect(find.text('Tala closed unexpectedly'), findsOneWidget);
      expect(find.textContaining('StateError'), findsOneWidget);
      expect(find.text('Don\'t send'), findsOneWidget);
    });
  });

  test('the kernel fact keeps the distribution clue and drops the builder', () {
    expect(
      kernelFact(
        'Linux version 7.0.0-43-generic (buildd@lcy02-amd64-080) '
        '(x86_64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0, GNU ld '
        '(GNU Binutils for Ubuntu) 2.46) #43-Ubuntu SMP PREEMPT\n',
      ),
      '7.0.0-43-generic (x86_64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) '
      '15.2.0, GNU ld (GNU Binutils for Ubuntu) 2.46)',
    );
    expect(kernelFact('x' * 300).length, 160);
  });
}
