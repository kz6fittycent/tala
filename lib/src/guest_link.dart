import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat.dart' show ApiException;
import 'log.dart';

/// The address a guest opens. `index.php` works whether or not the server has
/// pretty URLs set up.
String guestLink(String server, String token) {
  final base = server.endsWith('/')
      ? server.substring(0, server.length - 1)
      : server;
  return '$base/index.php/call/$token';
}

/// Names a new conversation that people can join without an account. Stays
/// open if the server refuses, and closes with the new conversation's token.
class NewGuestConversationDialog extends StatefulWidget {
  const NewGuestConversationDialog({super.key, required this.create});
  final Future<String> Function(String name, String password) create;

  @override
  State<NewGuestConversationDialog> createState() =>
      _NewGuestConversationDialogState();
}

class _NewGuestConversationDialogState
    extends State<NewGuestConversationDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _ready => _name.text.trim().isNotEmpty && !_busy;

  Future<void> _submit() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await widget.create(_name.text.trim(), _password.text);
      if (mounted) Navigator.of(context).pop(token);
    } catch (e) {
      log('rooms: creating a guest conversation failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException && e.status == 400
            ? 'Your server refused that. It may require a password, or a '
                  'stronger one.'
            : 'Couldn\'t create the conversation. Your server may not allow '
                  'it.';
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Invite someone without an account'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'This creates a conversation with a link. Anyone who has the link '
            'can join its chat and calls, with no Nextcloud account.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 255,
            decoration: const InputDecoration(labelText: 'Conversation name'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password (optional)'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _ready ? _submit : null,
        child: const Text('Create'),
      ),
    ],
  );
}

/// Shows a conversation's link, and for its moderators offers email invitations
/// and turning the link off.
class GuestLinkDialog extends StatefulWidget {
  const GuestLinkDialog({
    super.key,
    required this.name,
    required this.link,
    required this.hasPassword,
    required this.canManage,
    required this.invite,
    required this.turnOff,
  });

  final String name;
  final String link;
  final bool hasPassword;
  final bool canManage;
  final Future<void> Function(String email) invite;

  /// Returns once the user has decided; closes this dialog when it's true.
  final Future<bool> Function() turnOff;

  @override
  State<GuestLinkDialog> createState() => _GuestLinkDialogState();
}

class _GuestLinkDialogState extends State<GuestLinkDialog> {
  final TextEditingController _email = TextEditingController();
  bool _copied = false;
  bool _sending = false;
  String? _note;
  bool _noteIsError = false;

  bool get _emailLooksValid {
    final text = _email.text.trim();
    return !text.contains(' ') && RegExp(r'^[^@]+@[^@]+$').hasMatch(text);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.link));
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _send() async {
    if (!_emailLooksValid || _sending) return;
    final email = _email.text.trim();
    setState(() {
      _sending = true;
      _note = null;
    });
    try {
      await widget.invite(email);
      if (!mounted) return;
      _email.clear();
      setState(() {
        _sending = false;
        _note = 'Your server is sending the invitation to $email.';
        _noteIsError = false;
      });
    } catch (e) {
      log('rooms: email invitation failed: $e');
      if (!mounted) return;
      setState(() {
        _sending = false;
        _note =
            'Couldn\'t send that. Your server may not allow email '
            'invitations, so copy the link and send it yourself.';
        _noteIsError = true;
      });
    }
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.name),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.hasPassword
                  ? 'Anyone with this link and the password can join, with no '
                        'account. Send the password separately.'
                  : 'Anyone with this link can join, with no account.',
            ),
            const SizedBox(height: 12),
            SelectableText(widget.link),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                icon: Icon(_copied ? Icons.check : Icons.copy),
                label: Text(_copied ? 'Copied' : 'Copy link'),
                onPressed: _copy,
              ),
            ),
            if (widget.canManage) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Or send an invitation by email',
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _emailLooksValid && !_sending ? _send : null,
                    child: const Text('Send'),
                  ),
                ],
              ),
            ],
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _note!,
                  style: _noteIsError ? TextStyle(color: scheme.error) : null,
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.canManage)
          TextButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              if (await widget.turnOff() && mounted) navigator.pop();
            },
            child: Text('Turn off link', style: TextStyle(color: scheme.error)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
