// Tala: noise cancellation as libwebrtc's capture post-processing, which sees
// the microphone's audio after WebRTC's own echo and noise handling, before
// it's encoded. The work itself is in noise_suppressor.cc.
//
// libwebrtc's adapter calls Initialize on whatever was set before, even
// nullptr, so one processor is set once, for good, and switched on and off
// with SetEnabled. It's never freed: the audio thread may hold it until the
// process ends.

#ifndef TALA_NOISE_PROCESSOR_H_
#define TALA_NOISE_PROCESSOR_H_

#include <atomic>

#include "noise_suppressor.h"
#include "rtc_audio_processing.h"

namespace tala {

class NoiseProcessor : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  // From any thread. A fresh start each time it's switched on, so a new call
  // doesn't begin with the last one's idea of the noise.
  void SetEnabled(bool enabled) {
    if (enabled && !enabled_.load()) reset_.store(true);
    enabled_.store(enabled);
  }

  bool enabled() const { return enabled_.load(); }

  // Whether the audio thread has cleaned anything since it was switched on;
  // false at a rate it can't handle, or if libwebrtc never calls it.
  bool working() const { return working_.load(); }

  void Initialize(int, int) override { reset_.store(true); }

  void Reset(int) override { reset_.store(true); }

  // Called by libwebrtc's audio thread, 10 ms at a time, with the first
  // channel at full rate.
  void Process(int, int num_frames, int, float* buffer) override {
    if (!enabled_.load() || !buffer) return;
    if (reset_.exchange(false)) {
      suppressor_.Reset();
      working_.store(false);
    }
    if (suppressor_.Process(buffer, num_frames)) working_.store(true);
  }

  void Release() override {}

 private:
  NoiseSuppressor suppressor_;
  std::atomic<bool> enabled_{false};
  std::atomic<bool> reset_{true};
  std::atomic<bool> working_{false};
};

}  // namespace tala

#endif  // TALA_NOISE_PROCESSOR_H_
