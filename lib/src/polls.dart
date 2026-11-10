import 'package:flutter/material.dart';

import 'chat.dart' show ApiException;
import 'log.dart';

/// A Talk poll, as the server reports it to this user.
class Poll {
  Poll({
    required this.id,
    required this.question,
    required this.options,
    required this.votes,
    required this.voters,
    required this.votedSelf,
    required this.closed,
    required this.hidden,
    required this.maxVotes,
    required this.actorType,
    required this.actorId,
    required this.actorName,
  });

  factory Poll.fromJson(Map<String, dynamic> j) {
    final votes = <int, int>{};
    final raw = j['votes'];
    if (raw is Map) {
      for (final MapEntry(:key, :value) in raw.entries) {
        final i = int.tryParse('$key'.replaceFirst('option-', ''));
        if (i != null && value is int) votes[i] = value;
      }
    }
    return Poll(
      id: j['id'] as int,
      question: j['question'] as String? ?? '',
      options: [
        for (final o in j['options'] as List? ?? const [])
          if (o is String) o,
      ],
      votes: votes,
      voters: j['numVoters'] as int? ?? 0,
      votedSelf: [
        for (final v in j['votedSelf'] as List? ?? const [])
          if (v is int) v,
      ],
      closed: j['status'] == 1,
      hidden: j['resultMode'] == 1,
      maxVotes: j['maxVotes'] as int? ?? 0,
      actorType: j['actorType'] as String? ?? '',
      actorId: j['actorId'] as String? ?? '',
      actorName: j['actorDisplayName'] as String? ?? '',
    );
  }

  final int id;
  final String question;
  final List<String> options;

  /// Votes per option index. Empty while results are hidden from this user.
  final Map<int, int> votes;
  final int voters;
  final List<int> votedSelf;
  final bool closed;

  /// Results only show once the poll is closed.
  final bool hidden;

  /// 0 means any number; 1 means pick one.
  final int maxVotes;
  final String actorType;
  final String actorId;
  final String actorName;

  bool get voted => votedSelf.isNotEmpty;
  int get totalVotes => votes.values.fold(0, (a, b) => a + b);
  bool get showsResults => (voted || closed) && (!hidden || closed);
}

/// What the poll screens need from the server.
class PollSource {
  const PollSource({
    required this.load,
    required this.vote,
    required this.close,
    required this.create,
  });
  final Future<Poll> Function(String token, int pollId) load;
  final Future<Poll> Function(String token, int pollId, List<int> options) vote;
  final Future<Poll> Function(String token, int pollId) close;
  final Future<void> Function(
    String token,
    String question,
    List<String> options, {
    required bool hidden,
    required bool multiple,
  })
  create;
}

/// Opens a poll to vote on it or see how it went.
class PollDialog extends StatefulWidget {
  const PollDialog({
    super.key,
    required this.source,
    required this.token,
    required this.pollId,
    required this.selfId,
    required this.isModerator,
    required this.canVote,
  });
  final PollSource source;
  final String token;
  final int pollId;
  final String selfId;
  final bool isModerator;

  /// False where the user can't post, which also stops voting.
  final bool canVote;

  @override
  State<PollDialog> createState() => _PollDialogState();
}

class _PollDialogState extends State<PollDialog> {
  Poll? _poll;
  String? _error;
  bool _busy = false;
  bool _changing = false;
  final Set<int> _picked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final poll = await widget.source.load(widget.token, widget.pollId);
      if (mounted) setState(() => _poll = poll);
    } catch (e) {
      log('polls: loading failed: $e');
      if (mounted) setState(() => _error = 'Couldn\'t load this poll.');
    }
  }

  Future<void> _run(Future<Poll> Function() action, String failure) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final poll = await action();
      if (!mounted) return;
      setState(() {
        _poll = poll;
        _busy = false;
        _changing = false;
        _picked.clear();
      });
    } catch (e) {
      log('polls: $failure ($e)');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException && e.status == 404
            ? 'This poll no longer exists.'
            : failure;
      });
    }
  }

  void _toggle(Poll poll, int i) => setState(() {
    if (poll.maxVotes == 1) {
      _picked
        ..clear()
        ..add(i);
    } else if (!_picked.remove(i)) {
      if (poll.maxVotes == 0 || _picked.length < poll.maxVotes) _picked.add(i);
    }
  });

  bool _isOwn(Poll p) => p.actorType == 'users' && p.actorId == widget.selfId;

  Widget _ballot(Poll poll) {
    final options = [
      for (final (i, option) in poll.options.indexed)
        poll.maxVotes == 1
            ? RadioListTile<int>(
                value: i,
                enabled: !_busy,
                title: Text(option),
                contentPadding: EdgeInsets.zero,
              )
            : CheckboxListTile(
                value: _picked.contains(i),
                onChanged: _busy ? null : (_) => _toggle(poll, i),
                title: Text(option),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
    ];
    final column = Column(mainAxisSize: MainAxisSize.min, children: options);
    if (poll.maxVotes != 1) return column;
    return RadioGroup<int>(
      groupValue: _picked.firstOrNull,
      onChanged: (i) {
        if (i != null) _toggle(poll, i);
      },
      child: column,
    );
  }

  Widget _results(Poll poll) {
    final theme = Theme.of(context);
    final total = poll.totalVotes;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, option) in poll.options.indexed) ...[
          Row(
            children: [
              if (poll.votedSelf.contains(i))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.check_circle,
                    size: 16,
                    color: theme.colorScheme.primary,
                    semanticLabel: 'Your vote',
                  ),
                ),
              Expanded(child: Text(option)),
              Text('${poll.votes[i] ?? 0}'),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: total == 0 ? 0 : (poll.votes[i] ?? 0) / total,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final poll = _poll;
    final theme = Theme.of(context);
    if (poll == null) {
      return AlertDialog(
        title: const Text('Poll'),
        content: _error != null
            ? Text(_error!)
            : const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final voting =
        !poll.closed && widget.canVote && (!poll.voted || _changing);
    final canEnd = !poll.closed && (_isOwn(poll) || widget.isModerator);
    final status = [
      if (poll.closed) 'Closed' else 'Open',
      '${poll.voters} ${poll.voters == 1 ? 'voter' : 'voters'}',
      if (poll.actorName.isNotEmpty) 'by ${poll.actorName}',
    ].join(' · ');
    return AlertDialog(
      title: Text(poll.question),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              if (voting)
                _ballot(poll)
              else if (poll.showsResults)
                _results(poll)
              else
                Text(
                  poll.voted
                      ? 'Thanks for voting. Results show when the poll closes.'
                      : 'Results show when the poll closes.',
                ),
              if (voting && poll.maxVotes > 1)
                Text(
                  'Pick up to ${poll.maxVotes}.',
                  style: theme.textTheme.bodySmall,
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (canEnd)
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => widget.source.close(widget.token, poll.id),
                    'Couldn\'t end the poll.',
                  ),
            child: const Text('End poll'),
          ),
        if (!voting && poll.voted && !poll.closed && widget.canVote)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _changing = true;
                    _picked
                      ..clear()
                      ..addAll(poll.votedSelf);
                  }),
            child: const Text('Change vote'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (voting)
          FilledButton(
            onPressed: _busy || _picked.isEmpty
                ? null
                : () => _run(
                    () => widget.source.vote(
                      widget.token,
                      poll.id,
                      _picked.toList()..sort(),
                    ),
                    'Couldn\'t send your vote.',
                  ),
            child: const Text('Vote'),
          ),
      ],
    );
  }
}

/// Talk's limits on a poll's question and options.
const _questionLimit = 32000;
const _maxOptions = 20;

/// Asks a question with two or more answers. Closes with true once posted.
class CreatePollDialog extends StatefulWidget {
  const CreatePollDialog({super.key, required this.create});
  final Future<void> Function(
    String question,
    List<String> options, {
    required bool hidden,
    required bool multiple,
  })
  create;

  @override
  State<CreatePollDialog> createState() => _CreatePollDialogState();
}

class _CreatePollDialogState extends State<CreatePollDialog> {
  final TextEditingController _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _hidden = false;
  bool _multiple = false;
  bool _busy = false;
  String? _error;

  List<String> get _filled => [
    for (final o in _options)
      if (o.text.trim().isNotEmpty) o.text.trim(),
  ];

  bool get _canPost =>
      !_busy && _question.text.trim().isNotEmpty && _filled.length >= 2;

  Future<void> _post() async {
    if (!_canPost) return;
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.create(
        _question.text.trim(),
        _filled,
        hidden: _hidden,
        multiple: _multiple,
      );
      navigator.pop(true);
    } catch (e) {
      log('polls: creating failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException && e.status == 400
            ? 'This conversation doesn\'t take polls.'
            : 'Couldn\'t post the poll.';
      });
    }
  }

  @override
  void dispose() {
    _question.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New poll'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _question,
              autofocus: true,
              enabled: !_busy,
              maxLength: _questionLimit,
              decoration: const InputDecoration(
                labelText: 'Question',
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            for (final (i, o) in _options.indexed)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: o,
                      enabled: !_busy,
                      decoration: InputDecoration(labelText: 'Answer ${i + 1}'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (_options.length > 2)
                    IconButton(
                      tooltip: 'Remove answer ${i + 1}',
                      icon: const Icon(Icons.close),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _options.removeAt(i).dispose()),
                    ),
                ],
              ),
            if (_options.length < _maxOptions)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add an answer'),
                  onPressed: _busy
                      ? null
                      : () => setState(
                          () => _options.add(TextEditingController()),
                        ),
                ),
              ),
            CheckboxListTile(
              value: _multiple,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _multiple = v ?? false),
              title: const Text('Allow more than one answer'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: _hidden,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _hidden = v ?? false),
              title: const Text('Hide results until the poll ends'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _canPost ? _post : null,
        child: const Text('Post'),
      ),
    ],
  );
}
