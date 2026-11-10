import 'package:flutter/material.dart';

/// A fixed choice of common emoji, drawn by the system's emoji font. Not every
/// emoji there is: a full list with search would need a data package, and
/// the official clients' recent reactions cover most use.
const emojiGroups = <(String, IconData, List<String>)>[
  ('Smileys', Icons.emoji_emotions_outlined, [
    '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊',
    '😇', '🥰', '😍', '🤩', '😘', '😋', '😛', '😜', '🤪', '🤗', '🤭', '🤫',
    '🤔', '🤐', '🤨', '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '😌', '😔',
    '😪', '😴', '😷', '🤒', '🤯', '🥳', '😎', '🤓', '🧐', '😕', '😟', '😮',
    '😯', '😲', '😳', '🥺', '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱',
    '😖', '😣', '😞', '😓', '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '💀',
  ]),
  ('People', Icons.waving_hand_outlined, [
    '👍', '👎', '👌', '✌️', '🤞', '🤟', '🤘', '🤙', '👈', '👉', '👆', '👇',
    '☝️', '✋', '🤚', '🖐️', '👋', '👏', '🙌', '👐', '🤲', '🤝', '🙏', '✍️',
    '💪', '🫶', '👀', '🧠', '🫡', '🤷', '🤦', '🙋', '🙇', '💁', '🙆', '🙅',
  ]),
  ('Hearts', Icons.favorite_border, [
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🤎', '🖤', '🤍', '💔', '❣️', '💕',
    '💞', '💓', '💗', '💖', '💘', '💝', '💯', '💢', '💥', '💫', '💦', '💤',
  ]),
  ('Nature', Icons.local_florist_outlined, [
    '🐶', '🐱', '🐭', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷',
    '🐸', '🐵', '🐔', '🐧', '🐦', '🦆', '🦉', '🐝', '🦋', '🐢', '🐍', '🐙',
    '🌸', '🌻', '🌹', '🌷', '🌱', '🌲', '🍀', '🍁', '🌈', '☀️', '⛅', '🌧️',
    '❄️', '⚡', '🔥', '🌊', '⭐', '🌙',
  ]),
  ('Food', Icons.restaurant_outlined, [
    '🍎', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍒', '🍑', '🥑', '🌽', '🥕',
    '🍞', '🧀', '🥚', '🍳', '🥓', '🍔', '🍟', '🍕', '🌮', '🍝', '🍣', '🍰',
    '🎂', '🍪', '🍫', '🍿', '☕', '🍵', '🍺', '🍷', '🥂', '🍾', '🧃', '🥤',
  ]),
  ('Things', Icons.lightbulb_outline, [
    '🎉', '🎊', '🎈', '🎁', '🏆', '🥇', '⚽', '🏀', '🎮', '🎲', '🎵', '🎶',
    '🎤', '🎧', '📷', '💻', '📱', '⌚', '💡', '📌', '📎', '✏️', '📝', '📅',
    '📈', '📉', '🔒', '🔑', '🔔', '🔕', '⏰', '⌛', '🚀', '✈️', '🚗', '🏠',
    '✅', '❌', '❓', '❗', '⚠️', '🚫', '➕', '➖', '🆗', '🆒', '🆕', '🔝',
  ]),
];

/// Returns the chosen emoji, or null if the user closed the picker.
Future<String?> showEmojiPicker(BuildContext context) =>
    showDialog<String>(context: context, builder: (_) => const _EmojiPicker());

class _EmojiPicker extends StatelessWidget {
  const _EmojiPicker();

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 440),
      child: DefaultTabController(
        length: emojiGroups.length,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final (name, icon, _) in emojiGroups)
                  Tab(icon: Icon(icon, semanticLabel: name)),
              ],
            ),
            Flexible(
              child: TabBarView(
                children: [
                  for (final (_, _, emoji) in emojiGroups)
                    GridView.extent(
                      maxCrossAxisExtent: 48,
                      padding: const EdgeInsets.all(8),
                      children: [
                        for (final e in emoji)
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => Navigator.of(context).pop(e),
                            child: Center(
                              child: Text(
                                e,
                                style: const TextStyle(fontSize: 24),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
