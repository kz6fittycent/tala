# Tala patches to flutter_webrtc 1.6.3

Two changes: the camera start in `common/cpp/src/flutter_media_stream.cc` and its header, and libwebrtc checksum verification in `third_party/CMakeLists.txt`. `getUserMedia` opened the camera on the UI thread; on a Logitech QuickCam 3000 libwebrtc's 195 format probes took about 8s, which froze the window past GNOME's 5s "not responding" limit. The slow part now runs on a worker.

To upgrade: copy the new release here, reapply this change, or drop this directory if upstream fixes it. Worth offering upstream.

The prebuilt libwebrtc isn't committed. CMake downloads it at the version in `third_party/libwebrtc_version.ini` and checks the Linux x64 zip against `sha256_linux_x64` there, stopping the build on a mismatch. To upgrade libwebrtc, change the version and the checksum together. The build still fails if that release disappears from GitHub.
