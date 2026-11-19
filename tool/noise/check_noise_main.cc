// Runs Tala's noise suppressor over raw audio for check_noise.py:
//   check_noise_main <rate> <in.f32> <out.f32>
// Both files are mono float samples scaled as 16-bit, fed through in 10 ms
// pieces as libwebrtc does. Prints the time per piece.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "noise_suppressor.h"

int main(int argc, char** argv) {
  if (argc < 4) return 2;
  const int n = std::atoi(argv[1]) / 100;
  FILE* f = std::fopen(argv[2], "rb");
  if (!f) return 1;
  std::vector<float> audio;
  float s;
  while (std::fread(&s, sizeof s, 1, f) == 1) audio.push_back(s);
  std::fclose(f);
  audio.resize(audio.size() / n * n);
  tala::NoiseSuppressor ns;
  const auto start = std::chrono::steady_clock::now();
  for (size_t i = 0; i < audio.size(); i += n) {
    if (!ns.Process(&audio[i], n)) return 3;
  }
  const double ms = std::chrono::duration<double, std::milli>(
                        std::chrono::steady_clock::now() - start)
                        .count();
  std::printf("%d Hz: %.3f ms per 10 ms\n", n * 100, ms / (audio.size() / n));
  f = std::fopen(argv[3], "wb");
  std::fwrite(audio.data(), sizeof(float), audio.size(), f);
  std::fclose(f);
  return 0;
}
