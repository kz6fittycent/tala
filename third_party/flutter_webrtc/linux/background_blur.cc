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

// The mask's edge is refined against the picture at about this width: the
// model's mask is 256 wide, so on a 1280 wide camera each of its pixels spans
// five, too coarse to follow hair and shoulders.
constexpr int kGuideWidth = 640;
// Guided filter: box radius in guide pixels, and how much picture contrast it
// takes to move the edge (pictures from 0 to 1). Smaller follows the picture
// more closely, but also latches onto background texture beside the person.
constexpr int kGuideRadius = 4;
constexpr float kGuideEps = 0.02f;


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
// blurred `small` copy. Each row is first interpolated vertically from the
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
  std::vector<float> mrow(mw), brow(sw);
  for (int y = 0; y < h; y++) {
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
                  int h, int r, float eps, std::vector<float>& tmp) {
  const size_t n = g.size();
  std::vector<float> mean_g = g, mean_p = p, gg(n), gp(n);
  for (size_t i = 0; i < n; i++) {
    gg[i] = g[i] * g[i];
    gp[i] = g[i] * p[i];
  }
  BoxBlur(mean_g, w, h, r, tmp);
  BoxBlur(mean_p, w, h, r, tmp);
  BoxBlur(gg, w, h, r, tmp);
  BoxBlur(gp, w, h, r, tmp);
  // gg and gp become the a and b of each window.
  for (size_t i = 0; i < n; i++) {
    const float var = gg[i] - mean_g[i] * mean_g[i];
    const float cov = gp[i] - mean_g[i] * mean_p[i];
    const float a = cov / (var + eps);
    gg[i] = a;
    gp[i] = mean_p[i] - a * mean_g[i];
  }
  BoxBlur(gg, w, h, r, tmp);
  BoxBlur(gp, w, h, r, tmp);
  for (size_t i = 0; i < n; i++) {
    p[i] = std::min(std::max(gg[i] * g[i] + gp[i], 0.0f), 1.0f);
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
  // The model's mask, refined against the picture's brightness at about
  // kGuideWidth, so the edge lands on the person's real outline.
  const int gf = std::max(1, in.width / kGuideWidth);
  int gw, gh;
  Shrink(in.y, in.width, in.height, in.stride_y, gf, guide_, gw, gh);
  for (float& v : guide_) v /= 255;
  Resample(mask_, kMaskW, kMaskH, gw, gh, refined_);
  GuidedFilter(guide_, refined_, gw, gh, kGuideRadius, kGuideEps, scratch_);
  // A gentle S-curve: the model's unsure fringe leans to one side or the
  // other instead of showing half sharp. Anything harder turns that fringe
  // into sharp cutouts.
  for (float& v : refined_) v = v * v * (3 - 2 * v);

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
    // Only the background is blurred, each pixel weighted by how much it is
    // background, so the person's colors don't spread into a halo around
    // them. Where there's no background nearby, the person shows anyway.
    Resample(refined_, gw, gh, sw, sh, weight_);
    for (size_t k = 0; k < weight_.size(); k++) {
      weight_[k] = 1 - weight_[k];
      small_[i][k] *= weight_[k];
    }
    for (int p = 0; p < kBlurPasses; p++) {
      BoxBlur(small_[i], sw, sh, r, scratch_);
      BoxBlur(weight_, sw, sh, r, scratch_);
    }
    for (size_t k = 0; k < weight_.size(); k++) {
      small_[i][k] = weight_[k] > 1e-3f ? small_[i][k] / weight_[k]
                                        : (i == 0 ? 16.0f : 128.0f);
    }
    Blend(planes[i], strides[i], widths[i], heights[i], small_[i], sw, sh,
          refined_, gw, gh, outs[i]);
  }
}

}  // namespace tala
