// Tala: background blur, or a picture behind the person, as a libwebrtc video
// processor. Attached to a camera track by FlutterWebRTC's setBackgroundBlur
// method; the work itself is in background_blur.cc.

#ifndef TALA_BLUR_PROCESSOR_H_
#define TALA_BLUR_PROCESSOR_H_

#include <mutex>
#include <utility>
#include <vector>

#include "background_blur.h"
#include "rtc_video_frame.h"
#include "rtc_video_processor.h"

namespace tala {

class BlurProcessor : public libwebrtc::RTCVideoProcessor {
 public:
  // From any thread: the picture to show behind the person from the next
  // frame on (see BackgroundBlur::SetPicture), or empty to blur.
  void SetPicture(std::vector<uint8_t> rgba, int width, int height) {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_ = std::move(rgba);
    pending_width_ = width;
    pending_height_ = height;
    has_pending_ = true;
  }

  // On the capture thread, one frame at a time.
  libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame> Process(
      libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame> frame) override {
    I420 in;
    in.width = frame->width();
    in.height = frame->height();
    if (in.width < 2 || in.height < 2) return frame;
    {
      std::lock_guard<std::mutex> lock(pending_mutex_);
      if (has_pending_) {
        blur_.SetPicture(pending_, pending_width_, pending_height_);
        std::vector<uint8_t>().swap(pending_);
        has_pending_ = false;
      }
    }
    in.y = frame->DataY();
    in.u = frame->DataU();
    in.v = frame->DataV();
    in.stride_y = frame->StrideY();
    in.stride_u = frame->StrideU();
    in.stride_v = frame->StrideV();
    const int cw = (in.width + 1) / 2, ch = (in.height + 1) / 2;
    const size_t ys = static_cast<size_t>(in.width) * in.height;
    const size_t cs = static_cast<size_t>(cw) * ch;
    out_.resize(ys + 2 * cs);
    blur_.Apply(in, out_.data(), out_.data() + ys, out_.data() + ys + cs);
    // Create copies the planes, so out_ is free for the next frame.
    return libwebrtc::RTCVideoFrame::Create(
        in.width, in.height, out_.data(), in.width, out_.data() + ys, cw,
        out_.data() + ys + cs, cw);
  }

 private:
  BackgroundBlur blur_;
  std::vector<uint8_t> out_;
  std::mutex pending_mutex_;
  std::vector<uint8_t> pending_;
  int pending_width_ = 0, pending_height_ = 0;
  bool has_pending_ = false;
};

}  // namespace tala

#endif  // TALA_BLUR_PROCESSOR_H_
