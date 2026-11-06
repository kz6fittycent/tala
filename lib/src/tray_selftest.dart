import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'log.dart';
import 'tray.dart';

/// Hides and reshows the window, checking that Dart keeps running while hidden
/// and that drawing resumes afterward. Run with `tala --tray-selftest`.
class TraySelfTest extends StatefulWidget {
  const TraySelfTest({super.key});
  @override
  State<TraySelfTest> createState() => _TraySelfTestState();
}

class _TraySelfTestState extends State<TraySelfTest> {
  final AppTray _tray = AppTray();
  int _ticks = 0;
  int _frames = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPersistentFrameCallback((_) => _frames++);
    Timer.periodic(const Duration(milliseconds: 100), (_) {
      _ticks++;
      if (mounted) setState(() {});
    });
    unawaited(_run());
  }

  Future<void> _run() async {
    const wait = Duration(seconds: 3);
    await Future<void>.delayed(wait);
    log('tray test: visible, frames $_frames, ticks $_ticks');
    final framesBefore = _frames;
    await _tray.hide();
    final ticksAtHide = _ticks;
    await Future<void>.delayed(wait);
    final ranHidden = _ticks - ticksAtHide;
    log('tray test: hidden, ticks while hidden $ranHidden, '
        'frames while hidden ${_frames - framesBefore}');
    final framesAtShow = _frames;
    await _tray.show();
    await Future<void>.delayed(wait);
    final drew = _frames - framesAtShow;
    log('tray test: shown again, frames since $drew');
    final ok = ranHidden > 10 && drew > 10;
    log('tray test: ${ok ? 'PASSED' : 'FAILED'}');
    exit(ok ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(body: Center(child: Text('Tray test $_ticks'))),
      );
}
