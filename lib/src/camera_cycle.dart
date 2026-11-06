import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'log.dart';

/// Repeats the open, show, close sequence a call goes through, to reproduce
/// crashes when the camera is reopened. Nothing leaves this machine.
class CameraCycle extends StatefulWidget {
  const CameraCycle({super.key});
  @override
  State<CameraCycle> createState() => _CameraCycleState();
}

class _CameraCycleState extends State<CameraCycle> {
  RTCVideoRenderer? _renderer;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _timeOne(String label, Map<String, dynamic> c) async {
    final sw = Stopwatch()..start();
    var last = sw.elapsedMilliseconds, worst = 0;
    final tick = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final now = sw.elapsedMilliseconds;
      if (now - last > worst) worst = now - last;
      last = now;
    });
    final stream = await navigator.mediaDevices.getUserMedia(c);
    tick.cancel();
    log('timing $label: ${sw.elapsedMilliseconds}ms, '
        'longest UI stall ${worst}ms');
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  }

  Future<void> _run() async {
    await _timeOne('audio only', {'audio': true, 'video': false});
    await _timeOne('video only', {
      'audio': false,
      'video': {'width': 1280, 'height': 720, 'frameRate': 30},
    });
    await _timeOne('audio only again', {'audio': true, 'video': false});
    if (Platform.environment['TALA_TIMING_ONLY'] != null) exit(0);
    for (var i = 1; i <= 6; i++) {
      final sw = Stopwatch()..start();
      final r = RTCVideoRenderer();
      await r.initialize();
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'width': 1280, 'height': 720, 'frameRate': 30},
      });
      log('cycle $i: media open after ${sw.elapsedMilliseconds}ms');
      r.srcObject = stream;
      setState(() => _renderer = r);

      // Same shape as a call: publish with a data channel, then subscribe.
      final a = await createPeerConnection({'sdpSemantics': 'unified-plan'});
      final b = await createPeerConnection({'sdpSemantics': 'unified-plan'});
      a.onIceCandidate = (c) => b.addCandidate(c);
      b.onIceCandidate = (c) => a.addCandidate(c);
      for (final t in stream.getTracks()) {
        await a.addTrack(t, stream);
      }
      final channel = await a.createDataChannel('status', RTCDataChannelInit());
      channel.onDataChannelState = (st) {
        if (st == RTCDataChannelState.RTCDataChannelOpen) {
          channel.send(RTCDataChannelMessage('{"type":"audioOn"}'));
        }
      };
      final offer = await a.createOffer({});
      await a.setLocalDescription(offer);
      await b.setRemoteDescription(offer);
      final answer = await b.createAnswer({});
      await b.setLocalDescription(answer);
      await a.setRemoteDescription(answer);
      await Future<void>.delayed(const Duration(seconds: 4));
      await b.close();
      await a.close();
      log('cycle $i: peer connections closed');
      log('cycle $i: renderer ${r.videoWidth}x${r.videoHeight}');
      setState(() => _renderer = null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
      await r.dispose();
      log('cycle $i: closed');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    log('cycle: PASS');
    exit(0);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      home: Scaffold(
          backgroundColor: Colors.black,
          body: _renderer == null ? null : RTCVideoView(_renderer!)));
}
