import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'call_layout.dart';
import 'settings.dart';

/// The row of buttons under a call: microphone, noise cancellation, camera,
/// background, screen sharing, view, chat and hang up. Shrinks rather than
/// overflows in a narrow window.
class CallControls extends StatelessWidget {
  const CallControls({
    super.key,
    required this.settings,
    required this.micOn,
    required this.noiseCancel,
    required this.camOn,
    required this.effectsOn,
    required this.sharing,
    required this.choosingScreen,
    required this.unread,
    required this.onMic,
    required this.onNoiseCancel,
    required this.onCamera,
    required this.onBackground,
    required this.onScreen,
    required this.onViewChanged,
    required this.onChat,
    required this.onHangUp,
  });

  /// Holds the view choices and whether the chat is open.
  final AppSettings settings;
  final bool micOn;
  final bool noiseCancel;
  final bool camOn;

  /// A background or touch up is on.
  final bool effectsOn;
  final bool sharing;

  /// The desktop's screen picker is open.
  final bool choosingScreen;

  /// Unread messages in the call's conversation.
  final ValueListenable<int> unread;
  final VoidCallback onMic;
  final VoidCallback onNoiseCancel;
  final VoidCallback onCamera;
  final VoidCallback onBackground;
  final VoidCallback onScreen;

  /// After a view choice is saved in [settings].
  final VoidCallback onViewChanged;
  final VoidCallback onChat;
  final VoidCallback onHangUp;

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(width: 12);
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filled(
              tooltip: micOn ? 'Mute' : 'Unmute',
              icon: Icon(micOn ? Icons.mic : Icons.mic_off),
              onPressed: onMic,
            ),
            gap,
            IconButton.filled(
              tooltip: noiseCancel
                  ? 'Noise cancellation is on'
                  : 'Noise cancellation is off',
              isSelected: noiseCancel,
              icon: const Icon(Icons.noise_control_off),
              selectedIcon: const Icon(Icons.noise_aware),
              onPressed: onNoiseCancel,
            ),
            gap,
            IconButton.filled(
              tooltip: camOn ? 'Turn camera off' : 'Turn camera on',
              icon: Icon(camOn ? Icons.videocam : Icons.videocam_off),
              onPressed: onCamera,
            ),
            gap,
            IconButton.filled(
              tooltip: 'Background and touch up',
              isSelected: effectsOn,
              icon: const Icon(Icons.wallpaper_outlined),
              selectedIcon: const Icon(Icons.wallpaper),
              onPressed: camOn ? onBackground : null,
            ),
            gap,
            IconButton.filled(
              tooltip: choosingScreen
                  ? 'Choose what to share in the system\'s window'
                  : sharing
                  ? 'Stop sharing your screen'
                  : 'Share your screen',
              icon: Icon(sharing ? Icons.stop_screen_share : Icons.screen_share),
              onPressed: choosingScreen ? null : onScreen,
            ),
            gap,
            CallViewMenu(settings: settings, onChanged: onViewChanged),
            gap,
            ValueListenableBuilder(
              valueListenable: unread,
              builder: (context, unread, _) {
                final open = settings.callChatOpen;
                final waiting = !open && unread > 0;
                return IconButton.filled(
                  tooltip: open
                      ? 'Hide chat'
                      : waiting
                      ? 'Show chat ($unread unread)'
                      : 'Show chat',
                  icon: Badge(
                    isLabelVisible: waiting,
                    label: Text('$unread'),
                    child: Icon(open ? Icons.chat : Icons.chat_outlined),
                  ),
                  onPressed: onChat,
                );
              },
            ),
            gap,
            IconButton.filled(
              tooltip: 'Hang up',
              style: IconButton.styleFrom(backgroundColor: Colors.red),
              icon: const Icon(Icons.call_end),
              onPressed: onHangUp,
            ),
          ],
        ),
      ),
    );
  }
}

/// The call's View button: speaker or grid, how a shared screen sits with
/// people, and whether the user's own camera shows. Choices go straight into
/// [settings]; [onChanged] follows.
class CallViewMenu extends StatelessWidget {
  const CallViewMenu({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final AppSettings settings;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      for (final v in PeopleView.values)
        RadioMenuButton<PeopleView>(
          value: v,
          groupValue: settings.callPeopleView,
          onChanged: (v) {
            settings.callPeopleView = v!;
            onChanged();
          },
          child: Text(v.label),
        ),
      const Divider(),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Text(
          'While a screen is shared',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
      for (final v in ScreenView.values)
        RadioMenuButton<ScreenView>(
          value: v,
          groupValue: settings.callScreenView,
          onChanged: (v) {
            settings.callScreenView = v!;
            onChanged();
          },
          child: Text(v.label),
        ),
      const Divider(),
      CheckboxMenuButton(
        value: settings.callHideSelf,
        onChanged: (v) {
          settings.callHideSelf = v!;
          onChanged();
        },
        child: const Text('Hide my own video'),
      ),
    ],
    builder: (context, menu, _) => IconButton.filled(
      tooltip: 'View',
      icon: Icon(
        settings.callPeopleView == PeopleView.speaker
            ? Icons.view_agenda_outlined
            : Icons.grid_view,
      ),
      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
    ),
  );
}
