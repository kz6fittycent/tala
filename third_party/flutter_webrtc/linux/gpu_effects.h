// Background blur, pictures and touch up on the GPU, through OpenGL ES 3 on a
// window-less EGL context. The person model still runs on the CPU
// (BackgroundBlur::Segment); everything after the mask runs here, the same
// steps and numbers as background_blur.cc, so the pictures match.
//
// Standard EGL and GL ES only, reached through libepoxy (already a GTK
// dependency), so it's the same code on NVIDIA's driver and on Mesa. Create
// refuses software renderers, missing features and shaders that don't build;
// BackgroundBlur then stays on the CPU.

#ifndef TALA_GPU_EFFECTS_H_
#define TALA_GPU_EFFECTS_H_

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "background_blur.h"

namespace tala {

class GpuEffects {
 public:
  // A context on a hardware GPU, or null with the reason in `why`. Leaves no
  // context current on the calling thread.
  static std::unique_ptr<GpuEffects> Create(std::string* why);
  ~GpuEffects();
  GpuEffects(const GpuEffects&) = delete;
  GpuEffects& operator=(const GpuEffects&) = delete;

  // The GPU's name, as its driver gives it.
  const std::string& renderer() const { return renderer_; }

  struct Look {
    // The person mask at the model's size, already smoothed over frames.
    const float* mask = nullptr;
    int mask_width = 0, mask_height = 0;
    // The picture fitted to the frame (Y at frame size, U and V at chroma
    // size, values 0 to 255), or null to blur or leave the background.
    const std::vector<float>* picture = nullptr;
    // Changes whenever the picture's contents do, so it's sent again.
    int picture_version = 0;
    bool blur = true;
    float touch_up = 0;
  };

  // Does to `in` what BackgroundBlur::Apply does, into tightly packed planes.
  // From one thread at a time, which may change between calls. False on any
  // GL error, leaving the output unfinished.
  bool Apply(const I420& in, const Look& look, uint8_t* out_y, uint8_t* out_u,
             uint8_t* out_v);

  // The context and its textures; in gpu_effects.cc.
  struct Impl;

 private:
  GpuEffects() = default;
  std::unique_ptr<Impl> impl_;
  std::string renderer_;
};

}  // namespace tala

#endif  // TALA_GPU_EFFECTS_H_
