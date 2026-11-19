// Runs Tala's background blur on one raw I420 frame for check_blur.py:
//   check_blur_main <width> <height> <in.yuv> <out.yuv> [runs
//                   [<picture.rgba> <picture width> <picture height>]]
//                   [--touch-up=<0 to 1>] [--no-blur]
// With a picture, it goes behind the person instead of the blur; --no-blur
// leaves the background alone. Prints the average time per frame.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "background_blur.h"

int main(int argc, char** argv) {
  float touch_up = 0;
  bool blur_background = true;
  int kept = 1;
  for (int i = 1; i < argc; i++) {
    if (std::strncmp(argv[i], "--touch-up=", 11) == 0) {
      touch_up = std::atof(argv[i] + 11);
    } else if (std::strcmp(argv[i], "--no-blur") == 0) {
      blur_background = false;
    } else {
      argv[kept++] = argv[i];
    }
  }
  argc = kept;
  if (argc < 5) return 2;
  const int w = std::atoi(argv[1]), h = std::atoi(argv[2]);
  const int cw = (w + 1) / 2, ch = (h + 1) / 2;
  const size_t ys = static_cast<size_t>(w) * h, cs = static_cast<size_t>(cw) * ch;
  std::vector<uint8_t> in(ys + 2 * cs), out(ys + 2 * cs);
  FILE* f = std::fopen(argv[3], "rb");
  if (!f || std::fread(in.data(), 1, in.size(), f) != in.size()) return 1;
  std::fclose(f);
  tala::I420 frame;
  frame.width = w;
  frame.height = h;
  frame.y = in.data();
  frame.u = in.data() + ys;
  frame.v = in.data() + ys + cs;
  frame.stride_y = w;
  frame.stride_u = frame.stride_v = cw;
  const int runs = argc > 5 ? std::atoi(argv[5]) : 1;
  tala::BackgroundBlur blur;
  blur.SetLook(blur_background, touch_up);
  if (argc > 8) {
    const int pw = std::atoi(argv[7]), ph = std::atoi(argv[8]);
    std::vector<uint8_t> rgba(static_cast<size_t>(pw) * ph * 4);
    FILE* p = std::fopen(argv[6], "rb");
    if (!p || std::fread(rgba.data(), 1, rgba.size(), p) != rgba.size())
      return 1;
    std::fclose(p);
    blur.SetPicture(rgba, pw, ph);
  }
  // A few frames first so the mask settles, as it would in a call.
  for (int i = 0; i < 5; i++)
    blur.Apply(frame, out.data(), out.data() + ys, out.data() + ys + cs);
  const auto start = std::chrono::steady_clock::now();
  for (int i = 0; i < runs; i++)
    blur.Apply(frame, out.data(), out.data() + ys, out.data() + ys + cs);
  const double ms = std::chrono::duration<double, std::milli>(
                        std::chrono::steady_clock::now() - start)
                        .count() /
                    runs;
  std::printf("%dx%d: %.2f ms per frame\n", w, h, ms);
  f = std::fopen(argv[4], "wb");
  std::fwrite(out.data(), 1, out.size(), f);
  std::fclose(f);
  return 0;
}
