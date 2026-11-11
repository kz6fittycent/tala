#include "background_blur.h"

#include <algorithm>
#include <cmath>

namespace tala {
namespace {

constexpr int kMaskW = SelfieSegmenter::kWidth;
constexpr int kMaskH = SelfieSegmenter::kHeight;

// How much of each new mask is taken; the rest is the previous frames', which
// keeps the edge from flickering.
constexpr float kMaskFollow = 0.6f;

// Mask values between these blend; below is background, above is person.
constexpr float kEdgeLow = 0.25f;
constexpr float kEdgeHigh = 0.75f;
constexpr int kMaskSoften = 1;  // box radius in mask pixels

// The blurred copy is made at about this width, whatever the camera's size,
// so the blur looks the same at any resolution.
constexpr int kSmallWidth = 160;
constexpr int kBlurRadius = 3;  // in small pixels, three box passes
constexpr int kBlurPasses = 3;

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
  std::vector<int> counts(out.size(), 0);
  for (int y = 0; y < h; y++) {
    const uint8_t* row = p + static_cast<size_t>(y) * stride;
    float* o = &out[static_cast<size_t>(y / factor) * sw];
    int* c = &counts[static_cast<size_t>(y / factor) * sw];
    for (int x = 0; x < w; x++) {
      o[x / factor] += row[x];
      c[x / factor]++;
    }
  }
  for (size_t i = 0; i < out.size(); i++) out[i] /= counts[i];
}

// Box blur along rows then columns, clamping at the edges; repeated, it
// approaches a Gaussian.
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
  for (int x = 0; x < w; x++) {
    float sum = 0;
    for (int k = -r; k <= r; k++)
      sum += tmp[static_cast<size_t>(std::min(std::max(k, 0), h - 1)) * w + x];
    for (int y = 0; y < h; y++) {
      p[static_cast<size_t>(y) * w + x] = sum * scale;
      sum += tmp[static_cast<size_t>(std::min(y + r + 1, h - 1)) * w + x] -
             tmp[static_cast<size_t>(std::max(y - r, 0)) * w + x];
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
// blurred `small` copy. Each row is first interpolated vertically from the
// mask and the small copy, leaving one lerp a pixel along the row.
void Blend(const uint8_t* in, int stride, int w, int h,
           const std::vector<float>& small, int sw, int sh,
           const std::vector<float>& mask, uint8_t* out) {
  std::vector<int> mx, my, bx, by;
  std::vector<float> mfx, mfy, bfx, bfy;
  Axis(w, kMaskW, mx, mfx);
  Axis(h, kMaskH, my, mfy);
  Axis(w, sw, bx, bfx);
  Axis(h, sh, by, bfy);
  std::vector<float> mrow(kMaskW), brow(sw);
  for (int y = 0; y < h; y++) {
    VerticalLerp(mask.data(), kMaskW, kMaskH, my[y], mfy[y], mrow.data());
    VerticalLerp(small.data(), sw, sh, by[y], bfy[y], brow.data());
    const uint8_t* row = in + static_cast<size_t>(y) * stride;
    uint8_t* o = out + static_cast<size_t>(y) * w;
    for (int x = 0; x < w; x++) {
      const int m0 = mx[x], m1 = std::min(m0 + 1, kMaskW - 1);
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
}

}  // namespace

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

void BackgroundBlur::Apply(const I420& in, uint8_t* out_y, uint8_t* out_u,
                           uint8_t* out_v) {
  Segment(in);
  // Shaped toward a firmer edge, then softened a little so the model's
  // pixel steps don't show once stretched to the camera's size.
  shaped_.resize(mask_.size());
  for (size_t i = 0; i < mask_.size(); i++) {
    const float t =
        std::min(std::max((mask_[i] - kEdgeLow) / (kEdgeHigh - kEdgeLow), 0.0f),
                 1.0f);
    shaped_[i] = t * t * (3 - 2 * t);
  }
  BoxBlur(shaped_, kMaskW, kMaskH, kMaskSoften, scratch_);
  const int factor = std::max(1, in.width / kSmallWidth);
  const int cw = (in.width + 1) / 2, ch = (in.height + 1) / 2;
  const uint8_t* planes[3] = {in.y, in.u, in.v};
  const int strides[3] = {in.stride_y, in.stride_u, in.stride_v};
  const int widths[3] = {in.width, cw, cw};
  const int heights[3] = {in.height, ch, ch};
  uint8_t* outs[3] = {out_y, out_u, out_v};
  for (int i = 0; i < 3; i++) {
    // Chroma is already half size, so it shrinks by half as much.
    const int f = i == 0 ? factor : std::max(1, factor / 2);
    int sw, sh;
    Shrink(planes[i], widths[i], heights[i], strides[i], f, small_[i], sw, sh);
    // The same reach in camera pixels for every plane: kBlurRadius luma
    // small pixels are kBlurRadius * factor camera pixels, and a chroma small
    // pixel covers 2 * f.
    const int scale = i == 0 ? factor : 2 * f;
    const int r = std::max(1, (kBlurRadius * factor + scale / 2) / scale);
    for (int p = 0; p < kBlurPasses; p++) BoxBlur(small_[i], sw, sh, r, scratch_);
    Blend(planes[i], strides[i], widths[i], heights[i], small_[i], sw, sh,
          shaped_, outs[i]);
  }
}

}  // namespace tala
