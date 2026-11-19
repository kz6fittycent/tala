// Takes background noise (keyboards, fans, dogs, other voices further off)
// out of the microphone, with Xiph's RNNoise (third_party/rnnoise).
//
// Knows nothing of WebRTC, so it builds and can be checked on its own
// (tool/noise/check_noise.py); noise_processor.h hands it libwebrtc's capture
// audio.

#ifndef TALA_NOISE_SUPPRESSOR_H_
#define TALA_NOISE_SUPPRESSOR_H_

struct DenoiseState;

namespace tala {

class NoiseSuppressor {
 public:
  NoiseSuppressor();
  ~NoiseSuppressor();
  NoiseSuppressor(const NoiseSuppressor&) = delete;
  NoiseSuppressor& operator=(const NoiseSuppressor&) = delete;

  // Cleans 10 ms of mono audio in place: `count` samples, scaled as 16-bit
  // (-32768 to 32767), as libwebrtc's audio buffers are. RNNoise works at
  // 48 kHz (480 samples); 16 and 32 kHz are stretched to it and back.
  // Returns false, leaving the audio as it was, for any other size.
  bool Process(float* samples, int count);

  // Forgets earlier audio, for a new call or a new rate.
  void Reset();

 private:
  DenoiseState* state_ = nullptr;
  float out_[480];
  float last_ = 0;  // the previous frame's last sample, below 48 kHz
};

}  // namespace tala

#endif  // TALA_NOISE_SUPPRESSOR_H_
