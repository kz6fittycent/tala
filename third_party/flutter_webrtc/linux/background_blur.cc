#include "background_blur.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <thread>

#include "effects_tuning.h"
#include "gpu_effects.h"

namespace tala {
namespace {

constexpr int kMaskW = SelfieSegmenter::kWidth;
constexpr int kMaskH = SelfieSegmenter::kHeight;

// How much of each new mask is taken; the rest is the previous frames', which
// keeps the edge from flickering.
constexpr float kMaskFollow = 0.6f;

using namespace tuning;

// Runs fn(y0, y1) over rows 0 to h, split across up to four threads, the
// calling one among them. At 1080p a single core can't do every pass of a
// frame in a 60 fps frame's time; the work is the same, it just ends sooner.
// Frames come one at a time, so threads are started per pass: tens of
// microseconds against milliseconds of work.
template <typename F>
void ParallelRows(int h, F fn) {
  static const int most =
      std::max(1, std::min(4, static_cast<int>(
                                  std::thread::hardware_concurrency() / 2)));
  // Rows come in hundreds; a handful of whole tasks (h below 8) each get one.
  const int n = std::min(most, h < 8 ? h : std::max(1, h / 128));
  if (n == 1) {
    fn(0, h);
    return;
  }
  std::vector<std::thread> threads;
  for (int i = 1; i < n; i++) threads.emplace_back(fn, h * i / n, h * (i + 1) / n);
  fn(0, h / n);
  for (auto& t : threads) t.join();
}

uint8_t Clamp8(float v) {
  return static_cast<uint8_t>(std::min(std::max(v + 0.5f, 0.0f), 255.0f));
}

// Averages a plane down by `factor` in each direction (partial blocks at the
// edges average what they cover).
void Shrink(const uint8_t* p, int w, int h, int stride, int factor,
            std::vector<float>& out, int& sw, int& sh) {
  sw = (w + factor - 1) / factor;
  sh = (h + factor - 1) / factor;
  out.assign(static_cast<size_t>(sw) * sh, 0.0f);
  for (int by = 0; by < sh; by++) {
    const int y0 = by * factor, y1 = std::min(y0 + factor, h);
    float* o = &out[static_cast<size_t>(by) * sw];
    for (int y = y0; y < y1; y++) {
      const uint8_t* row = p + static_cast<size_t>(y) * stride;
      for (int bx = 0; bx < sw; bx++) {
        const int x0 = bx * factor, x1 = std::min(x0 + factor, w);
        int sum = 0;
        for (int x = x0; x < x1; x++) sum += row[x];
        o[bx] += sum;
      }
    }
    const int rows = y1 - y0;
    for (int bx = 0; bx < sw; bx++) {
      const int cols = std::min(bx * factor + factor, w) - bx * factor;
      o[bx] /= rows * cols;
    }
  }
}

// Box blur along rows then columns, clamping at the edges; repeated, it
// approaches a Gaussian. The column pass slides a running sum over whole
// rows, so memory is read in order.
void BoxBlur(std::vector<float>& p, int w, int h, int r,
             std::vector<float>& tmp) {
  tmp.resize(p.size());
  const float scale = 1.0f / (2 * r + 1);
  for (int y = 0; y < h; y++) {
    const float* in = &p[static_cast<size_t>(y) * w];
    float* out = &tmp[static_cast<size_t>(y) * w];
    float sum = 0;
    for (int k = -r; k <= r; k++) sum += in[std::min(std::max(k, 0), w - 1)];
    for (int x = 0; x < w; x++) {
      out[x] = sum * scale;
      sum += in[std::min(x + r + 1, w - 1)] - in[std::max(x - r, 0)];
    }
  }
  auto row = [&](int y) {
    return &tmp[static_cast<size_t>(std::min(std::max(y, 0), h - 1)) * w];
  };
  std::vector<float> sum(w, 0.0f);
  for (int k = -r; k <= r; k++) {
    const float* t = row(k);
    for (int x = 0; x < w; x++) sum[x] += t[x];
  }
  for (int y = 0; y < h; y++) {
    float* out = &p[static_cast<size_t>(y) * w];
    const float* add = row(y + r + 1);
    const float* drop = row(y - r);
    for (int x = 0; x < w; x++) {
      out[x] = sum[x] * scale;
      sum[x] += add[x] - drop[x];
    }
  }
}

// Sample positions for scaling a `from`-long axis to `to` with half pixel
// centers: index of the lower neighbor and the weight of the upper one.
void Axis(int to, int from, std::vector<int>& lo, std::vector<float>& frac) {
  lo.resize(to);
  frac.resize(to);
  const float scale = static_cast<float>(from) / to;
  for (int i = 0; i < to; i++) {
    const float f = std::min(std::max((i + 0.5f) * scale - 0.5f, 0.0f),
                             static_cast<float>(from - 1));
    lo[i] = std::min(static_cast<int>(f), from - 2 < 0 ? 0 : from - 2);
    frac[i] = from > 1 ? f - lo[i] : 0.0f;
  }
}

// Row `y0` of `p` blended toward the next by `fy`.
void VerticalLerp(const float* p, int w, int h, int y0, float fy, float* out) {
  const float* a = p + static_cast<size_t>(y0) * w;
  const float* b = p + static_cast<size_t>(std::min(y0 + 1, h - 1)) * w;
  for (int x = 0; x < w; x++) out[x] = a[x] + (b[x] - a[x]) * fy;
}

// Blends one plane: the person (mask near 1) from `in`, the rest from the
// blurred `small` copy (or the picture, at full size). Each row is first interpolated vertically from the
// mask and the small copy, leaving one lerp a pixel along the row.
void Blend(const uint8_t* in, int stride, int w, int h,
           const std::vector<float>& small, int sw, int sh,
           const std::vector<float>& mask, int mw, int mh, uint8_t* out) {
  std::vector<int> mx, my, bx, by;
  std::vector<float> mfx, mfy, bfx, bfy;
  Axis(w, mw, mx, mfx);
  Axis(h, mh, my, mfy);
  Axis(w, sw, bx, bfx);
  Axis(h, sh, by, bfy);
  ParallelRows(h, [&](int y0, int y1) {
    std::vector<float> mrow(mw), brow(sw);
    for (int y = y0; y < y1; y++) {
      VerticalLerp(mask.data(), mw, mh, my[y], mfy[y], mrow.data());
      VerticalLerp(small.data(), sw, sh, by[y], bfy[y], brow.data());
      const uint8_t* row = in + static_cast<size_t>(y) * stride;
      uint8_t* o = out + static_cast<size_t>(y) * w;
      for (int x = 0; x < w; x++) {
        const int m0 = mx[x], m1 = std::min(m0 + 1, mw - 1);
        const float m = mrow[m0] + (mrow[m1] - mrow[m0]) * mfx[x];
        if (m >= 0.999f) {
          o[x] = row[x];
          continue;
        }
        const int b0 = bx[x], b1 = std::min(b0 + 1, sw - 1);
        const float b = brow[b0] + (brow[b1] - brow[b0]) * bfx[x];
        o[x] = Clamp8(b + (row[x] - b) * m);
      }
    }
  });
}

// Bilinear resize of a float plane, half pixel centers.
void Resample(const std::vector<float>& src, int sw, int sh, int dw, int dh,
              std::vector<float>& out) {
  std::vector<int> xs, ys;
  std::vector<float> fx, fy;
  Axis(dw, sw, xs, fx);
  Axis(dh, sh, ys, fy);
  out.resize(static_cast<size_t>(dw) * dh);
  std::vector<float> row(sw);
  for (int y = 0; y < dh; y++) {
    VerticalLerp(src.data(), sw, sh, ys[y], fy[y], row.data());
    float* o = &out[static_cast<size_t>(y) * dw];
    for (int x = 0; x < dw; x++) {
      const int x0 = xs[x], x1 = std::min(x0 + 1, sw - 1);
      o[x] = row[x0] + (row[x1] - row[x0]) * fx[x];
    }
  }
}

// He, Sun and Tang's guided filter: makes `p` follow the edges of the guide
// picture `g`. Both w by h; the result goes back into `p`, clamped to 0..1.
void GuidedFilter(const std::vector<float>& g, std::vector<float>& p, int w,
                  int h, int r, float eps) {
  const size_t n = g.size();
  std::vector<float> mean_g = g, mean_p = p, gg(n), gp(n);
  for (size_t i = 0; i < n; i++) {
    gg[i] = g[i] * g[i];
    gp[i] = g[i] * p[i];
  }
  // The four blurs are independent, so each gets a thread.
  std::vector<float>* planes[4] = {&mean_g, &mean_p, &gg, &gp};
  ParallelRows(4, [&](int i0, int i1) {
    std::vector<float> own;
    for (int i = i0; i < i1; i++) BoxBlur(*planes[i], w, h, r, own);
  });
  // gg and gp become the a and b of each window.
  for (size_t i = 0; i < n; i++) {
    const float var = gg[i] - mean_g[i] * mean_g[i];
    const float cov = gp[i] - mean_g[i] * mean_p[i];
    const float a = cov / (var + eps);
    gg[i] = a;
    gp[i] = mean_p[i] - a * mean_g[i];
  }
  ParallelRows(2, [&](int i0, int i1) {
    std::vector<float> own;
    for (int i = i0; i < i1; i++) BoxBlur(*planes[2 + i], w, h, r, own);
  });
  for (size_t i = 0; i < n; i++) {
    p[i] = std::min(std::max(gg[i] * g[i] + gp[i], 0.0f), 1.0f);
  }
}

// Bilinear sample positions along one axis of a crop starting at `start` and
// `length` long in a `from`-long source, for `to` output pixels.
void CropAxis(int to, float start, float length, int from, std::vector<int>& lo,
              std::vector<float>& frac) {
  lo.resize(to);
  frac.resize(to);
  const float scale = length / to;
  for (int i = 0; i < to; i++) {
    const float f = std::min(std::max(start + (i + 0.5f) * scale - 0.5f, 0.0f),
                             static_cast<float>(from - 1));
    lo[i] = std::min(static_cast<int>(f), from - 2 < 0 ? 0 : from - 2);
    frac[i] = from > 1 ? f - lo[i] : 0.0f;
  }
}

// 1 inside lo..hi, falling to 0 kSkinSoft outside it.
float Ramp(float v, float lo, float hi) {
  const float d = std::max(lo - v, v - hi);
  return d <= 0 ? 1.0f : d >= kSkinSoft ? 0.0f : 1 - d / kSkinSoft;
}

}  // namespace

BackgroundBlur::BackgroundBlur() = default;
BackgroundBlur::~BackgroundBlur() = default;

std::string BackgroundBlur::Engine() const {
  std::lock_guard<std::mutex> lock(engine_mutex_);
  return engine_;
}

void BackgroundBlur::SetEngine(const std::string& engine) {
  std::lock_guard<std::mutex> lock(engine_mutex_);
  engine_ = engine;
}

void BackgroundBlur::DropGpu(const std::string& why) {
  gpu_.reset();
  gpu_tried_ = true;
  SetEngine("cpu: " + why);
}

bool BackgroundBlur::ApplyGpu(const I420& in, uint8_t* out_y, uint8_t* out_u,
                              uint8_t* out_v) {
  using Clock = std::chrono::steady_clock;
  if (!gpu_allowed_) return false;
  if (!gpu_) {
    if (gpu_tried_) return false;
    gpu_tried_ = true;
    std::string why;
    gpu_ = GpuEffects::Create(&why);
    if (!gpu_) {
      SetEngine("cpu: " + why);
      return false;
    }
  }
  GpuEffects::Look look;
  look.mask = mask_.data();
  look.mask_width = kMaskW;
  look.mask_height = kMaskH;
  if (picture_width_ > 0) {
    FitPicture(in.width, in.height);
    look.picture = picture_scaled_;
  }
  look.picture_version = picture_version_;
  look.blur = blur_;
  look.touch_up = touch_up_;
  const unsigned kind = 1u << ((picture_width_ > 0 ? 4 : 0) |
                               (blur_ ? 2 : 0) | (touch_up_ > 0 ? 1 : 0));
  const int cw = (in.width + 1) / 2, ch = (in.height + 1) / 2;
  const size_t ys = static_cast<size_t>(in.width) * in.height;
  const size_t cs = static_cast<size_t>(cw) * ch;

  if (!(gpu_checked_ & kind)) {
    // Both ways on this frame; the CPU's picture goes out either way.
    const auto t0 = Clock::now();
    ApplyCpu(in, out_y, out_u, out_v);
    cpu_ms_ = std::chrono::duration<double, std::milli>(Clock::now() - t0)
                  .count();
    check_.resize(ys + 2 * cs);
    if (!gpu_->Apply(in, look, check_.data(), check_.data() + ys,
                     check_.data() + ys + cs)) {
      DropGpu("GPU error on " + gpu_->renderer());
      return true;
    }
    // Rounding may differ by a level here and there; a real fault differs
    // more, and in more places.
    size_t off = 0;
    const uint8_t* cpu[3] = {out_y, out_u, out_v};
    const size_t sizes[3] = {ys, cs, cs};
    size_t at = 0;
    for (int p = 0; p < 3; p++) {
      for (size_t i = 0; i < sizes[p]; i++) {
        if (std::abs(cpu[p][i] - check_[at + i]) > 2) off++;
      }
      at += sizes[p];
    }
    if (off * 1000 > ys + 2 * cs) {
      DropGpu("GPU's picture differed (" + gpu_->renderer() + ")");
      return true;
    }
    gpu_checked_ |= kind;
    gpu_frames_ = 0;
    gpu_ms_ = 0;
    SetEngine("gpu: " + gpu_->renderer());
    return true;
  }

  const auto t0 = Clock::now();
  if (!gpu_->Apply(in, look, out_y, out_u, out_v)) {
    DropGpu("GPU error on " + gpu_->renderer());
    return false;
  }
  // After a few frames to settle, 30 frames' time against the CPU's.
  if (++gpu_frames_ > 5 && gpu_frames_ <= 35) {
    gpu_ms_ += std::chrono::duration<double, std::milli>(Clock::now() - t0)
                   .count();
    if (gpu_frames_ == 35 && gpu_ms_ / 30 > cpu_ms_) {
      DropGpu("GPU slower than the CPU (" + gpu_->renderer() + ")");
    }
  }
  return true;
}

void BackgroundBlur::SetPicture(const std::vector<uint8_t>& rgba, int width,
                                int height) {
  scaled_width_ = scaled_height_ = 0;
  picture_version_++;
  if (width < 2 || height < 2 ||
      rgba.size() < static_cast<size_t>(width) * height * 4) {
    for (auto& p : picture_) p.clear();
    picture_width_ = picture_height_ = 0;
    return;
  }
  const size_t n = static_cast<size_t>(width) * height;
  for (auto& p : picture_) p.resize(n);
  // BT.601 limited range, as the camera's frames are.
  for (size_t i = 0; i < n; i++) {
    const float r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
    picture_[0][i] = 16 + 0.257f * r + 0.504f * g + 0.098f * b;
    picture_[1][i] = 128 - 0.148f * r - 0.291f * g + 0.439f * b;
    picture_[2][i] = 128 + 0.439f * r - 0.368f * g - 0.071f * b;
  }
  picture_width_ = width;
  picture_height_ = height;
}

void BackgroundBlur::FitPicture(int width, int height) {
  if (scaled_width_ == width && scaled_height_ == height) return;
  const float pw = picture_width_, ph = picture_height_;
  // The largest centered part of the picture with the frame's shape.
  float crop_w = pw, crop_h = ph;
  if (pw * height > ph * width) {
    crop_w = ph * width / height;
  } else {
    crop_h = pw * height / width;
  }
  const float x0 = (pw - crop_w) / 2, y0 = (ph - crop_h) / 2;
  const int cw = (width + 1) / 2, ch = (height + 1) / 2;
  for (int i = 0; i < 3; i++) {
    const int ow = i == 0 ? width : cw, oh = i == 0 ? height : ch;
    std::vector<int> xs, ys;
    std::vector<float> fx, fy;
    CropAxis(ow, x0, crop_w, picture_width_, xs, fx);
    CropAxis(oh, y0, crop_h, picture_height_, ys, fy);
    auto& out = picture_scaled_[i];
    out.resize(static_cast<size_t>(ow) * oh);
    std::vector<float> row(picture_width_);
    for (int y = 0; y < oh; y++) {
      VerticalLerp(picture_[i].data(), picture_width_, picture_height_, ys[y],
                   fy[y], row.data());
      float* o = &out[static_cast<size_t>(y) * ow];
      for (int x = 0; x < ow; x++) {
        const int a = xs[x], b = std::min(a + 1, picture_width_ - 1);
        o[x] = row[a] + (row[b] - row[a]) * fx[x];
      }
    }
  }
  scaled_width_ = width;
  scaled_height_ = height;
}

void BackgroundBlur::Segment(const I420& in) {
  rgb_.resize(static_cast<size_t>(kMaskW) * kMaskH * 3);
  // Stretched to the model's 16:9, nearest pixel; BT.601 limited range, as
  // webcams send.
  for (int y = 0; y < kMaskH; y++) {
    const int sy = std::min((2 * y + 1) * in.height / (2 * kMaskH), in.height - 1);
    for (int x = 0; x < kMaskW; x++) {
      const int sx = std::min((2 * x + 1) * in.width / (2 * kMaskW), in.width - 1);
      const float l = 1.164f * (in.y[static_cast<size_t>(sy) * in.stride_y + sx] - 16);
      const float u = in.u[static_cast<size_t>(sy / 2) * in.stride_u + sx / 2] - 128.0f;
      const float v = in.v[static_cast<size_t>(sy / 2) * in.stride_v + sx / 2] - 128.0f;
      float* p = &rgb_[(static_cast<size_t>(y) * kMaskW + x) * 3];
      p[0] = std::min(std::max(l + 1.596f * v, 0.0f), 255.0f) / 255;
      p[1] = std::min(std::max(l - 0.392f * u - 0.813f * v, 0.0f), 255.0f) / 255;
      p[2] = std::min(std::max(l + 2.017f * u, 0.0f), 255.0f) / 255;
    }
  }
  const float* raw = segmenter_.Run(rgb_.data());
  const bool fresh = mask_width_ != in.width || mask_height_ != in.height;
  mask_.resize(static_cast<size_t>(kMaskW) * kMaskH);
  for (size_t i = 0; i < mask_.size(); i++) {
    mask_[i] = fresh ? raw[i] : mask_[i] + (raw[i] - mask_[i]) * kMaskFollow;
  }
  mask_width_ = in.width;
  mask_height_ = in.height;
}

void BackgroundBlur::TouchUp(const I420& in, int gw, int gh) {
  smooth_ = guide_;
  GuidedFilter(guide_, smooth_, gw, gh, kTouchRadius, kTouchEps);
  const int w = in.width, h = in.height;
  touched_.resize(static_cast<size_t>(w) * h);
  std::vector<int> xs, ys;
  std::vector<float> fx, fy;
  Axis(w, gw, xs, fx);
  Axis(h, gh, ys, fy);
  const float inv = 1 / (kTouchDetail * kTouchDetail);
  const int cw = (w + 1) / 2;
  const float amount = kTouchMost * touch_up_;
  ParallelRows(h, [&](int y0, int y1) {
    std::vector<float> srow(gw), mrow(gw), skin(cw);
    int skin_y = -1;
    for (int y = y0; y < y1; y++) {
      VerticalLerp(smooth_.data(), gw, gh, ys[y], fy[y], srow.data());
      VerticalLerp(refined_.data(), gw, gh, ys[y], fy[y], mrow.data());
      // How much each chroma pixel looks like skin, shared by its two rows.
      if (y / 2 != skin_y) {
        skin_y = y / 2;
        const uint8_t* u = in.u + static_cast<size_t>(skin_y) * in.stride_u;
        const uint8_t* v = in.v + static_cast<size_t>(skin_y) * in.stride_v;
        for (int x = 0; x < cw; x++) {
          skin[x] = amount * Ramp(u[x], 77, 127) * Ramp(v[x], 133, 173);
        }
      }
      const uint8_t* row = in.y + static_cast<size_t>(y) * in.stride_y;
      uint8_t* o = &touched_[static_cast<size_t>(y) * w];
      for (int x = 0; x < w; x++) {
        const float s = skin[x / 2];
        if (s <= 0) {
          o[x] = row[x];
          continue;
        }
        const int a = xs[x], b = std::min(a + 1, gw - 1);
        const float weight = s * (mrow[a] + (mrow[b] - mrow[a]) * fx[x]);
        if (weight < 0.01f) {
          o[x] = row[x];
          continue;
        }
        const float base = 255 * (srow[a] + (srow[b] - srow[a]) * fx[x]);
        const float d = row[x] - base;
        const float t = d * d * inv;
        o[x] = Clamp8(row[x] - weight * d / (1 + t * t));
      }
    }
  });
}

void BackgroundBlur::Apply(const I420& in, uint8_t* out_y, uint8_t* out_u,
                           uint8_t* out_v) {
  // The model runs at most every kModelGap: at 60 fps every other frame,
  // which the mask's smoothing over frames already hides.
  const auto now = std::chrono::steady_clock::now();
  if (mask_width_ != in.width || mask_height_ != in.height ||
      now - last_model_ >= model_gap_) {
    Segment(in);
    last_model_ = now;
  }
  if (!ApplyGpu(in, out_y, out_u, out_v)) ApplyCpu(in, out_y, out_u, out_v);
}

void BackgroundBlur::ApplyCpu(const I420& in, uint8_t* out_y, uint8_t* out_u,
                              uint8_t* out_v) {
  // The model's mask, refined against the picture's brightness at about
  // kGuideWidth, so the edge lands on the person's real outline.
  const int gf = std::max(1, in.width / kGuideWidth);
  int gw, gh;
  Shrink(in.y, in.width, in.height, in.stride_y, gf, guide_, gw, gh);
  for (float& v : guide_) v /= 255;
  Resample(mask_, kMaskW, kMaskH, gw, gh, refined_);
  GuidedFilter(guide_, refined_, gw, gh, kGuideRadius, kGuideEps);
  // A gentle S-curve: the model's unsure fringe leans to one side or the
  // other instead of showing half sharp. Anything harder turns that fringe
  // into sharp cutouts.
  for (float& v : refined_) v = v * v * (3 - 2 * v);

  const int cw = (in.width + 1) / 2, ch = (in.height + 1) / 2;
  // Touched up, the person's brightness comes from touched_ from here on.
  const uint8_t* luma = in.y;
  int luma_stride = in.stride_y;
  if (touch_up_ > 0) {
    TouchUp(in, gw, gh);
    luma = touched_.data();
    luma_stride = in.width;
  }
  if (picture_width_ == 0 && !blur_) {
    const uint8_t* planes[3] = {luma, in.u, in.v};
    const int strides[3] = {luma_stride, in.stride_u, in.stride_v};
    uint8_t* outs[3] = {out_y, out_u, out_v};
    for (int i = 0; i < 3; i++) {
      const int w = i == 0 ? in.width : cw, h = i == 0 ? in.height : ch;
      for (int y = 0; y < h; y++) {
        std::copy(planes[i] + static_cast<size_t>(y) * strides[i],
                  planes[i] + static_cast<size_t>(y) * strides[i] + w,
                  outs[i] + static_cast<size_t>(y) * w);
      }
    }
    return;
  }
  if (picture_width_ > 0) {
    for (float& v : refined_) {
      v = std::max(0.0f, (v - kPictureCut) / (1 - kPictureCut));
    }
    FitPicture(in.width, in.height);
    const uint8_t* planes[3] = {luma, in.u, in.v};
    const int strides[3] = {luma_stride, in.stride_u, in.stride_v};
    uint8_t* outs[3] = {out_y, out_u, out_v};
    for (int i = 0; i < 3; i++) {
      const int w = i == 0 ? in.width : cw, h = i == 0 ? in.height : ch;
      Blend(planes[i], strides[i], w, h, picture_scaled_[i], w, h, refined_,
            gw, gh, outs[i]);
    }
    return;
  }

  const int factor = std::max(1, in.width / kSmallWidth);
  const uint8_t* planes[3] = {luma, in.u, in.v};
  const int strides[3] = {luma_stride, in.stride_u, in.stride_v};
  const int widths[3] = {in.width, cw, cw};
  const int heights[3] = {in.height, ch, ch};
  uint8_t* outs[3] = {out_y, out_u, out_v};
  // The planes are independent, so each gets a thread.
  ParallelRows(3, [&](int i0, int i1) {
    for (int i = i0; i < i1; i++) {
      std::vector<float>& weight = weight_[i];
      std::vector<float>& scratch = scratch_planes_[i];
      // Chroma is already half size, so it shrinks by half as much.
      const int f = i == 0 ? factor : std::max(1, factor / 2);
      int sw, sh;
      Shrink(planes[i], widths[i], heights[i], strides[i], f, small_[i], sw, sh);
      // The same reach in camera pixels for every plane: kBlurRadius luma
      // small pixels are kBlurRadius * factor camera pixels, and a chroma small
      // pixel covers 2 * f.
      const int scale = i == 0 ? factor : 2 * f;
      const int r = std::max(1, (kBlurRadius * factor + scale / 2) / scale);
      // Only the background is blurred, each pixel weighted by how much it is
      // background, so the person's colors don't spread into a halo around
      // them. Where there's no background nearby, the person shows anyway.
      Resample(refined_, gw, gh, sw, sh, weight);
      for (size_t k = 0; k < weight.size(); k++) {
        weight[k] = 1 - weight[k];
        small_[i][k] *= weight[k];
      }
      for (int p = 0; p < kBlurPasses; p++) {
        BoxBlur(small_[i], sw, sh, r, scratch);
        BoxBlur(weight, sw, sh, r, scratch);
      }
      for (size_t k = 0; k < weight.size(); k++) {
        small_[i][k] = weight[k] > 1e-3f ? small_[i][k] / weight[k]
                                         : (i == 0 ? 16.0f : 128.0f);
      }
      Blend(planes[i], strides[i], widths[i], heights[i], small_[i], sw, sh,
            refined_, gw, gh, outs[i]);
    }
  });
}

}  // namespace tala
