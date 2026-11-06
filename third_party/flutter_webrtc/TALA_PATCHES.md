# Tala patches to flutter_webrtc 1.6.3

Only the camera start in `common/cpp/src/flutter_media_stream.cc` and its header. `getUserMedia` opened the camera on the UI thread; on a Logitech QuickCam 3000 libwebrtc's 195 format probes took about 8s, which froze the window past GNOME's 5s "not responding" limit. The slow part now runs on a worker.

To upgrade: copy the new release here, reapply this change, or drop this directory if upstream fixes it. Worth offering upstream.

The prebuilt libwebrtc isn't committed. CMake downloads it at the version in `third_party/libwebrtc_version.ini` and doesn't verify it. Linux x64 zip for libwebrtc.m150.7871.07, sha256 `ef380526cf9616848bc0b97b24990cbf2ad851c209d5dce93cc3ebb9d3789fbc`.
