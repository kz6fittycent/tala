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

/// Arranges a call. Without [chat], the other people fill the space and the
/// user's own camera floats in the corner. With it, they share the space with
/// a narrow column holding the user's camera above the chat.
class CallLayout extends StatelessWidget {
  const CallLayout({
    super.key,
    required this.others,
    required this.self,
    required this.controls,
    this.chat,
  });

  final Widget others;
  final Widget self;
  final Widget controls;
  final Widget? chat;

  Widget _video({Size? corner}) => Stack(
    fit: StackFit.expand,
    children: [
      others,
      if (corner != null)
        Positioned(
          right: 16,
          top: 16,
          width: corner.width,
          height: corner.height,
          child: self,
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
