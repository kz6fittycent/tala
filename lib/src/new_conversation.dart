import 'dart:async';

import 'package:flutter/material.dart';

import 'log.dart';
import 'nc_api.dart';

/// A search field with its results. Put it in a [Flexible] inside a column.
class PeopleSearch extends StatefulWidget {
  const PeopleSearch({
    super.key,
    required this.search,
    required this.onPick,
    this.label = 'Search for a person',
    this.exclude = const {},
    this.clearOnPick = false,
    this.autofocus = true,
  });
  final Future<List<Person>> Function(String query) search;
  final ValueChanged<Person> onPick;
  final String label;

  /// User ids not to offer, such as people already chosen.
  final Set<String> exclude;

  /// For picking several people in a row.
  final bool clearOnPick;
  final bool autofocus;

  @override
  State<PeopleSearch> createState() => _PeopleSearchState();
}

class _PeopleSearchState extends State<PeopleSearch> {
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

  void _pick(Person person) {
    if (widget.clearOnPick) {
      _query.clear();
      _changed('');
    }
    widget.onPick(person);
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
    final people = [
      ...?_people?.where((p) => !widget.exclude.contains(p.id)),
    ];
    final String? message = _failed
        ? 'Couldn\'t search. Check your connection and try again.'
        : _people == null
        ? null
        : people.isEmpty
        ? 'No one found.'
        : null;
    if (message != null) {
      return Padding(padding: const EdgeInsets.all(24), child: Text(message));
    }
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
          onTap: () => _pick(people[i]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _query,
        autofocus: widget.autofocus,
        decoration: InputDecoration(labelText: widget.label),
        onChanged: _changed,
      ),
      _results(),
    ],
  );
}

/// Finds someone on the server. Closes with the person chosen, or null.
class NewConversationDialog extends StatelessWidget {
  const NewConversationDialog({
    super.key,
    required this.search,
    this.onInviteGuest,
    this.onNewGroup,
  });
  final Future<List<Person>> Function(String query) search;

  /// Called after closing, to invite someone who has no account.
  final VoidCallback? onInviteGuest;

  /// Called after closing, to create a group instead.
  final VoidCallback? onNewGroup;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New conversation'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: PeopleSearch(
              search: search,
              onPick: (person) => Navigator.of(context).pop(person),
            ),
          ),
          if (onNewGroup != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('New group'),
              subtitle: const Text('A named conversation with several people'),
              onTap: () {
                Navigator.of(context).pop();
                onNewGroup!();
              },
            ),
          if (onInviteGuest != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: const Text('Invite someone without an account'),
              subtitle: const Text('Create a conversation with a link'),
              onTap: () {
                Navigator.of(context).pop();
                onInviteGuest!();
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
