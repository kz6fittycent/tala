import 'dart:async';

import 'package:flutter/material.dart';

import 'log.dart';
import 'nc_api.dart';

/// Finds someone on the server. Closes with the person chosen, or null.
class NewConversationDialog extends StatefulWidget {
  const NewConversationDialog({
    super.key,
    required this.search,
    this.onInviteGuest,
  });
  final Future<List<Person>> Function(String query) search;

  /// Called after closing, to invite someone who has no account.
  final VoidCallback? onInviteGuest;

  @override
  State<NewConversationDialog> createState() => _NewConversationDialogState();
}

class _NewConversationDialogState extends State<NewConversationDialog> {
  static const _pause = Duration(milliseconds: 300);

  final TextEditingController _query = TextEditingController();
  Timer? _timer;
  List<Person>? _people;
  bool _searching = false;
  bool _failed = false;

  /// Only the newest search may show its results.
  int _latest = 0;

  void _changed(String text) {
    _timer?.cancel();
    final query = text.trim();
    final search = ++_latest;
    if (query.isEmpty) {
      setState(() {
        _people = null;
        _searching = false;
        _failed = false;
      });
      return;
    }
    setState(() => _searching = true);
    _timer = Timer(_pause, () => _run(query, search));
  }

  Future<void> _run(String query, int search) async {
    try {
      final people = await widget.search(query);
      if (!mounted || search != _latest) return;
      setState(() {
        _people = people;
        _searching = false;
        _failed = false;
      });
    } catch (e) {
      log('people search failed: $e');
      if (!mounted || search != _latest) return;
      setState(() {
        _searching = false;
        _failed = true;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    super.dispose();
  }

  Widget _results() {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final String? message = _failed
        ? 'Couldn\'t search. Check your connection and try again.'
        : _people == null
        ? null
        : _people!.isEmpty
        ? 'No one found.'
        : null;
    if (message != null) {
      return Padding(padding: const EdgeInsets.all(24), child: Text(message));
    }
    final people = _people ?? const <Person>[];
    return Flexible(
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: people.length,
        itemBuilder: (context, i) => ListTile(
          title: Text(
            people[i].name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: people[i].detail.isEmpty
              ? null
              : Text(
                  people[i].detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          onTap: () => Navigator.of(context).pop(people[i]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New conversation'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _query,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Search for a person'),
            onChanged: _changed,
          ),
          _results(),
          if (widget.onInviteGuest != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: const Text('Invite someone without an account'),
              subtitle: const Text('Create a conversation with a link'),
              onTap: () {
                Navigator.of(context).pop();
                widget.onInviteGuest!();
              },
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
    ],
  );
}
