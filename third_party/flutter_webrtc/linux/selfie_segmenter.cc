#include "selfie_segmenter.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace tala {
namespace {

struct TensorInfo {
  int h, w, c;
  int weight;  // offset into kWeights, or -1 for a computed tensor
  int count;
};

struct OpInfo {
  int kind, stride, same, in0, in1, in2, out;
};

#include "selfie_model_data.inc"

// In step with tool/blur/export_selfie_model.py.
enum Kind { kConv, kDwConv, kTConv, kRelu, kHSwish, kLogistic, kMean, kAdd,
            kMul, kResize };

float HalfToFloat(uint16_t h) {
  const uint32_t sign = (h & 0x8000u) << 16;
  uint32_t exp = (h >> 10) & 0x1f;
  uint32_t mant = h & 0x3ffu;
  uint32_t bits;
  if (exp == 0) {
    if (mant == 0) {
      bits = sign;
    } else {  // subnormal
      exp = 127 - 15 + 1;
      while ((mant & 0x400u) == 0) {
        mant <<= 1;
        exp--;
      }
      bits = sign | (exp << 23) | ((mant & 0x3ffu) << 13);
    }
  } else if (exp == 31) {
    bits = sign | 0x7f800000u | (mant << 13);
  } else {
    bits = sign | ((exp + 127 - 15) << 23) | (mant << 13);
  }
  float f;
  std::memcpy(&f, &bits, sizeof f);
  return f;
}

// TFLite's SAME padding: output is ceil(in / stride), and any odd padding
// goes after.
int PadBefore(int in, int out, int k, int stride) {
  return std::max((out - 1) * stride + k - in, 0) / 2;
}

// Kernel [O][K][K][I] to [K][K][I][O], so the innermost loop runs along the
// output channels, which the compiler can vectorize.
std::vector<float> Transposed(const float* w, int o, int k, int i) {
  std::vector<float> t(static_cast<size_t>(o) * k * k * i);
  for (int oc = 0; oc < o; oc++)
    for (int p = 0; p < k * k; p++)
      for (int ic = 0; ic < i; ic++)
        t[(static_cast<size_t>(p) * i + ic) * o + oc] =
            w[(static_cast<size_t>(oc) * k * k + p) * i + ic];
  return t;
}

void Conv(const float* in, const TensorInfo& ti, const float* w, int k,
          const float* bias, float* out, const TensorInfo& to, int stride,
          bool same) {
  const int ic_n = ti.c, oc_n = to.c;
  const int pad_y = same ? PadBefore(ti.h, to.h, k, stride) : 0;
  const int pad_x = same ? PadBefore(ti.w, to.w, k, stride) : 0;
  for (int oy = 0; oy < to.h; oy++) {
    for (int ox = 0; ox < to.w; ox++) {
      float* o = out + (static_cast<size_t>(oy) * to.w + ox) * oc_n;
      std::copy(bias, bias + oc_n, o);
      for (int ky = 0; ky < k; ky++) {
        const int iy = oy * stride + ky - pad_y;
        if (iy < 0 || iy >= ti.h) continue;
        for (int kx = 0; kx < k; kx++) {
          const int ix = ox * stride + kx - pad_x;
          if (ix < 0 || ix >= ti.w) continue;
          const float* px = in + (static_cast<size_t>(iy) * ti.w + ix) * ic_n;
          const float* wk = w + static_cast<size_t>(ky * k + kx) * ic_n * oc_n;
          for (int ic = 0; ic < ic_n; ic++) {
            const float v = px[ic];
            const float* wr = wk + static_cast<size_t>(ic) * oc_n;
            for (int oc = 0; oc < oc_n; oc++) o[oc] += v * wr[oc];
          }
        }
      }
    }
  }
}

// Kernel [1][K][K][C].
void DwConv(const float* in, const TensorInfo& ti, const float* w, int k,
            const float* bias, float* out, const TensorInfo& to, int stride,
            bool same) {
  const int c_n = ti.c;
  const int pad_y = same ? PadBefore(ti.h, to.h, k, stride) : 0;
  const int pad_x = same ? PadBefore(ti.w, to.w, k, stride) : 0;
  for (int oy = 0; oy < to.h; oy++) {
    for (int ox = 0; ox < to.w; ox++) {
      float* o = out + (static_cast<size_t>(oy) * to.w + ox) * c_n;
      std::copy(bias, bias + c_n, o);
      for (int ky = 0; ky < k; ky++) {
        const int iy = oy * stride + ky - pad_y;
        if (iy < 0 || iy >= ti.h) continue;
        for (int kx = 0; kx < k; kx++) {
          const int ix = ox * stride + kx - pad_x;
          if (ix < 0 || ix >= ti.w) continue;
          const float* px = in + (static_cast<size_t>(iy) * ti.w + ix) * c_n;
          const float* wk = w + static_cast<size_t>(ky * k + kx) * c_n;
          for (int c = 0; c < c_n; c++) o[c] += px[c] * wk[c];
        }
      }
    }
  }
}

// MediaPipe's Convolution2DTransposeBias with a 2x2 kernel and stride 2: each
// input pixel spreads into its own 2x2 block. Kernel [O][2][2][I].
void TConv(const float* in, const TensorInfo& ti, const float* w,
           const float* bias, float* out, const TensorInfo& to) {
  const int ic_n = ti.c, oc_n = to.c;
  for (int y = 0; y < ti.h; y++) {
    for (int x = 0; x < ti.w; x++) {
      const float* px = in + (static_cast<size_t>(y) * ti.w + x) * ic_n;
      for (int ky = 0; ky < 2; ky++) {
        for (int kx = 0; kx < 2; kx++) {
          float* o = out + (static_cast<size_t>(2 * y + ky) * to.w + 2 * x + kx) * oc_n;
          for (int oc = 0; oc < oc_n; oc++) {
            const float* wr = w + (static_cast<size_t>(oc) * 4 + ky * 2 + kx) * ic_n;
            float s = bias[oc];
            for (int ic = 0; ic < ic_n; ic++) s += px[ic] * wr[ic];
            o[oc] = s;
          }
        }
      }
    }
  }
}

// TFLite's ResizeBilinear with half pixel centers.
void Resize(const float* in, const TensorInfo& ti, float* out,
            const TensorInfo& to) {
  const float sy = static_cast<float>(ti.h) / to.h;
  const float sx = static_cast<float>(ti.w) / to.w;
  const int c_n = ti.c;
  for (int oy = 0; oy < to.h; oy++) {
    const float fy = (oy + 0.5f) * sy - 0.5f;
    const int y0 = std::max(static_cast<int>(std::floor(fy)), 0);
    const int y1 = std::min(static_cast<int>(std::ceil(fy)), ti.h - 1);
    const float dy = fy - y0;
    for (int ox = 0; ox < to.w; ox++) {
      const float fx = (ox + 0.5f) * sx - 0.5f;
      const int x0 = std::max(static_cast<int>(std::floor(fx)), 0);
      const int x1 = std::min(static_cast<int>(std::ceil(fx)), ti.w - 1);
      const float dx = fx - x0;
      const float* a = in + (static_cast<size_t>(y0) * ti.w + x0) * c_n;
      const float* b = in + (static_cast<size_t>(y0) * ti.w + x1) * c_n;
      const float* c = in + (static_cast<size_t>(y1) * ti.w + x0) * c_n;
      const float* d = in + (static_cast<size_t>(y1) * ti.w + x1) * c_n;
      float* o = out + (static_cast<size_t>(oy) * to.w + ox) * c_n;
      for (int ch = 0; ch < c_n; ch++) {
        o[ch] = a[ch] * (1 - dy) * (1 - dx) + b[ch] * (1 - dy) * dx +
                c[ch] * dy * (1 - dx) + d[ch] * dy * dx;
      }
    }
  }
}

// Same shapes, or the second (or first) a single 1x1xC vector applied to
// every pixel.
template <typename F>
void Binary(const float* a, const TensorInfo& ta, const float* b,
            const TensorInfo& tb, float* out, const TensorInfo& to, F f) {
  const int c_n = to.c;
  const size_t px = static_cast<size_t>(to.h) * to.w;
  const bool a_vec = ta.h * ta.w == 1 && px > 1;
  const bool b_vec = tb.h * tb.w == 1 && px > 1;
  for (size_t p = 0; p < px; p++) {
    const float* ar = a + (a_vec ? 0 : p * c_n);
    const float* br = b + (b_vec ? 0 : p * c_n);
    float* o = out + p * c_n;
    for (int c = 0; c < c_n; c++) o[c] = f(ar[c], br[c]);
  }
}

struct Model {
  std::vector<float> weights;  // all of kWeights as floats
  // Per op, the kernel rearranged for Conv, else empty.
  std::vector<std::vector<float>> kernels;

  Model() {
    constexpr size_t n = sizeof kWeights / sizeof kWeights[0];
    weights.resize(n);
    for (size_t i = 0; i < n; i++) weights[i] = HalfToFloat(kWeights[i]);
    for (const OpInfo& op : kOps) {
      kernels.emplace_back();
      if (op.kind != kConv) continue;
      const TensorInfo& w = kTensors[op.in1];
      const int o = w.count / (w.h * w.w * w.c);
      kernels.back() = Transposed(&weights[w.weight], o, w.h, w.c);
    }
  }
};

const Model& TheModel() {
  static const Model model;
  return model;
}

}  // namespace

SelfieSegmenter::SelfieSegmenter() {
  TheModel();
  for (const TensorInfo& t : kTensors) {
    values_.emplace_back(t.weight < 0 ? t.count : 0);
  }
}

const float* SelfieSegmenter::Run(const float* rgb) {
  const Model& m = TheModel();
  std::copy(rgb, rgb + kTensors[kInput].count, values_[kInput].begin());
  auto data = [&](int t) -> const float* {
    return kTensors[t].weight >= 0 ? &m.weights[kTensors[t].weight]
                                   : values_[t].data();
  };
  for (size_t n = 0; n < sizeof kOps / sizeof kOps[0]; n++) {
    const OpInfo& op = kOps[n];
    const TensorInfo& ti = kTensors[op.in0];
    const TensorInfo& to = kTensors[op.out];
    const float* in = data(op.in0);
    float* out = values_[op.out].data();
    const size_t count = static_cast<size_t>(to.count);
    switch (op.kind) {
      case kConv:
        Conv(in, ti, m.kernels[n].data(), kTensors[op.in1].h, data(op.in2),
             out, to, op.stride, op.same);
        break;
      case kDwConv:
        DwConv(in, ti, data(op.in1), kTensors[op.in1].h, data(op.in2), out,
               to, op.stride, op.same);
        break;
      case kTConv:
        TConv(in, ti, data(op.in1), data(op.in2), out, to);
        break;
      case kRelu:
        for (size_t i = 0; i < count; i++) out[i] = std::max(in[i], 0.0f);
        break;
      case kHSwish:
        for (size_t i = 0; i < count; i++) {
          out[i] = in[i] * std::min(std::max(in[i] + 3, 0.0f), 6.0f) / 6;
        }
        break;
      case kLogistic:
        for (size_t i = 0; i < count; i++) out[i] = 1 / (1 + std::exp(-in[i]));
        break;
      case kMean: {
        const size_t px = static_cast<size_t>(ti.h) * ti.w;
        std::fill(out, out + ti.c, 0.0f);
        for (size_t p = 0; p < px; p++)
          for (int c = 0; c < ti.c; c++) out[c] += in[p * ti.c + c];
        for (int c = 0; c < ti.c; c++) out[c] /= px;
        break;
      }
      case kAdd:
        Binary(in, ti, data(op.in1), kTensors[op.in1], out, to,
               [](float a, float b) { return a + b; });
        break;
      case kMul:
        Binary(in, ti, data(op.in1), kTensors[op.in1], out, to,
               [](float a, float b) { return a * b; });
        break;
      case kResize:
        Resize(in, ti, out, to);
        break;
    }
  }
  return values_[kOutput].data();
}

}  // namespace tala
