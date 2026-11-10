import 'dart:async';

import 'package:flutter/material.dart';

import 'chat.dart' show ApiException;
import 'log.dart';

/// online, away, dnd, invisible or offline, as Nextcloud names them.
class UserStatus {
  const UserStatus(this.type, {this.message = '', this.icon = ''});

  factory UserStatus.fromJson(Map<String, dynamic> j) => UserStatus(
    j['status'] as String? ?? 'offline',
    message: j['message'] as String? ?? '',
    icon: j['icon'] as String? ?? '',
  );

  final String type;
  final String message;
  final String icon;

  String get label => statusLabel(type);

  /// The message with its emoji, as the web shows it.
  String get text => [icon, message].where((s) => s.isNotEmpty).join(' ');

  /// "Away · Back at 3", or null when there's nothing worth a line: offline
  /// with no message.
  String? get summary {
    final parts = [
      if (statusColor(type) != null) label,
      if (text.isNotEmpty) text,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

String statusLabel(String type) => switch (type) {
  'online' => 'Online',
  'away' => 'Away',
  'dnd' => 'Do not disturb',
  'invisible' => 'Invisible',
  'busy' => 'Busy',
  _ => 'Offline',
};

/// Null for offline and invisible, which show no dot.
Color? statusColor(String type) => switch (type) {
  'online' => const Color(0xFF2E9F4E),
  'away' || 'busy' => const Color(0xFFE6A100),
  'dnd' => const Color(0xFFD7263D),
  _ => null,
};

/// A dot on an avatar's corner. Ringed with the surface so it reads on any
/// avatar color.
class StatusDot extends StatelessWidget {
  const StatusDot(this.type, {super.key, this.size = 12});
  final String type;
  final double size;
  @override
  Widget build(BuildContext context) {
    final color = statusColor(type);
    if (color == null) return const SizedBox.shrink();
    return Semantics(
      label: statusLabel(type),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.surface,
            width: 2,
          ),
        ),
      ),
    );
  }
}

/// Puts [dot] on [avatar]'s lower right corner.
Widget withStatus(Widget avatar, String? type) => type == null
    ? avatar
    : Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(right: -2, bottom: -2, child: StatusDot(type)),
        ],
      );

/// Keeps the server told whether the user is here, the way the web client's
/// heartbeat does, and holds their own status. The server only applies a
/// heartbeat while the user's chosen status is Online, so Away, Do not disturb
/// and Invisible set by hand stay put.
class Presence extends ChangeNotifier {
  Presence({
    required this.heartbeat,
    required this.fetchOwn,
    required this.setOwn,
    this.interval = const Duration(minutes: 5),
    this.awayAfter = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Returns the user's status afterwards, when the server says.
  final Future<UserStatus?> Function({required bool away}) heartbeat;
  final Future<UserStatus> Function() fetchOwn;
  final Future<void> Function(String type) setOwn;
  final Duration interval;

  /// Unfocused this long counts as away.
  final Duration awayAfter;
  final DateTime Function() _now;

  Timer? _timer;
  bool _focused = true;
  DateTime? _leftAt;
  bool? _sentAway;
  bool _disabled = false;
  UserStatus? own;

  /// False if the server has no user status app.
  bool get available => !_disabled;

  bool get _away =>
      !_focused && _leftAt != null && _now().difference(_leftAt!) >= awayAfter;

  void start({required bool focused}) {
    _focused = focused;
    if (!focused) _leftAt = _now();
    _timer = Timer.periodic(interval, (_) => _beat());
    // After the beat: the server makes a status for someone who has none on
    // their first heartbeat, and until then reading it is a 404.
    _beat().then((_) => refresh());
  }

  /// Coming back sends at once, so others see the change without waiting.
  void focusChanged(bool focused) {
    if (_focused == focused) return;
    _focused = focused;
    if (focused) {
      _leftAt = null;
      if (_sentAway == true) _beat();
    } else {
      _leftAt = _now();
    }
  }

  Future<void> _beat() async {
    if (_disabled) return;
    final away = _away;
    try {
      final status = await heartbeat(away: away);
      _sentAway = away;
      if (status != null && status.type != own?.type) {
        own = status;
        notifyListeners();
      }
    } catch (e) {
      _failed(e, 'heartbeat');
    }
  }

  Future<void> refresh() async {
    if (_disabled) return;
    try {
      own = await fetchOwn();
      notifyListeners();
    } on ApiException catch (e) {
      // "No status for the current user", not a missing app: only a heartbeat
      // 404 means that.
      if (e.status != 404) log('status: reading status failed: $e');
    } catch (e) {
      log('status: reading status failed: $e');
    }
  }

  /// Returns false if the server refused.
  Future<bool> set(String type) async {
    try {
      await setOwn(type);
      own = UserStatus(type, message: own?.message ?? '', icon: own?.icon ?? '');
      notifyListeners();
      return true;
    } catch (e) {
      log('status: setting failed: $e');
      return false;
    }
  }

  void _failed(Object e, String what) {
    if (e is ApiException && e.status == 404) {
      log('status: no user status on this server');
      _disabled = true;
      _timer?.cancel();
      notifyListeners();
    } else {
      log('status: $what failed: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

const _choices = [
  ('online', 'Online', null),
  ('away', 'Away', null),
  ('dnd', 'Do not disturb', 'Mutes all notifications'),
  ('invisible', 'Invisible', 'Appear offline'),
];

/// Picks the user's own status. Changes go to the server at once.
class StatusDialog extends StatelessWidget {
  const StatusDialog({super.key, required this.presence});
  final Presence presence;

  Future<void> _pick(BuildContext context, String type) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    if (await presence.set(type)) {
      navigator.pop();
    } else {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Couldn\'t change your status.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: presence,
    builder: (context, _) => AlertDialog(
      title: const Text('Your status'),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: SizedBox(
        width: 360,
        child: RadioGroup<String>(
          groupValue: presence.own?.type,
          onChanged: (type) {
            if (type != null) _pick(context, type);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (type, label, detail) in _choices)
                RadioListTile<String>(
                  value: type,
                  title: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        child: statusColor(type) == null
                            ? Icon(Icons.circle_outlined, size: 12,
                                color: Theme.of(context).colorScheme.outline)
                            : StatusDot(type),
                      ),
                      const SizedBox(width: 8),
                      Text(label),
                    ],
                  ),
                  subtitle: detail == null ? null : Text(detail),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
