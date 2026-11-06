import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'log.dart';

/// Frame times, in milliseconds. A frame is slow if it misses 30 frames a second.
class FrameStats {
  static const slowMs = 33.0;
  final List<double> _build = [];
  final List<double> _raster = [];

  int get count => _build.length;
  int get slow {
    var n = 0;
    for (var i = 0; i < count; i++) {
      if (_build[i] + _raster[i] > slowMs) n++;
    }
    return n;
  }

  void add(double buildMs, double rasterMs) {
    _build.add(buildMs);
    _raster.add(rasterMs);
  }

  void clear() {
    _build.clear();
    _raster.clear();
  }

  @visibleForTesting
  static double percentile(List<double> values, double p) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    return sorted[min(sorted.length - 1, (sorted.length * p).floor())];
  }

  String summary() {
    String part(String name, List<double> v) => '$name '
        'p50 ${percentile(v, .5).toStringAsFixed(1)} '
        'p99 ${percentile(v, .99).toStringAsFixed(1)} '
        'worst ${percentile(v, 1).toStringAsFixed(1)} ms';
    return '$count frames, $slow slow, ${part('build', _build)}, '
        '${part('raster', _raster)}';
  }

  void addAll(List<FrameTiming> timings) {
    for (final t in timings) {
      add(
        t.buildDuration.inMicroseconds / 1000,
        t.rasterDuration.inMicroseconds / 1000,
      );
    }
  }
}

/// Logs a line for any minute that had slow frames, so lag shows up in log.txt.
void startFrameLog() {
  final stats = FrameStats();
  SchedulerBinding.instance.addTimingsCallback(stats.addAll);
  Timer.periodic(const Duration(minutes: 1), (_) {
    if (stats.slow > 0) log('frames: ${stats.summary()}');
    stats.clear();
  });
}

/// `--frame-check`: scrolls a list for 10 seconds and logs the frame rate and
/// times, for comparing builds on one machine.
class FrameCheck extends StatefulWidget {
  const FrameCheck({super.key, required this.done});
  final VoidCallback done;
  @override
  State<FrameCheck> createState() => _FrameCheckState();
}

class _FrameCheckState extends State<FrameCheck> {
  static const _warmUp = Duration(seconds: 2);
  static const _measure = Duration(seconds: 10);
  final ScrollController _scroll = ScrollController();
  final FrameStats _stats = FrameStats();

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_stats.addAll);
    _run();
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    unawaited(_scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: _warmUp + _measure + const Duration(seconds: 2),
      curve: Curves.linear,
    ));
    await Future<void>.delayed(_warmUp);
    _stats.clear();
    await Future<void>.delayed(_measure);
    final fps = _stats.count / _measure.inSeconds;
    log('frame check: ${fps.toStringAsFixed(1)} fps, ${_stats.summary()}');
    widget.done();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: _scroll,
            itemCount: 2000,
            itemBuilder: (_, i) => ListTile(
              leading: CircleAvatar(child: Text('${i % 10}')),
              title: Text('Conversation $i'),
              subtitle: const Text('The quick brown fox jumps over the lazy dog'),
            ),
          ),
        ),
      );
}
