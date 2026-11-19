#include "noise_suppressor.h"

#include <algorithm>

#include "rnnoise.h"

namespace tala {
namespace {

constexpr int kFrame = 480;  // RNNoise's 10 ms at 48 kHz

// Linear interpolation of `p` (n long) at position `pos`, clamped to its ends.
float At(const float* p, int n, float pos) {
  if (pos <= 0) return p[0];
  if (pos >= n - 1) return p[n - 1];
  const int i = static_cast<int>(pos);
  return p[i] + (p[i + 1] - p[i]) * (pos - i);
}

}  // namespace

NoiseSuppressor::NoiseSuppressor()
    : state_(rnnoise_create(nullptr)) {}

NoiseSuppressor::~NoiseSuppressor() { rnnoise_destroy(state_); }

void NoiseSuppressor::Reset() {
  if (state_) rnnoise_init(state_, nullptr);
  last_ = 0;
}

bool NoiseSuppressor::Process(float* samples, int count) {
  if (!state_) return false;
  if (count == kFrame) {
    rnnoise_process_frame(state_, out_, samples);
    std::copy(out_, out_ + kFrame, samples);
    return true;
  }
  if (count != 160 && count != 320) return false;
  // Stretched to 48 kHz by straight lines between samples. The previous
  // frame's last sample goes first, so each frame joins the one before, at
  // the cost of one sample's delay.
  float joined[321];
  joined[0] = last_;
  std::copy(samples, samples + count, joined + 1);
  last_ = samples[count - 1];
  const float step = static_cast<float>(count) / kFrame;
  float stretched[kFrame];
  for (int i = 0; i < kFrame; i++) {
    stretched[i] = At(joined, count + 1, i * step);
  }
  rnnoise_process_frame(state_, out_, stretched);
  // And back: what's above the lower rate's limit was never there, so
  // sampling the cleaned audio again needs no filter first.
  for (int j = 0; j < count; j++) samples[j] = At(out_, kFrame, j / step);
  return true;
}

}  // namespace tala
