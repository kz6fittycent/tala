import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'avatars.dart';
import 'chat.dart' show ApiException;
import 'log.dart';
import 'nc_api.dart';
import 'new_conversation.dart';

const _nameLimit = 255;

/// What creating a group produced. The group exists even if someone couldn't
/// be added, so that's reported rather than treated as a failure.
class NewGroup {
  NewGroup(this.token, this.notAdded);
  final String token;
  final List<Person> notAdded;
}

/// Names a group and picks its first members, who can also be added later.
class NewGroupDialog extends StatefulWidget {
  const NewGroupDialog({
    super.key,
    required this.search,
    required this.create,
    required this.add,
  });
  final Future<List<Person>> Function(String query) search;
  final Future<String> Function(String name) create;
  final Future<void> Function(String token, String userId) add;

  @override
  State<NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<NewGroupDialog> {
  final TextEditingController _name = TextEditingController();
  final List<Person> _people = [];
  bool _busy = false;
  String? _error;

  Future<void> _create() async {
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final String token;
    try {
      token = await widget.create(_name.text.trim());
    } catch (e) {
      log('groups: creating failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException && e.status == 403
            ? 'This server doesn\'t let you create conversations.'
            : 'Couldn\'t create the group. Check your connection and try '
                  'again.';
      });
      return;
    }
    final notAdded = <Person>[];
    for (final person in _people) {
      try {
        await widget.add(token, person.id);
      } catch (e) {
        log('groups: adding a member failed: $e');
        notAdded.add(person);
      }
    }
    navigator.pop(NewGroup(token, notAdded));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('New group'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              enabled: !_busy,
              maxLength: _nameLimit,
              decoration: const InputDecoration(
                labelText: 'Group name',
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
            ),
            // Scrolls, so a long list of people can't push the dialog off screen.
            if (_people.isNotEmpty)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final person in _people)
                          InputChip(
                            label: Text(person.name),
                            deleteButtonTooltipMessage:
                                'Remove ${person.name}',
                            onDeleted: _busy
                                ? null
                                : () => setState(() => _people.remove(person)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            if (!_busy)
              Flexible(
                child: PeopleSearch(
                  search: widget.search,
                  label: 'Add people',
                  autofocus: false,
                  clearOnPick: true,
                  exclude: {for (final p in _people) p.id},
                  onPick: (person) => setState(() => _people.add(person)),
                ),
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
          onPressed: _busy || _name.text.trim().isEmpty ? null : _create,
          child: Text(_busy ? 'Creating…' : 'Create'),
        ),
      ],
    ),
  );
}

/// Lists who's in a conversation. Moderators can also change who's in it.
class MembersDialog extends StatefulWidget {
  const MembersDialog({
    super.key,
    required this.name,
    required this.selfId,
    required this.canManage,
    required this.load,
    required this.search,
    required this.add,
    required this.remove,
    required this.setModerator,
    this.avatars,
  });
  final AvatarStore? avatars;
  final String name;
  final String selfId;
  final bool canManage;
  final Future<List<Member>> Function() load;
  final Future<List<Person>> Function(String query) search;
  final Future<void> Function(String userId) add;
  final Future<void> Function(int attendeeId) remove;
  final Future<void> Function(int attendeeId, bool moderator) setModerator;

  @override
  State<MembersDialog> createState() => _MembersDialogState();
}

class _MembersDialogState extends State<MembersDialog> {
  List<Member>? _members;
  bool _loadFailed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final members = await widget.load();
      members.sort((a, b) {
        if (a.isModerator != b.isModerator) return a.isModerator ? -1 : 1;
        return a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        );
      });
      if (!mounted) return;
      setState(() {
        _members = members;
        _loadFailed = false;
      });
    } catch (e) {
      log('groups: loading members failed: $e');
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  /// The server decides, so its list is reloaded after every change.
  Future<void> _change(
    Future<void> Function() action,
    String failure,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } catch (e) {
      log('groups: changing members failed: $e');
      if (mounted) {
        _error = e is ApiException && e.status == 403
            ? 'Only moderators can do that, and an owner can\'t be changed.'
            : e is ApiException && e.status == 400
            ? 'The server refused that. A conversation needs a moderator, and '
                  'moderators may need demoting before they can be removed.'
            : failure;
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  bool _isSelf(Member m) => m.actorType == 'users' && m.actorId == widget.selfId;

  Future<void> _confirmRemove(Member m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${m.displayName}?'),
        content: Text(
          m.isGuest
              ? 'They lose access to ${widget.name}.'
              : 'They lose access to ${widget.name} until someone adds them '
                    'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _change(
      () => widget.remove(m.attendeeId),
      'Couldn\'t remove ${m.displayName}.',
    );
  }

  Widget? _actions(Member m) {
    if (!widget.canManage || _isSelf(m) || m.isOwner) return null;
    return PopupMenuButton<String>(
      tooltip: 'Options for ${m.displayName}',
      enabled: !_busy,
      onSelected: (choice) {
        if (choice == 'remove') {
          _confirmRemove(m);
        } else {
          _change(
            () => widget.setModerator(m.attendeeId, !m.isModerator),
            'Couldn\'t change ${m.displayName}.',
          );
        }
      },
      itemBuilder: (_) => [
        if (m.canBeModerator)
          PopupMenuItem(
            value: 'moderator',
            child: Text(m.isModerator ? 'Remove as moderator' : 'Make moderator'),
          ),
        const PopupMenuItem(value: 'remove', child: Text('Remove…')),
      ],
    );
  }

  Widget _list() {
    final members = _members;
    if (members == null) {
      return Center(
        child: _loadFailed
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Couldn\'t load the members.'),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _load, child: const Text('Try again')),
                ],
              )
            : const CircularProgressIndicator(),
      );
    }
    return ListView.builder(
      itemCount: members.length,
      itemBuilder: (context, i) {
        final m = members[i];
        final details = [if (_isSelf(m)) 'You', if (m.role.isNotEmpty) m.role];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Avatar(
            name: m.displayName,
            image: m.actorType == 'users'
                ? widget.avatars?.forUser(m.actorId)
                : null,
          ),
          title: Text(
            m.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: details.isEmpty ? null : Text(details.join(' · ')),
          trailing: _actions(m),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = _members?.length;
    return AlertDialog(
      title: Text(
        count == null ? widget.name : '${widget.name} ($count)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 420,
        height: 460,
        // A cap rather than Flexible, which would hold half the height for an
        // empty search and take it from the list.
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.canManage)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.min(200, box.maxHeight / 2),
                  ),
                  child: PeopleSearch(
                    search: widget.search,
                    label: 'Add someone',
                    autofocus: false,
                    clearOnPick: true,
                    exclude: {
                      for (final m in _members ?? const <Member>[])
                        if (m.actorType == 'users') m.actorId,
                    },
                    onPick: (person) => _change(
                      () => widget.add(person.id),
                      'Couldn\'t add ${person.name}.',
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(child: _list()),
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
    );
  }
}

/// Closes with true once the server has accepted the new name.
class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.name, required this.rename});
  final String name;
  final Future<void> Function(String name) rename;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.name,
  );
  bool _busy = false;
  String? _error;

  bool get _canSave {
    final name = _name.text.trim();
    return !_busy && name.isNotEmpty && name != widget.name;
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.rename(_name.text.trim());
      navigator.pop(true);
    } catch (e) {
      log('groups: renaming failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Couldn\'t rename this conversation.';
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename conversation'),
    content: SizedBox(
      width: 420,
      child: TextField(
        controller: _name,
        autofocus: true,
        enabled: !_busy,
        maxLength: _nameLimit,
        decoration: InputDecoration(
          labelText: 'Name',
          counterText: '',
          errorText: _error,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _canSave ? _save : null,
        child: const Text('Save'),
      ),
    ],
  );
}
