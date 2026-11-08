# Tala patches to flutter_webrtc 1.6.3

Three changes: the camera start in `common/cpp/src/flutter_media_stream.cc` and its header, libwebrtc checksum verification in `third_party/CMakeLists.txt`, and screen sharing through the portal (its own section below). `getUserMedia` opened the camera on the UI thread; on a Logitech QuickCam 3000 libwebrtc's 195 format probes took about 8s, which froze the window past GNOME's 5s "not responding" limit. The slow part now runs on a worker.

To upgrade: copy the new release here, reapply this change, or drop this directory if upstream fixes it. Worth offering upstream.

The prebuilt libwebrtc isn't committed. CMake downloads it at the version in `third_party/libwebrtc_version.ini` and checks the Linux x64 zip against `sha256_linux_x64` there, stopping the build on a mismatch. To upgrade libwebrtc, change the version and the checksum together. The build still fails if that release disappears from GitHub.

## Screen sharing through the portal (Linux)

libwebrtc's own desktop capture opens two portal sessions for one share (two pickers) and tells Dart neither when the user cancels nor when the share ends. Tala does the portal and PipeWire part itself instead:

- `linux/portal_screencast.{h,cc}`: one `org.freedesktop.portal.ScreenCast` session per share (CreateSession, SelectSources for screens and windows, Start, OpenPipeWireRemote), then a PipeWire stream of BGRx/RGBx shared-memory buffers converted to I420. The last picture is sent again each second while nothing changes, so someone who starts watching later gets one. Closing the object closes the session.
- `common/cpp/src/flutter_screen_capture.cc` and its header: `GetPortalDisplayMedia` makes a stream with a custom video source fed by the capture and returns it in `getDisplayMedia`'s shape; `StopPortalDisplayMedia` ends it. Outcomes go out on the event channel as `{"event": "portalScreenCast", "streamId", "state": "sharing|cancelled|stopped|failed"}`.
- `common/cpp/src/flutter_webrtc.cc`: the `getPortalDisplayMedia` and `stopPortalDisplayMedia` methods, Linux only.
- `lib/flutter_webrtc.dart`: exports `FlutterWebRTCEventChannel` and `MediaStreamNative` for the Dart side (`lib/src/screen_share.dart` in Tala).
- `linux/CMakeLists.txt`: builds it, linking `libpipewire-0.3` and `gio-unix-2.0` through pkg-config. Building needs `libpipewire-0.3-dev`.

Worth offering upstream: it fixes the two-picker problem for every Linux user of the plugin.
