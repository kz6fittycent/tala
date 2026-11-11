// Finds the person in a camera picture, for background blur.
//
// Runs MediaPipe's landscape selfie segmenter (Apache License 2.0, Google)
// with a small engine of Tala's own: the model is a fixed list of about a
// dozen kinds of layer, so no inference library is needed. The model's layers
// and weights are generated into selfie_model_data.inc by
// tool/blur/export_selfie_model.py. Nothing here depends on WebRTC or GTK, so
// it builds and can be checked on its own (tool/blur/check_segmenter.sh).

#ifndef TALA_SELFIE_SEGMENTER_H_
#define TALA_SELFIE_SEGMENTER_H_

#include <vector>

namespace tala {

class SelfieSegmenter {
 public:
  static constexpr int kWidth = 256;
  static constexpr int kHeight = 144;

  SelfieSegmenter();

  // `rgb` is kHeight rows of kWidth pixels, each red, green and blue from 0
  // to 1. Returns kHeight * kWidth values from 0 (background) to 1 (person),
  // valid until the next call.
  const float* Run(const float* rgb);

 private:
  std::vector<std::vector<float>> values_;
};

}  // namespace tala

#endif  // TALA_SELFIE_SEGMENTER_H_
