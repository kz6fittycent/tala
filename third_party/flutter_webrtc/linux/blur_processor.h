// Tala: background blur as a libwebrtc video processor. Attached to a camera
// track by FlutterWebRTC's setBackgroundBlur method; the blur itself is in
// background_blur.cc.

#ifndef TALA_BLUR_PROCESSOR_H_
#define TALA_BLUR_PROCESSOR_H_

#include <vector>

#include "background_blur.h"
#include "rtc_video_frame.h"
#include "rtc_video_processor.h"

namespace tala {

class BlurProcessor : public libwebrtc::RTCVideoProcessor {
 public:
  // On the capture thread, one frame at a time.
  libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame> Process(
      libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame> frame) override {
    I420 in;
    in.width = frame->width();
    in.height = frame->height();
    if (in.width < 2 || in.height < 2) return frame;
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
};

}  // namespace tala

#endif  // TALA_BLUR_PROCESSOR_H_
