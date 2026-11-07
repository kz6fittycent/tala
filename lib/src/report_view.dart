import 'dart:convert';

import 'package:flutter/material.dart';

import 'nc_api.dart';
import 'report.dart';

/// Offers "Report a problem", or a report of a crash. Nothing leaves the
/// machine until Send is clicked.
Future<void> showReportDialog(
  BuildContext context, {
  Credentials? creds,
  Crash? crash,
  bool earlier = false,
}) => showDialog<void>(
  context: context,
  // A crash needs an answer, so that it isn't offered again.
  barrierDismissible: crash == null,
  builder: (_) => ReportDialog(creds: creds, crash: crash, earlier: earlier),
);

class ReportDialog extends StatefulWidget {
  const ReportDialog({
    super.key,
    this.creds,
    this.crash,
    this.earlier = false,
    this.facts,
    this.send = sendReport,
  });

  final Credentials? creds;
  final Crash? crash;

  /// The crash was in an earlier session, rather than just now.
  final bool earlier;

  /// Replaces the real checks, for tests.
  final Future<String>? facts;
  final Future<ReportOutcome> Function(Report) send;

  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog> {
  final _description = TextEditingController();
  final _contact = TextEditingController();
  late final Future<String> _facts =
      widget.facts ??
      gatherFacts(
        api: widget.creds == null ? null : NcApi(widget.creds!),
      );
  bool _sending = false;
  ReportOutcome? _outcome;
  String? _preview;

  @override
  void dispose() {
    _description.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<Report> _build() async => buildReport(
    description: _description.text,
    contact: _contact.text,
    facts: await _facts,
    crash: widget.crash,
    creds: widget.creds,
  );

  Future<void> _showPreview() async {
    final report = await _build();
    if (!mounted) return;
    setState(() {
      _preview = const JsonEncoder.withIndent('  ').convert(report.toJson());
    });
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final outcome = await widget.send(await _build());
    if (widget.crash != null) forgetCrash();
    if (!mounted) return;
    setState(() {
      _sending = false;
      _outcome = outcome;
    });
  }

  void _dontSend() {
    if (widget.crash != null) forgetCrash();
    Navigator.of(context).pop();
  }

  String get _title {
    if (widget.crash == null) return 'Report a problem';
    return widget.earlier
        ? 'Tala closed unexpectedly'
        : 'Tala hit an internal error';
  }

  Widget _editing(BuildContext context) {
    final crash = widget.crash;
    final muted = Theme.of(context).textTheme.bodySmall;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            crash == null
                ? 'Something not working right? Say what happened if you '
                      'like, but you don\'t have to: Tala\'s log goes with the '
                      'report and usually shows enough.'
                : '${widget.earlier ? 'Last time it ran, Tala' : 'Tala just'} '
                      'hit a bug (${crash.summary}). Sending a report lets it '
                      'get fixed. If you remember what you were doing, add it '
                      'below.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            maxLines: 5,
            maxLength: maxDescriptionChars,
            decoration: const InputDecoration(
              hintText: 'What were you doing, and what went wrong? (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _contact,
            maxLength: maxContactChars,
            decoration: const InputDecoration(
              hintText: 'A name or email for a reply (optional, public)',
              border: OutlineInputBorder(),
            ),
          ),
          Text(
            'This becomes a public issue on Tala\'s GitHub page, so anyone can '
            'read it. You don\'t need an account. It includes the app version, '
            'your Linux version, what the app could check about your setup, '
            'your server\'s software versions and the recent log. Your server '
            'address, username, room tokens, IP addresses and home folder name '
            'are masked, and Tala\'s log doesn\'t include your messages. You can '
            'read all of it below before sending.',
            style: muted,
          ),
          const SizedBox(height: 4),
          ExpansionTile(
            title: const Text('What gets sent'),
            tilePadding: EdgeInsets.zero,
            onExpansionChanged: (open) {
              if (open) {
                _showPreview();
              } else {
                setState(() => _preview = null);
              }
            },
            children: [
              SizedBox(
                height: 220,
                child: _preview == null
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: SelectableText(
                          _preview!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ({String head, String text}) _result(ReportOutcome o) => switch (o.result) {
    ReportResult.sent => (head: 'Thank you', text: 'Your report was sent.'),
    ReportResult.duplicate => (
      head: 'Thank you',
      text:
          'Your report was sent. Someone already hit this one, so it was added '
          'to the existing report.',
    ),
    ReportResult.failed => (
      head: 'Saved for later',
      text:
          'The report couldn\'t be sent right now, so it was saved. Tala sends '
          'it automatically the next time it starts.',
    ),
    ReportResult.rejected => (
      head: 'Not sent',
      text: 'Sorry, the report couldn\'t be sent: ${o.message ?? 'unknown error'}',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    if (outcome != null) {
      final r = _result(outcome);
      return AlertDialog(
        title: Text(r.head),
        content: Text(r.text),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(width: 540, child: _editing(context)),
      actions: [
        TextButton(
          onPressed: _sending ? null : _dontSend,
          child: Text(widget.crash == null ? 'Cancel' : 'Don\'t send'),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: Text(_sending ? 'Sending…' : 'Send report'),
        ),
      ],
    );
  }
}
