#ifndef PLUGINS_FLUTTER_WEBRTC_HXX
#define PLUGINS_FLUTTER_WEBRTC_HXX

#include "flutter_common.h"

#include "flutter_data_channel.h"
#include "flutter_data_packet_cryptor.h"
#include "flutter_frame_cryptor.h"
#include "flutter_media_stream.h"
#include "flutter_peerconnection.h"
#include "flutter_screen_capture.h"
#include "flutter_video_renderer.h"

#include "libwebrtc.h"
#include "rtc_logging.h"

#ifdef __linux__
#include <map>
#include <memory>

#include "blur_processor.h"
#endif

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class FlutterWebRTCPlugin : public flutter::Plugin {
 public:
  virtual BinaryMessenger* messenger() = 0;

  virtual TextureRegistrar* textures() = 0;

  virtual TaskRunner* task_runner() = 0;
};

class FlutterWebRTC : public FlutterWebRTCBase,
                      public FlutterVideoRendererManager,
                      public FlutterMediaStream,
                      public FlutterPeerConnection,
                      public FlutterScreenCapture,
                      public FlutterDataChannel,
                      public FlutterFrameCryptor,
                      public FlutterDataPacketCryptor {
 public:
  FlutterWebRTC(FlutterWebRTCPlugin* plugin);
  virtual ~FlutterWebRTC();

  void HandleMethodCall(const MethodCallProxy& method_call,
                        std::unique_ptr<MethodResultProxy> result);

 private:
  void initLoggerCallback(RTCLoggingSeverity severity);
  RTCLoggingSeverity str2LogSeverity(std::string str);

#ifdef __linux__
  // Tala: blurs the background of a local camera track, or stops. Returns
  // whether the track is now blurred. Platform thread.
  bool SetBackgroundBlur(const std::string& track_id, bool enabled);

  // Blur processors by track id. A disposed track's processor is already
  // detached by FlutterWebRTCBase, so stale entries are only freed here.
  std::map<std::string, std::unique_ptr<tala::BlurProcessor>> blurs_;
#endif
};

}  // namespace flutter_webrtc_plugin

#endif  // PLUGINS_FLUTTER_WEBRTC_HXX
