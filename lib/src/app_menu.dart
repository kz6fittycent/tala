import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_info.dart';
import 'chat_view.dart';
import 'log.dart';
import 'nc_api.dart';
import 'report_view.dart';
import 'settings.dart';
import 'tray.dart';

/// Host and any port or subfolder, for showing to people.
String serverLabel(String server) {
  final uri = Uri.tryParse(server);
  if (uri == null || uri.host.isEmpty) return server;
  final port = uri.hasPort ? ':${uri.port}' : '';
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  return '${uri.host}$port$path';
}

String normalizeServerUrl(String input) {
  final url = input.trim().replaceAll(RegExp(r'/+$'), '');
  if (url.isEmpty) return '';
  return url.startsWith(RegExp(r'https?://')) ? url : 'https://$url';
}

/// Asks for a server and runs the browser sign-in. Nothing is stored here.
class SignInForm extends StatefulWidget {
  const SignInForm({
    super.key,
    required this.onSignedIn,
    this.initialServer = '',
    this.signIn = loginFlow,
  });

  final ValueChanged<Credentials> onSignedIn;
  final String initialServer;
  final Future<Credentials> Function(String, {bool Function()? isCancelled})
  signIn;

  @override
  State<SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<SignInForm> {
  late final TextEditingController _server = TextEditingController(
    text: widget.initialServer,
  );
  String? _status;
  bool _waiting = false;

  /// Bumped to abandon a sign-in that's still waiting on the browser.
  int _attempt = 0;

  Future<void> _go() async {
    final url = normalizeServerUrl(_server.text);
    if (url.isEmpty) return;
    final attempt = ++_attempt;
    setState(() {
      _waiting = true;
      _status = 'Approve the login in your browser…';
    });
    try {
      final creds = await widget.signIn(
        url,
        isCancelled: () => attempt != _attempt,
      );
      if (!mounted || attempt != _attempt) return;
      widget.onSignedIn(creds);
    } on LoginCancelled {
      // The user already moved on.
    } catch (e) {
      log('login: $e');
      if (mounted && attempt == _attempt) {
        setState(() {
          _waiting = false;
          _status = 'Login failed: $e';
        });
      }
    }
  }

  void _cancel() {
    _attempt++;
    setState(() {
      _waiting = false;
      _status = null;
    });
  }

  @override
  void dispose() {
    _attempt++;
    _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextField(
        controller: _server,
        enabled: !_waiting,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Nextcloud server address',
        ),
        onSubmitted: (_) => _go(),
      ),
      const SizedBox(height: 16),
      if (_waiting)
        OutlinedButton(onPressed: _cancel, child: const Text('Cancel sign-in'))
      else
        FilledButton(onPressed: _go, child: const Text('Sign in')),
      if (_status != null) ...[const SizedBox(height: 16), Text(_status!)],
    ],
  );
}

enum _MenuChoice {
  account,
  appearance,
  sound,
  archived,
  startAtLogin,
  help,
  report,
  about,
  support,
}

class AppMenu extends StatefulWidget {
  const AppMenu({
    super.key,
    required this.settings,
    required this.creds,
    required this.onChangeAccount,
  });

  final AppSettings settings;
  final Credentials creds;
  final ValueChanged<Credentials> onChangeAccount;

  @override
  State<AppMenu> createState() => _AppMenuState();
}

class _AppMenuState extends State<AppMenu> {
  AppSettings get settings => widget.settings;
  Credentials get creds => widget.creds;

  /// Null hides the choice, on platforms without it.
  bool? _startAtLogin;

  @override
  void initState() {
    super.initState();
    AppTray.startAtLogin().then((enabled) {
      if (mounted) setState(() => _startAtLogin = enabled);
    });
  }

  Future<void> _toggleStartAtLogin() async {
    final messenger = ScaffoldMessenger.of(context);
    final wanted = !(_startAtLogin ?? false);
    if (await AppTray.setStartAtLogin(wanted)) {
      if (mounted) setState(() => _startAtLogin = wanted);
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t change start at login.')),
      );
    }
  }

  PopupMenuItem<_MenuChoice> _item(
    _MenuChoice value,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: value,
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
    ),
  );

  void _chosen(BuildContext context, _MenuChoice choice) {
    switch (choice) {
      case _MenuChoice.account:
        showDialog<void>(
          context: context,
          builder: (_) => AccountDialog(
            creds: creds,
            onChangeAccount: widget.onChangeAccount,
          ),
        );
      case _MenuChoice.appearance:
        showDialog<void>(
          context: context,
          builder: (_) => AppearanceDialog(settings: settings),
        );
      case _MenuChoice.sound:
        settings.messageSound = !settings.messageSound;
      case _MenuChoice.archived:
        settings.hideArchived = !settings.hideArchived;
      case _MenuChoice.startAtLogin:
        _toggleStartAtLogin();
      case _MenuChoice.help:
        openExternal(wikiUrl);
      case _MenuChoice.report:
        showReportDialog(context, creds: creds);
      case _MenuChoice.about:
        showDialog<void>(context: context, builder: (_) => const AboutTala());
      case _MenuChoice.support:
        openExternal(supportUrl);
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<_MenuChoice>(
    tooltip: 'Menu',
    icon: const Icon(Icons.more_vert),
    onSelected: (choice) => _chosen(context, choice),
    itemBuilder: (context) => [
      PopupMenuItem(
        value: _MenuChoice.account,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.dns_outlined),
          title: Text(creds.user, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            serverLabel(creds.server),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      const PopupMenuDivider(),
      _item(_MenuChoice.appearance, Icons.palette_outlined, 'Appearance…'),
      const PopupMenuDivider(),
      CheckedPopupMenuItem(
        value: _MenuChoice.sound,
        checked: settings.messageSound,
        child: const Text('Message sound'),
      ),
      CheckedPopupMenuItem(
        value: _MenuChoice.archived,
        checked: !settings.hideArchived,
        child: const Text('Show archived'),
      ),
      if (_startAtLogin != null)
        CheckedPopupMenuItem(
          value: _MenuChoice.startAtLogin,
          checked: _startAtLogin!,
          child: const Text('Start at login'),
        ),
      const PopupMenuDivider(),
      _item(_MenuChoice.help, Icons.help_outline, 'Help'),
      _item(_MenuChoice.report, Icons.bug_report_outlined, 'Report a problem…'),
      _item(_MenuChoice.about, Icons.info_outline, 'About Tala'),
      _item(_MenuChoice.support, Icons.favorite_outline, 'Support Tala'),
    ],
  );
}

class AppearanceDialog extends StatelessWidget {
  const AppearanceDialog({super.key, required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => AlertDialog(
      title: const Text('Appearance'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Theme'),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) => settings.themeMode = s.single,
            ),
            const SizedBox(height: 20),
            const Text('Color'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final accent in accents)
                  _Swatch(
                    accent: accent,
                    selected: settings.accent.name == accent.name,
                    onTap: () => settings.accent = accent,
                  ),
              ],
            ),
          ],
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

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.accent,
    required this.selected,
    required this.onTap,
  });
  final Accent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: accent.label,
    child: Tooltip(
      message: accent.label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: CircleAvatar(
          radius: 22,
          backgroundColor: accent.color,
          foregroundColor: Colors.white,
          child: selected ? const Icon(Icons.check) : null,
        ),
      ),
    ),
  );
}

class AccountDialog extends StatefulWidget {
  const AccountDialog({
    super.key,
    required this.creds,
    required this.onChangeAccount,
  });

  final Credentials creds;
  final ValueChanged<Credentials> onChangeAccount;

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  bool _changing = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Account'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText('Signed in as ${widget.creds.user}'),
          const SizedBox(height: 4),
          SelectableText('Server: ${serverLabel(widget.creds.server)}'),
          if (_changing) ...[
            const SizedBox(height: 16),
            const Text(
              'Sign in to the new address. You stay on this server until that '
              'works, then Tala removes its app password from this one.',
            ),
            const SizedBox(height: 8),
            SignInForm(
              initialServer: widget.creds.server,
              onSignedIn: (creds) {
                Navigator.of(context).pop();
                widget.onChangeAccount(creds);
              },
            ),
          ],
        ],
      ),
    ),
    actions: [
      if (!_changing)
        TextButton(
          onPressed: () => setState(() => _changing = true),
          child: const Text('Change server…'),
        ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}

class AboutTala extends StatelessWidget {
  const AboutTala({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: Image.asset('assets/icon/tala-small-64.png', width: 64, height: 64),
    title: const Text('Tala'),
    content: const SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Version $appVersion'),
          SizedBox(height: 12),
          Text(
            'Chat and calls for Nextcloud Talk.',
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 12),
          Text(
            'Tala is an independent project, not affiliated with or endorsed '
            'by Nextcloud GmbH.',
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 12),
          Text(
            'Copyright © 2026 kz6fittycent. Free software under the GNU '
            'Affero General Public License, version 3 or any later version.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => showLicensePage(
          context: context,
          applicationName: 'Tala',
          applicationVersion: appVersion,
        ),
        child: const Text('Licenses'),
      ),
      TextButton(
        onPressed: () => openExternal(repoUrl),
        child: const Text('Source code'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}
