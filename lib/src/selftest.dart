import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'log.dart';

/// Loops the camera and mic through two local peer connections and exits 0 if
/// frames arrive. Nothing leaves this machine.
class SelfTest extends StatefulWidget {
  const SelfTest({super.key});
  @override
  State<SelfTest> createState() => _SelfTestState();
}

class _SelfTestState extends State<SelfTest> {
  final _renderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    var code = 1;
    try {
      await _renderer.initialize();
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'width': 640, 'height': 480},
      });
      log('selftest: tracks ${stream.getTracks().map((t) => t.kind).toList()}');
      final a = await createPeerConnection({'sdpSemantics': 'unified-plan'});
      final b = await createPeerConnection({'sdpSemantics': 'unified-plan'});
      a.onIceCandidate = (c) => b.addCandidate(c);
      b.onIceCandidate = (c) => a.addCandidate(c);
      b.onTrack = (e) {
        if (e.track.kind == 'video' && e.streams.isNotEmpty) {
          setState(() => _renderer.srcObject = e.streams.first);
        }
      };
      for (final t in stream.getTracks()) {
        await a.addTrack(t, stream);
      }
      final offer = await a.createOffer({});
      await a.setLocalDescription(offer);
      await b.setRemoteDescription(offer);
      final answer = await b.createAnswer({});
      await b.setLocalDescription(answer);
      await a.setRemoteDescription(answer);

      await Future<void>.delayed(const Duration(seconds: 8));
      num frames = 0, audioBytes = 0;
      for (final r in await b.getStats()) {
        if (r.type == 'inbound-rtp') {
          final kind = r.values['kind'] ?? r.values['mediaType'];
          if (kind == 'video') frames = r.values['framesDecoded'] ?? 0;
          if (kind == 'audio') audioBytes = r.values['bytesReceived'] ?? 0;
        }
      }
      log('selftest: decoded frames=$frames audioBytes=$audioBytes '
          'renderer=${_renderer.videoWidth}x${_renderer.videoHeight}');
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await a.close();
      await b.close();
      code = frames > 0 && audioBytes > 0 && _renderer.videoWidth > 0 ? 0 : 1;
    } catch (e) {
      log('selftest: failed: $e');
    }
    log('selftest: ${code == 0 ? 'PASS' : 'FAIL'}');
    exit(code);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      home: Scaffold(backgroundColor: Colors.black, body: RTCVideoView(_renderer)));
}
