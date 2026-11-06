class ChatNote {
  const ChatNote(this.id, this.token, this.title, this.body);
  final int id;
  final String token;
  final String title;
  final String body;
}

/// Decides what to do with the server's chat notifications. The server already
/// applied the user's notification settings, so nothing is filtered by content.
class ChatAlerts {
  ChatAlerts({
    required this.isViewing,
    required this.show,
    required this.hide,
    required this.dismiss,
  });

  /// True when the user is looking at this conversation right now.
  final bool Function(String token) isViewing;
  final void Function(ChatNote note) show;

  /// Removes this conversation's desktop popup.
  final void Function(String token) hide;

  /// Clears the notification on the server, and so on the user's other devices.
  final void Function(int id) dismiss;

  Map<int, ChatNote> _known = {};
  bool _baseline = true;

  void update(List<ChatNote> notes) {
    final next = {for (final n in notes) n.id: n};
    if (_baseline) {
      // Old notifications were already seen elsewhere, so startup stays quiet.
      _baseline = false;
      _known = next;
      return;
    }
    for (final n in notes) {
      if (_known.containsKey(n.id)) continue;
      if (isViewing(n.token)) {
        dismiss(n.id);
      } else {
        show(n);
      }
    }
    final stillThere = next.values.map((n) => n.token).toSet();
    for (final n in _known.values) {
      if (!stillThere.contains(n.token)) hide(n.token);
    }
    _known = next;
  }

  void conversationRead(String token) {
    hide(token);
    for (final n in _known.values) {
      if (n.token == token) dismiss(n.id);
    }
  }
}
