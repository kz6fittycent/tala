import 'dart:math';

import 'package:flutter/widgets.dart';

/// Columns and rows for [count] videos, wider than tall on a tie.
(int, int) gridShape(int count) {
  if (count <= 0) return (0, 0);
  final columns = sqrt(count).ceil();
  return (columns, (count / columns).ceil());
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
