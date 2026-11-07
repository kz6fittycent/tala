import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_info.dart';
import 'log.dart';
import 'nc_api.dart';
import 'paths.dart';
import 'tray.dart';

/// "Report a problem": a report goes to a relay (`relay/bug-report/`) that files
/// it as a public issue on Tala's GitHub repo, so the user needs no GitHub
/// account and the app holds no token. Nothing is sent until the user clicks
/// Send, and what identifies them is masked first.
const _relayUrl = 'https://tala-bug-report.jimmy-tigert.workers.dev/report';
const _requestTimeout = Duration(seconds: 30);
const _maxLogChars = 45000;
const _maxDetailChars = 12000;
const maxDescriptionChars = 5000;
const maxContactChars = 200;
const _pendingMaxFiles = 5;
const _pendingMaxAge = Duration(days: 30);

/// `TALA_REPORT_URL` points reports somewhere else, for tests.
String get reportUrl => Platform.environment['TALA_REPORT_URL'] ?? _relayUrl;

// ---------------------------------------------------------------------------
// Masking. These logs quote raw error text, which can hold URLs and addresses.

final _url = RegExp(r'\b(https?|wss?|stuns?|turns?):(//)?[^\s/"' "'" r'),\]]+');
final _tokenPath = RegExp(r'/(room|call|chat|token)/[A-Za-z0-9]{4,}');
final _tokenQuery = RegExp(r'\btoken=[A-Za-z0-9_-]+');
final _email = RegExp(r'\b[\w.+-]+@[\w-]+(\.[\w-]+)+\b');
final _home = RegExp(r'/(home|Users)/[^/\s"' "'" r'`)\]]+');
final _ipv4 = RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b');
final _ipv6 = RegExp(
  r'(?<![\w:])(?:[0-9a-fA-F]{1,4}:){4,7}[0-9a-fA-F]{1,4}(?![\w:])'
  r'|(?<![\w:])(?:[0-9a-fA-F]{1,4}:)+:(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4})*)?(?![\w:])',
);
final _domain = RegExp(
  r'\b(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}\b',
);
// File names and D-Bus names look like domains and help with diagnosis.
const _notDomainEndings = {
  'dart', 'txt', 'json', 'wav', 'png', 'so', 'cc', 'js', 'yaml', 'desktop',
  'php',
};
const _notDomainStarts = {'org', 'com', 'io', 'net', 'dart', 'package'};

bool _keepDotted(String word) {
  final parts = word.toLowerCase().split('.');
  return _notDomainEndings.contains(parts.last) ||
      _notDomainStarts.contains(parts.first);
}

/// Hides what identifies the user: their server and account, other hosts and
/// addresses, room tokens, email addresses and home folder names.
String maskReportText(
  String text, {
  String? server,
  String? user,
  String? password,
}) {
  var out = text;
  if (password != null && password.isNotEmpty) {
    out = out.replaceAll(password, '[password]');
  }
  out = out.replaceAllMapped(_url, (m) => '${m[1]}://[host]');
  final host = server == null ? null : Uri.tryParse(server)?.host;
  if (host != null && host.isNotEmpty) out = out.replaceAll(host, '[server]');
  out = out
      .replaceAllMapped(_tokenPath, (m) => '/${m[1]}/[token]')
      .replaceAll(_tokenQuery, 'token=[token]')
      .replaceAll(_email, '[email]')
      .replaceAll(_home, '~')
      .replaceAll(_ipv4, '[ip]')
      .replaceAll(_ipv6, '[ip]')
      .replaceAllMapped(
        _domain,
        (m) => _keepDotted(m[0]!) ? m[0]! : '[host]',
      );
  // Short names would match ordinary words.
  if (user != null && user.length >= 3) {
    out = out.replaceAll(
      RegExp('(?<![\\w-])${RegExp.escape(user)}(?![\\w-])'),
      '[user]',
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// Crashes.

/// What a crash report needs. Saved as `crash.json`.
class Crash {
  Crash({
    required this.summary,
    required this.message,
    required this.fingerprint,
    required this.version,
    required this.details,
  });

  /// "StateError" or "fatal signal SIGSEGV".
  final String summary;
  final String message;
  final String fingerprint;
  final String version;
  final String details;

  Map<String, dynamic> toJson() => {
    'summary': summary,
    'message': message,
    'fingerprint': fingerprint,
    'version': version,
    'details': details,
  };

  static Crash? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['summary'], f = j['fingerprint'];
    if (s is! String || f is! String) return null;
    return Crash(
      summary: s,
      message: j['message'] as String? ?? '',
      fingerprint: f,
      version: j['version'] as String? ?? '',
      details: j['details'] as String? ?? '',
    );
  }
}

/// 12 hex digits of FNV-1a 64, the same as XBTune's. The relay only needs it to
/// match reports of one bug.
String reportFingerprint(String key) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(key)) {
    h ^= b;
    h *= 0x100000001b3;
  }
  return (h >>> 16).toRadixString(16).padLeft(12, '0');
}

/// A lost connection isn't a bug in Tala, however it surfaced.
@visibleForTesting
bool isNetworkError(Object e) =>
    e is SocketException ||
    e is HttpException ||
    e is TlsException ||
    e is WebSocketException ||
    e is TimeoutException;

/// A release build's stack has no names, so the error's type and its message
/// without numbers identify the bug across versions and users.
@visibleForTesting
Crash describeError(Object error, StackTrace? stack) {
  final type = error.runtimeType.toString();
  final message = error.toString();
  final shortMessage = message.length > 300
      ? message.substring(0, 300)
      : message;
  var details = '$message\n\n${stack ?? ''}';
  if (details.length > _maxDetailChars) {
    details = details.substring(0, _maxDetailChars);
  }
  return Crash(
    summary: type,
    message: shortMessage,
    fingerprint: reportFingerprint(
      'dart|$type|${message.replaceAll(RegExp(r'\d'), '')}',
    ),
    version: appVersion,
    details: details,
  );
}

/// A crash this session that the app survived, for offering a report at once.
final ValueNotifier<Crash?> newCrash = ValueNotifier(null);
bool _crashed = false;

void recordDartError(Object error, StackTrace? stack, {Directory? dir}) {
  final crash = describeError(error, stack);
  log('uncaught ${crash.summary}: ${crash.message}');
  if (isNetworkError(error) || _crashed) return;
  _crashed = true;
  try {
    File('${(dir ?? configDir).path}/crash.json').writeAsStringSync(
      jsonEncode(crash.toJson()),
    );
  } on FileSystemException catch (e) {
    log('report: could not save the crash: ${e.osError?.message}');
  }
  newCrash.value = crash;
}

void installCrashCapture() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    previous?.call(details);
    recordDartError(details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    recordDartError(error, stack);
    return true;
  };
}

/// What the last session left: an error in Dart (`crash.json`), or a fatal
/// signal, written by `linux/runner/fatal_signal.cc`.
Crash? previousCrash({Directory? dir}) {
  final d = (dir ?? configDir).path;
  try {
    final c = Crash.fromJson(
      jsonDecode(File('$d/crash.json').readAsStringSync()),
    );
    if (c != null) return c;
  } on FileSystemException {
    // None saved.
  } on FormatException {
    // Half written, and not worth reporting.
  }
  try {
    final lines = File('$d/fatal.log')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final signal = lines.last.trim().replaceFirst('fatal signal ', '');
    return Crash(
      summary: 'fatal signal $signal',
      message: '',
      fingerprint: reportFingerprint('signal|$signal'),
      version: '(previous session)',
      details: 'A fatal signal stopped the app; the log shows what it was doing.',
    );
  } on FileSystemException {
    return null;
  }
}

/// The user has answered: don't offer it again. The fatal log is emptied rather
/// than deleted because the running app holds it open.
void forgetCrash({Directory? dir}) {
  final d = (dir ?? configDir).path;
  try {
    final crash = File('$d/crash.json');
    if (crash.existsSync()) crash.deleteSync();
    final fatal = File('$d/fatal.log');
    if (fatal.existsSync()) fatal.writeAsStringSync('');
  } on FileSystemException catch (e) {
    log('report: could not clear the crash: ${e.osError?.message}');
  }
}

// ---------------------------------------------------------------------------
// What goes in a report.

/// The JSON the relay expects (`relay/bug-report/worker.js`).
class Report {
  Report({
    required this.description,
    required this.version,
    required this.platform,
    required this.facts,
    required this.log,
    this.contact,
    this.error,
    this.fingerprint,
  });

  final String description;
  final String? contact;
  final String version;
  final String platform;
  final String facts;
  final String? error;
  final String? fingerprint;
  final String log;

  Map<String, dynamic> toJson() => {
    'description': description,
    if (contact != null) 'contact': contact,
    'version': version,
    'platform': platform,
    if (facts.isNotEmpty) 'facts': facts,
    if (error != null) 'error': error,
    if (fingerprint != null) 'fingerprint': fingerprint,
    'log': log,
  };

  static Report? fromJson(Object? j) {
    if (j is! Map) return null;
    final v = j['version'], p = j['platform'];
    if (v is! String || p is! String) return null;
    return Report(
      description: j['description'] as String? ?? '',
      contact: j['contact'] as String?,
      version: v,
      platform: p,
      facts: j['facts'] as String? ?? '',
      error: j['error'] as String?,
      fingerprint: j['fingerprint'] as String?,
      log: j['log'] as String? ?? '',
    );
  }
}

/// The newest part of the log, starting at a whole line.
String readRecentLog({Directory? dir}) {
  final d = (dir ?? configDir).path;
  String read(String name) {
    try {
      return File('$d/$name').readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  final text = read('log.previous.txt') + read('log.txt');
  if (text.length <= _maxLogChars) return text;
  final tail = text.substring(text.length - _maxLogChars);
  final line = tail.indexOf('\n');
  return line < 0 ? tail : tail.substring(line + 1);
}

/// `/etc/os-release` inside a snap is the base's; the host's is under hostfs.
String reportPlatform() {
  String? prettyName(String path) {
    try {
      for (final line in File(path).readAsLinesSync()) {
        if (line.startsWith('PRETTY_NAME=')) {
          return line.substring(12).replaceAll('"', '');
        }
      }
    } on FileSystemException {
      // Not there on this system.
    }
    return null;
  }

  final env = Platform.environment;
  final revision = env['SNAP_REVISION'];
  final os = revision == null
      ? prettyName('/etc/os-release')
      : prettyName('/var/lib/snapd/hostfs/usr/lib/os-release');
  return [
    os ?? Platform.operatingSystem,
    Abi.current().toString(),
    if (revision != null) 'snap rev $revision',
  ].join(' · ');
}

/// What Tala can find out itself, so nobody has to ask the user.
Future<String> gatherFacts({NcApi? api, AppTray? tray}) async {
  final env = Platform.environment;
  final facts = <String>[
    'Session: ${env['XDG_SESSION_TYPE'] ?? '?'}, '
        'desktop ${env['XDG_CURRENT_DESKTOP'] ?? '?'}',
  ];

  Future<void> add(String label, Future<String?> Function() look) async {
    try {
      final value = await look().timeout(const Duration(seconds: 5));
      if (value != null) facts.add('$label: $value');
    } catch (e) {
      facts.add('$label: could not check');
    }
  }

  await add('Tray host', () async {
    return await (tray ?? AppTray()).available() ? 'yes' : 'no';
  });
  if (env.containsKey('SNAP')) {
    for (final plug in const [
      'password-manager-service',
      'camera',
      'audio-record',
      'audio-playback',
    ]) {
      await add('Snap permission $plug', () async {
        final r = await Process.run('snapctl', ['is-connected', plug]);
        return r.exitCode == 0 ? 'connected' : 'NOT connected';
      });
    }
  }
  if (api != null) await add('Server', api.serverSummary);
  return facts.join('\n');
}

Report buildReport({
  required String description,
  required String contact,
  required String facts,
  Crash? crash,
  Credentials? creds,
  Directory? dir,
}) {
  String mask(String s) => maskReportText(
    s,
    server: creds?.server,
    user: creds?.user,
    password: creds?.appPassword,
  );
  var text = readRecentLog(dir: dir);
  if (crash != null) text += '\n--- crash ---\n${crash.details}';
  final trimmedContact = contact.trim();
  final words = description.trim();
  String? error;
  if (crash != null) {
    final e = mask(
      crash.message.isEmpty
          ? crash.summary
          : '${crash.summary}: ${crash.message}',
    );
    error = e.length > 200 ? e.substring(0, 200) : e;
  }
  return Report(
    // The user's own words and contact details are theirs to send as written.
    description: words.length > maxDescriptionChars
        ? words.substring(0, maxDescriptionChars)
        : words,
    contact: trimmedContact.isEmpty
        ? null
        : trimmedContact.length > maxContactChars
        ? trimmedContact.substring(0, maxContactChars)
        : trimmedContact,
    version: appVersion,
    platform: mask(reportPlatform()),
    facts: mask(facts),
    error: error,
    fingerprint: crash?.fingerprint,
    log: mask(text),
  );
}

// ---------------------------------------------------------------------------
// Sending.

enum ReportResult {
  /// Filed as a new issue.
  sent,

  /// Added to an existing issue for the same crash.
  duplicate,

  /// The relay refused it, and trying again won't help.
  rejected,

  /// Offline, timed out or the relay is busy: worth trying again later.
  failed,
}

class ReportOutcome {
  const ReportOutcome(this.result, [this.message]);
  final ReportResult result;
  final String? message;
}

@visibleForTesting
ReportOutcome classifyReply(int status, String body) {
  Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    json = null;
  }
  final map = json is Map ? json : const {};
  final error = map['error'] is String ? map['error'] as String : 'HTTP $status';
  if (status == 200 || status == 201) {
    return ReportOutcome(
      map['duplicate'] == true ? ReportResult.duplicate : ReportResult.sent,
    );
  }
  if (const {400, 404, 405, 413}.contains(status)) {
    return ReportOutcome(ReportResult.rejected, error);
  }
  return ReportOutcome(ReportResult.failed, error);
}

Future<ReportOutcome> postReport(Report report, {String? url}) async {
  final client = HttpClient()
    ..userAgent = 'Tala/$appVersion'
    ..connectionTimeout = _requestTimeout;
  try {
    final request = await client
        .postUrl(Uri.parse(url ?? reportUrl))
        .timeout(_requestTimeout);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(report.toJson())));
    final response = await request.close().timeout(_requestTimeout);
    final body = await utf8.decoder.bind(response).join().timeout(_requestTimeout);
    return classifyReply(response.statusCode, body);
  } catch (e) {
    return ReportOutcome(ReportResult.failed, e.runtimeType.toString());
  } finally {
    client.close(force: true);
  }
}

Directory _pendingDir(Directory? dir) =>
    Directory('${(dir ?? configDir).path}/pending');

/// Saved reports, oldest first, deleting any past their age limit.
@visibleForTesting
List<File> pendingReports({Directory? dir}) {
  final d = _pendingDir(dir);
  if (!d.existsSync()) return [];
  final now = DateTime.now();
  final files = <File>[];
  for (final f in d.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json')) continue;
    if (now.difference(f.lastModifiedSync()) > _pendingMaxAge) {
      f.deleteSync();
    } else {
      files.add(f);
    }
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}

bool _savePending(Report report, {Directory? dir}) {
  try {
    final d = _pendingDir(dir)..createSync(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch.toString().padLeft(20, '0');
    File('${d.path}/$stamp.json').writeAsStringSync(jsonEncode(report.toJson()));
    final all = pendingReports(dir: dir);
    if (all.length > _pendingMaxFiles) {
      for (final old in all.take(all.length - _pendingMaxFiles)) {
        old.deleteSync();
      }
    }
    return true;
  } on FileSystemException catch (e) {
    log('report: could not save for later: ${e.osError?.message}');
    return false;
  }
}

/// Sends a report, saving it for a later start if it can't go now.
Future<ReportOutcome> sendReport(
  Report report, {
  String? url,
  Directory? dir,
}) async {
  final outcome = await postReport(report, url: url);
  switch (outcome.result) {
    case ReportResult.sent:
    case ReportResult.duplicate:
      log('report: sent');
    case ReportResult.rejected:
      log('report: refused: ${outcome.message}');
    case ReportResult.failed:
      log('report: not sent, saving to try later: ${outcome.message}');
      if (!_savePending(report, dir: dir)) {
        return ReportOutcome(
          ReportResult.rejected,
          'It couldn\'t be sent or saved.',
        );
      }
  }
  return outcome;
}

/// Tries saved reports one at a time, stopping at the first that still can't
/// go, which usually means there's still no connection.
Future<void> sendPendingReports({String? url, Directory? dir}) async {
  for (final file in pendingReports(dir: dir)) {
    Report? report;
    try {
      report = Report.fromJson(jsonDecode(file.readAsStringSync()));
    } on FormatException {
      report = null;
    }
    if (report == null) {
      file.deleteSync();
      continue;
    }
    final outcome = await postReport(report, url: url);
    if (outcome.result == ReportResult.failed) {
      log('report: a saved report still can\'t be sent');
      return;
    }
    log('report: a saved report went: ${outcome.result.name}');
    file.deleteSync();
  }
}
