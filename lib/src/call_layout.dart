import 'dart:math';

import 'package:flutter/material.dart';

/// Columns and rows for [count] videos, wider than tall on a tie.
(int, int) gridShape(int count) {
  if (count <= 0) return (0, 0);
  final columns = sqrt(count).ceil();
  return (columns, (count / columns).ceil());
}

/// Below this width, chat goes under the video instead of beside it.
const callSideBySideWidth = 760.0;
const _callChatWidth = 340.0;

/// How the people in a call are shown: whoever is speaking large with the
/// rest in a row below, or everyone the same size. Stored by name.
enum PeopleView {
  speaker('Speaker'),
  grid('Grid');

  const PeopleView(this.label);
  final String label;

  static PeopleView fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => grid);
}

/// How a shared screen is shown: with people in a row below, beside it in a
/// column, or alone. Stored by name.
enum ScreenView {
  below('People below the screen'),
  beside('People beside the screen'),
  only('Screen only');

  const ScreenView(this.label);
  final String label;

  static ScreenView fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => below);
}

/// One person's video, with what's drawn over it.
class StageTile {
  const StageTile({
    required this.id,
    required this.video,
    this.name,
    this.speaking = false,
  });

  /// Stable while they're in the call.
  final String id;
  final Widget video;
  final String? name;
  final bool speaking;
}

/// Arranges a call. Without [chat], the other people fill the space and the
/// user's own camera floats in the corner. With it, they share the space with
/// a narrow column holding the user's camera above the chat. Without [self],
/// the user's own camera isn't shown at all.
class CallLayout extends StatelessWidget {
  const CallLayout({
    super.key,
    required this.others,
    required this.self,
    required this.controls,
    this.chat,
  });

  final Widget others;
  final Widget? self;
  final Widget controls;
  final Widget? chat;

  Widget _video({Size? corner}) => Stack(
    fit: StackFit.expand,
    children: [
      others,
      if (corner != null && self != null)
        Positioned(
          right: 16,
          top: 16,
          width: corner.width,
          height: corner.height,
          child: self!,
        ),
      Positioned(left: 0, right: 0, bottom: 12, child: controls),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final chat = this.chat;
    if (chat == null) return _video(corner: const Size(240, 135));
    final panel = Material(child: chat);
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < callSideBySideWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 2, child: _video(corner: const Size(128, 72))),
              Expanded(flex: 3, child: panel),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _video()),
            SizedBox(
              width: _callChatWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (self != null)
                    AspectRatio(aspectRatio: 16 / 9, child: self),
                  Expanded(child: panel),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Shares all the space it's given between its children, leaving no gaps. One
/// child gets everything, and a short last row stretches to the full width.
class FillGrid extends StatelessWidget {
  const FillGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final (columns, rows) = gridShape(children.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var row = 0; row < rows; row++)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final child in children.skip(row * columns).take(columns))
                  Expanded(child: child),
              ],
            ),
          ),
      ],
    );
  }
}

/// Height of the row of people under a shared screen or the speaker, and the
/// space left below it for the call's controls.
const screenStripHeight = 96.0;
const screenControlsSpace = 76.0;

/// Width of the column of people beside a shared screen.
const screenColumnWidth = 220.0;

/// A video with the person's name in the corner and, when [highlight], a
/// frame while they speak. Tapping it calls [onTap].
class TileFrame extends StatelessWidget {
  const TileFrame({
    super.key,
    required this.tile,
    this.highlight = true,
    this.pinned = false,
    this.onTap,
    this.tapHint,
  });

  final StageTile tile;
  final bool highlight;
  final bool pinned;
  final VoidCallback? onTap;
  final String? tapHint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = tile.name;
    Widget result = Stack(
      fit: StackFit.expand,
      children: [
        tile.video,
        if (name != null || pinned)
          Positioned(
            left: 6,
            bottom: 6,
            right: 6,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pinned)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.push_pin, size: 12,
                            color: Colors.white),
                      ),
                    if (name != null)
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        if (highlight && tile.speaking)
          IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('speaking'),
              decoration: BoxDecoration(
                border: Border.all(color: scheme.primary, width: 3),
              ),
            ),
          ),
      ],
    );
    if (onTap != null) {
      result = Tooltip(
        message: tapHint ?? '',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: result,
        ),
      );
    }
    return Semantics(
      label: name,
      button: onTap != null,
      child: result,
    );
  }
}

/// The person [PeopleStage] shows large in speaker view: the pinned one if
/// they're still here, else whoever is speaking, else the first.
String? focusOf(List<StageTile> people, {String? pinned, String? speaker}) {
  if (people.isEmpty) return null;
  bool here(String? id) => id != null && people.any((p) => p.id == id);
  if (here(pinned)) return pinned;
  if (here(speaker)) return speaker;
  return people.first.id;
}

/// A scrolling row (or column) of small 16:9 tiles.
class _Strip extends StatelessWidget {
  const _Strip({
    required this.tiles,
    required this.axis,
    this.onTap,
  });
  final List<StageTile> tiles;
  final Axis axis;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) => ListView(
    scrollDirection: axis,
    padding: axis == Axis.horizontal
        ? const EdgeInsets.only(top: 4)
        : const EdgeInsets.only(left: 4),
    children: [
      for (final t in tiles)
        Padding(
          key: ValueKey(t.id),
          padding: axis == Axis.horizontal
              ? const EdgeInsets.only(right: 4)
              : const EdgeInsets.only(bottom: 4),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: TileFrame(
              tile: t,
              onTap: onTap == null ? null : () => onTap!(t.id),
              tapHint: 'Keep ${t.name ?? 'them'} in focus',
            ),
          ),
        ),
    ],
  );
}

/// The people in a call, in [view]. In speaker view one person fills the
/// space and the rest sit in a row below; tapping one there pins them
/// ([onPin] with their id), and tapping the pinned one lets go ([onPin] with
/// null).
class PeopleStage extends StatelessWidget {
  const PeopleStage({
    super.key,
    required this.people,
    this.view = PeopleView.grid,
    this.speaker,
    this.pinned,
    this.onPin,
  });

  final List<StageTile> people;
  final PeopleView view;
  final String? speaker;
  final String? pinned;
  final ValueChanged<String?>? onPin;

  @override
  Widget build(BuildContext context) {
    // Alone with one other person, both views are the same.
    if (view == PeopleView.grid || people.length < 2) {
      return FillGrid(children: [
        for (final p in people)
          TileFrame(key: ValueKey(p.id), tile: p, highlight: people.length > 1),
      ]);
    }
    final focus = focusOf(people, pinned: pinned, speaker: speaker);
    final main = people.firstWhere((p) => p.id == focus);
    final isPinned = main.id == pinned;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: TileFrame(
            key: ValueKey(main.id),
            tile: main,
            highlight: false,
            pinned: isPinned,
            onTap: isPinned && onPin != null ? () => onPin!(null) : null,
            tapHint: 'Stop keeping ${main.name ?? 'them'} in focus',
          ),
        ),
        SizedBox(
          height: screenStripHeight,
          child: _Strip(
            tiles: [for (final p in people) if (p.id != main.id) p],
            axis: Axis.horizontal,
            onTap: onPin,
          ),
        ),
        const SizedBox(height: screenControlsSpace),
      ],
    );
  }
}

/// A shared screen is shown whole, never cropped, because its detail is the
/// point. People's videos go in a row beneath it, a column beside it, or
/// nowhere, by [screenView]. With no screen, people are shown as [peopleView]
/// says.
class ScreenStage extends StatelessWidget {
  const ScreenStage({
    super.key,
    required this.screens,
    required this.people,
    this.peopleView = PeopleView.grid,
    this.screenView = ScreenView.below,
    this.speaker,
    this.pinned,
    this.onPin,
  });
  final List<Widget> screens;
  final List<StageTile> people;
  final PeopleView peopleView;
  final ScreenView screenView;
  final String? speaker;
  final String? pinned;
  final ValueChanged<String?>? onPin;

  @override
  Widget build(BuildContext context) {
    if (screens.isEmpty) {
      return PeopleStage(
        people: people,
        view: peopleView,
        speaker: speaker,
        pinned: pinned,
        onPin: onPin,
      );
    }
    final screen = FillGrid(children: screens);
    final showPeople = people.isNotEmpty && screenView != ScreenView.only;
    if (showPeople && screenView == ScreenView.beside) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: screen),
                SizedBox(
                  width: screenColumnWidth,
                  child: _Strip(tiles: people, axis: Axis.vertical),
                ),
              ],
            ),
          ),
          const SizedBox(height: screenControlsSpace),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: screen),
        if (showPeople)
          SizedBox(
            height: screenStripHeight,
            child: _Strip(tiles: people, axis: Axis.horizontal),
          ),
        const SizedBox(height: screenControlsSpace),
      ],
    );
  }
}

/// Says the user's screen is going out to the call, with a way to stop.
class SharingBanner extends StatelessWidget {
  const SharingBanner({super.key, required this.onStop});
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.screen_share, color: colors.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'You\'re sharing your screen',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onPrimaryContainer),
              ),
            ),
            FilledButton(onPressed: onStop, child: const Text('Stop sharing')),
          ],
        ),
      ),
    );
  }
}
