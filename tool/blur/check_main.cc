// Runs Tala's selfie segmenter on raw float input for check_segmenter.py:
//   check_main <in.f32> <out.f32> [runs]
// The input is 144x256x3 floats; the output 144x256. Prints the average time
// per run.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "selfie_segmenter.h"

int main(int argc, char** argv) {
  if (argc < 3) return 2;
  using S = tala::SelfieSegmenter;
  std::vector<float> in(S::kWidth * S::kHeight * 3);
  FILE* f = std::fopen(argv[1], "rb");
  if (!f || std::fread(in.data(), sizeof(float), in.size(), f) != in.size()) {
    return 1;
  }
  std::fclose(f);
  const int runs = argc > 3 ? std::atoi(argv[3]) : 1;
  S seg;
  const float* out = seg.Run(in.data());
  const auto start = std::chrono::steady_clock::now();
  for (int i = 0; i < runs; i++) out = seg.Run(in.data());
  const double ms = std::chrono::duration<double, std::milli>(
                        std::chrono::steady_clock::now() - start)
                        .count() /
                    runs;
  std::printf("%.2f ms per run\n", ms);
  f = std::fopen(argv[2], "wb");
  std::fwrite(out, sizeof(float), S::kWidth * S::kHeight, f);
  std::fclose(f);
  return 0;
}
