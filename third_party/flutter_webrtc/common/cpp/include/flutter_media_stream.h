#ifndef FLUTTER_WEBRTC_RTC_GET_USERMEDIA_HXX
#define FLUTTER_WEBRTC_RTC_GET_USERMEDIA_HXX

#include <functional>
#include <memory>

#include "flutter_common.h"
#include "flutter_webrtc_base.h"

namespace flutter_webrtc_plugin {

class FlutterMediaStream {
 public:
  FlutterMediaStream(FlutterWebRTCBase* base);

  void GetUserMedia(const EncodableMap& constraints,
                    std::unique_ptr<MethodResultProxy> result);

  void GetUserAudio(const EncodableMap& constraints,
                    scoped_refptr<RTCMediaStream> stream,
                    EncodableMap& params);

  void GetUserVideo(const EncodableMap& constraints,
                    scoped_refptr<RTCMediaStream> stream,
                    std::shared_ptr<EncodableMap> params,
                    std::function<void()> done);

  void FinishUserVideo(scoped_refptr<RTCVideoCapturer> video_capturer,
                       std::string sourceId,
                       int32_t width,
                       int32_t height,
                       int32_t fps,
                       const EncodableMap& video_constraints,
                       scoped_refptr<RTCMediaStream> stream,
                       EncodableMap& params);

  void GetSources(std::unique_ptr<MethodResultProxy> result);

  void SelectAudioOutput(const std::string& device_id,
                         std::unique_ptr<MethodResultProxy> result);

  void SelectAudioInput(const std::string& device_id,
                        std::unique_ptr<MethodResultProxy> result);

  void MediaStreamGetTracks(const std::string& stream_id,
                            std::unique_ptr<MethodResultProxy> result);

  void MediaStreamDispose(const std::string& stream_id,
                          std::unique_ptr<MethodResultProxy> result);

  void MediaStreamTrackSetEnable(const std::string& track_id,
                                 std::unique_ptr<MethodResultProxy> result);

  void MediaStreamTrackSwitchCamera(const std::string& track_id,
                                    std::unique_ptr<MethodResultProxy> result);

  void MediaStreamTrackDispose(const std::string& track_id,
                               std::unique_ptr<MethodResultProxy> result);

  void CreateLocalMediaStream(std::unique_ptr<MethodResultProxy> result);

  void OnDeviceChange();

 private:
  FlutterWebRTCBase* base_;
};

}  // namespace flutter_webrtc_plugin

#endif  // !FLUTTER_WEBRTC_RTC_GET_USERMEDIA_HXX
