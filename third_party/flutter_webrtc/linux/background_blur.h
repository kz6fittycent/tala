// Blurs everything but the person in camera frames, or puts a picture
// behind them instead, and can touch up their skin.
//
// Works on I420 planes and knows nothing of WebRTC, so it builds and can be
// checked on its own (tool/blur/check_blur.py); flutter_webrtc.cc wraps it in
// an RTCVideoProcessor.

#ifndef TALA_BACKGROUND_BLUR_H_
#define TALA_BACKGROUND_BLUR_H_

#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
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

class GpuEffects;

class BackgroundBlur {
 public:
  BackgroundBlur();
  ~BackgroundBlur();

  // Blurs `in` into the planes of `out_y`, `out_u` and `out_v`, which are
  // tightly packed: width by height, then twice (width+1)/2 by (height+1)/2.
  // Call from one thread at a time.
  //
  // The person model runs here; the rest runs on the GPU when there's a
  // usable one (gpu_effects.h). Each kind of look is first done both ways
  // on one frame, and the GPU is only used if it gave the same picture; it's
  // dropped for good if it errs or turns out slower than this code.
  void Apply(const I420& in, uint8_t* out_y, uint8_t* out_u, uint8_t* out_v);

  // Whether the GPU may be tried. Before the first Apply.
  void SetGpuAllowed(bool allowed) {
    gpu_allowed_ = allowed;
    if (!allowed) SetEngine("cpu: GPU not allowed");
  }

  // What's doing the work, for the log: "gpu: <its name>", or "cpu" with
  // why the GPU isn't in use. From any thread.
  std::string Engine() const;

  // Shows `rgba` (width by height, 4 bytes a pixel, rows packed) behind the
  // person instead of blurring, filling the frame and cropped to its shape.
  // An empty picture goes back to blurring. Same thread as Apply.
  void SetPicture(const std::vector<uint8_t>& rgba, int width, int height);

  // Whether the background is blurred when there's no picture (otherwise
  // it's left alone), and how much to smooth the person's skin, from 0 (not
  // at all) to 1. Same thread as Apply.
  void SetLook(bool blur, float touch_up) {
    blur_ = blur;
    touch_up_ = touch_up < 0 ? 0 : touch_up > 1 ? 1 : touch_up;
  }

  // The shortest time between runs of the person model; frames in between
  // reuse its last mask. 25 ms runs it on every frame at 30 fps and every
  // other at 60. Zero runs it every frame (for timing checks).
  void SetModelGap(std::chrono::milliseconds gap) { model_gap_ = gap; }

 private:
  void Segment(const I420& in);
  // Everything after the model, here on the CPU.
  void ApplyCpu(const I420& in, uint8_t* out_y, uint8_t* out_u, uint8_t* out_v);
  // The same on the GPU if it's in use; false if the CPU should do it.
  bool ApplyGpu(const I420& in, uint8_t* out_y, uint8_t* out_u, uint8_t* out_v);
  // Stops using the GPU for good.
  void DropGpu(const std::string& why);
  void SetEngine(const std::string& engine);
  // Smooths fine detail on the person's skin into touched_ (width by height,
  // rows packed), using guide_ and refined_ at the guide's size.
  void TouchUp(const I420& in, int gw, int gh);
  // Scales the picture to cover a frame of this size, into picture_scaled_.
  void FitPicture(int width, int height);

  SelfieSegmenter segmenter_;
  std::vector<float> rgb_;
  // The person mask at the model's size, smoothed over frames; refined_
  // is it fitted to the picture's edges at the guide's size.
  std::vector<float> mask_;
  int mask_width_ = 0, mask_height_ = 0;  // frame size mask_ belongs to
  std::vector<float> guide_, refined_;
  // Per plane, as the planes are blurred side by side.
  std::vector<float> small_[3], weight_[3], scratch_planes_[3];
  // The picture in Y, U and V at its own size, all three full resolution;
  // empty when blurring.
  std::vector<float> picture_[3];
  int picture_width_ = 0, picture_height_ = 0;
  // picture_ fitted to the frame: Y at frame size, U and V at chroma size.
  std::vector<float> picture_scaled_[3];
  int scaled_width_ = 0, scaled_height_ = 0;  // frame size they belong to
  std::chrono::steady_clock::time_point last_model_;
  std::chrono::steady_clock::duration model_gap_ = std::chrono::milliseconds(25);
  bool blur_ = true;
  float touch_up_ = 0;
  std::vector<float> smooth_;
  std::vector<uint8_t> touched_;

  bool gpu_allowed_ = true;
  bool gpu_tried_ = false;
  std::unique_ptr<GpuEffects> gpu_;
  int picture_version_ = 0;  // changes with the picture, for the GPU's copy
  unsigned gpu_checked_ = 0;  // looks checked against the CPU, one bit each
  double cpu_ms_ = 0;         // the CPU's time on the last check
  int gpu_frames_ = 0;
  double gpu_ms_ = 0;
  std::vector<uint8_t> check_;
  mutable std::mutex engine_mutex_;
  std::string engine_ = "cpu: not started";
};

}  // namespace tala

#endif  // TALA_BACKGROUND_BLUR_H_
