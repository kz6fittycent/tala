// Blurs everything but the person in camera frames.
//
// Works on I420 planes and knows nothing of WebRTC, so it builds and can be
// checked on its own (tool/blur/check_blur.py); flutter_webrtc.cc wraps it in
// an RTCVideoProcessor.

#ifndef TALA_BACKGROUND_BLUR_H_
#define TALA_BACKGROUND_BLUR_H_

#include <cstdint>
#include <vector>

#include "selfie_segmenter.h"

namespace tala {

struct I420 {
  int width = 0, height = 0;
  const uint8_t* y = nullptr;
  const uint8_t* u = nullptr;
  const uint8_t* v = nullptr;
  int stride_y = 0, stride_u = 0, stride_v = 0;
};

class BackgroundBlur {
 public:
  // Blurs `in` into the planes of `out_y`, `out_u` and `out_v`, which are
  // tightly packed: width by height, then twice (width+1)/2 by (height+1)/2.
  // Call from one thread at a time.
  void Apply(const I420& in, uint8_t* out_y, uint8_t* out_u, uint8_t* out_v);

 private:
  void Segment(const I420& in);

  SelfieSegmenter segmenter_;
  std::vector<float> rgb_;
  // The person mask at the model's size, smoothed over frames; refined_
  // is it fitted to the picture's edges at the guide's size.
  std::vector<float> mask_;
  int mask_width_ = 0, mask_height_ = 0;  // frame size mask_ belongs to
  std::vector<float> guide_, refined_, weight_;
  std::vector<float> small_[3];
  std::vector<float> scratch_;
};

}  // namespace tala

#endif  // TALA_BACKGROUND_BLUR_H_
