#include "gpu_effects.h"

#include <epoxy/egl.h>
#include <epoxy/gl.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <map>
#include <utility>

#include "effects_tuning.h"

namespace tala {
namespace {

using namespace tuning;

// Whether a space-separated extension list has `word`.
bool HasWord(const char* list, const char* word) {
  if (!list) return false;
  const size_t n = std::strlen(word);
  for (const char* s = list; (s = std::strstr(s, word)); s += n) {
    if ((s == list || s[-1] == ' ') && (s[n] == ' ' || s[n] == '\0')) {
      return true;
    }
  }
  return false;
}

// Renderers that run on the CPU: slower than background_blur.cc's own code.
bool IsSoftware(std::string name) {
  for (char& c : name) c = static_cast<char>(std::tolower(c));
  for (const char* word :
       {"llvmpipe", "softpipe", "swiftshader", "software", "lavapipe"}) {
    if (name.find(word) != std::string::npos) return true;
  }
  return false;
}

// One triangle over the whole target; each pass works per output pixel.
const char* kVertex = R"(#version 300 es
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

// Shared by every pass. Sampling is by texelFetch only, with the same
// arithmetic as background_blur.cc, rather than the GPU's own filtering,
// whose precision varies by GPU.
const char* kCommon = R"(#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
layout(location = 0) out vec4 o;

ivec2 here() { return ivec2(gl_FragCoord.xy); }

// background_blur.cc's Axis: the neighbors and the upper one's weight for
// output i of `to`, along an axis `from` long, half pixel centers.
void axis(int i, int to, int from, out int lo, out int hi, out float fr) {
  float scale = float(from) / float(to);
  float f = clamp((float(i) + 0.5) * scale - 0.5, 0.0, float(from - 1));
  lo = min(int(f), max(from - 2, 0));
  hi = min(lo + 1, from - 1);
  fr = from > 1 ? f - float(lo) : 0.0;
}

// Bilinear, as Resample and Blend do it: down the columns first.
float bilerp(sampler2D t, ivec2 p, ivec2 to) {
  ivec2 from = textureSize(t, 0);
  int x0, x1, y0, y1;
  float fx, fy;
  axis(p.x, to.x, from.x, x0, x1, fx);
  axis(p.y, to.y, from.y, y0, y1, fy);
  float a0 = texelFetch(t, ivec2(x0, y0), 0).r;
  float b0 = texelFetch(t, ivec2(x0, y1), 0).r;
  float a1 = texelFetch(t, ivec2(x1, y0), 0).r;
  float b1 = texelFetch(t, ivec2(x1, y1), 0).r;
  float r0 = a0 + (b0 - a0) * fy;
  float r1 = a1 + (b1 - a1) * fy;
  return r0 + (r1 - r0) * fx;
}

// A plane's byte, 0 to 255, from an 8-bit texture.
float byte(sampler2D t, ivec2 p) {
  return floor(texelFetch(t, p, 0).r * 255.0 + 0.5);
}

float clamp8(float v) { return floor(clamp(v + 0.5, 0.0, 255.0)); }
)";

// Shrink: averages `factor` by `factor` blocks of bytes, divided by `div`.
const char* kShrink = R"(
uniform sampler2D src;
uniform int factor;
uniform float div;
void main() {
  ivec2 p = here();
  ivec2 s = textureSize(src, 0);
  int x0 = p.x * factor, y0 = p.y * factor;
  int x1 = min(x0 + factor, s.x), y1 = min(y0 + factor, s.y);
  float sum = 0.0;
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1; x++) sum += byte(src, ivec2(x, y));
  }
  o = vec4(sum / float((x1 - x0) * (y1 - y0)) / div, 0.0, 0.0, 0.0);
}
)";

// Resample: a float plane scaled to the target's size.
const char* kResample = R"(
uniform sampler2D src;
uniform ivec2 to;
void main() { o = vec4(bilerp(src, here(), to), 0.0, 0.0, 0.0); }
)";

// The guided filter's four inputs, to be box blurred together.
const char* kGuidePack = R"(
uniform sampler2D g;
uniform sampler2D p;
void main() {
  float a = texelFetch(g, here(), 0).r, b = texelFetch(p, here(), 0).r;
  o = vec4(a, b, a * a, a * b);
}
)";

// Box blur along `dir`, clamping at the edges.
const char* kBox = R"(
uniform sampler2D src;
uniform int r;
uniform ivec2 dir;
void main() {
  ivec2 p = here();
  ivec2 last = textureSize(src, 0) - 1;
  vec4 sum = vec4(0.0);
  for (int k = -r; k <= r; k++) {
    sum += texelFetch(src, clamp(p + dir * k, ivec2(0), last), 0);
  }
  o = sum * (1.0 / float(2 * r + 1));
}
)";

// Each window's a and b, from the blurred means.
const char* kGuideAb = R"(
uniform sampler2D m;
uniform float eps;
void main() {
  vec4 v = texelFetch(m, here(), 0);
  float a = (v.w - v.x * v.y) / (v.z - v.x * v.x + eps);
  o = vec4(a, v.y - a * v.x, 0.0, 0.0);
}
)";

// The filtered result; `curve` adds the gentle S-curve.
const char* kGuideOut = R"(
uniform sampler2D ab;
uniform sampler2D g;
uniform int curve;
void main() {
  vec2 c = texelFetch(ab, here(), 0).rg;
  float q = clamp(c.x * texelFetch(g, here(), 0).r + c.y, 0.0, 1.0);
  if (curve == 1) q = q * q * (3.0 - 2.0 * q);
  o = vec4(q, 0.0, 0.0, 0.0);
}
)";

// With a picture, the mask's unsure fringe counts as background.
const char* kCut = R"(
uniform sampler2D src;
uniform float cut;
void main() {
  float q = texelFetch(src, here(), 0).r;
  o = vec4(max(0.0, (q - cut) / (1.0 - cut)), 0.0, 0.0, 0.0);
}
)";

// Touch up, into an 8-bit brightness plane.
const char* kTouch = R"(
uniform sampler2D ys;
uniform sampler2D us;
uniform sampler2D vs;
uniform sampler2D smooth_;
uniform sampler2D person;
uniform float amount;
uniform float inv;
uniform float soft;
float ramp(float v, float lo, float hi) {
  float d = max(lo - v, v - hi);
  return d <= 0.0 ? 1.0 : d >= soft ? 0.0 : 1.0 - d / soft;
}
void main() {
  ivec2 p = here();
  ivec2 size = textureSize(ys, 0);
  float y = byte(ys, p);
  ivec2 c = p / 2;
  float s = amount * ramp(byte(us, c), 77.0, 127.0) *
            ramp(byte(vs, c), 133.0, 173.0);
  float v = y;
  if (s > 0.0) {
    float w = s * bilerp(person, p, size);
    if (w >= 0.01) {
      float d = y - 255.0 * bilerp(smooth_, p, size);
      float t = d * d * inv;
      v = clamp8(y - w * d / (1.0 + t * t));
    }
  }
  o = vec4(v / 255.0, 0.0, 0.0, 0.0);
}
)";

// A small plane weighted by how much each pixel is background.
const char* kWeigh = R"(
uniform sampler2D small;
uniform sampler2D refined;
void main() {
  ivec2 p = here();
  float w = 1.0 - bilerp(refined, p, textureSize(small, 0));
  o = vec4(texelFetch(small, p, 0).r * w, w, 0.0, 0.0);
}
)";

// The blurred background, unweighted again.
const char* kUnweigh = R"(
uniform sampler2D acc;
uniform float fallback;
void main() {
  vec2 v = texelFetch(acc, here(), 0).rg;
  o = vec4(v.y > 1e-3 ? v.x / v.y : fallback, 0.0, 0.0, 0.0);
}
)";

// The person from `plane`, the rest from `bg`, four pixels to a texel so the
// result reads back as the plane's own bytes.
const char* kBlend = R"(
uniform sampler2D plane;
uniform sampler2D bg;
uniform sampler2D refined;
uniform int width;
void main() {
  ivec2 p = here();
  ivec2 size = ivec2(width, textureSize(plane, 0).y);
  vec4 r = vec4(0.0);
  for (int k = 0; k < 4; k++) {
    ivec2 q = ivec2(p.x * 4 + k, p.y);
    if (q.x >= width) break;
    float in_ = byte(plane, q);
    float m = bilerp(refined, q, size);
    float v = in_;
    if (m < 0.999) {
      float b = bilerp(bg, q, size);
      v = clamp8(b + (in_ - b) * m);
    }
    r[k] = v / 255.0;
  }
  o = r;
}
)";

// A plane as it is, four pixels to a texel.
const char* kPack = R"(
uniform sampler2D plane;
uniform int width;
void main() {
  ivec2 p = here();
  vec4 r = vec4(0.0);
  for (int k = 0; k < 4; k++) {
    ivec2 q = ivec2(p.x * 4 + k, p.y);
    if (q.x >= width) break;
    r[k] = byte(plane, q) / 255.0;
  }
  o = r;
}
)";

GLuint Compile(GLenum type, const std::string& source, std::string* log) {
  GLuint s = glCreateShader(type);
  const char* text = source.c_str();
  glShaderSource(s, 1, &text, nullptr);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char buf[512] = {};
    glGetShaderInfoLog(s, sizeof buf, nullptr, buf);
    *log = buf;
    glDeleteShader(s);
    return 0;
  }
  return s;
}

}  // namespace

struct GpuEffects::Impl {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  GLuint vao = 0;
  std::map<std::string, GLuint> programs;
  GLuint program = 0;  // the one in use
  int unit = 0;        // its next texture unit

  struct Tex {
    GLuint tex = 0, fbo = 0;
    int w = 0, h = 0;
    GLenum format = 0;
  };
  std::map<std::string, Tex> textures;
  int picture_version = -1, picture_w = 0, picture_h = 0;
  std::vector<uint8_t> readback;
  bool broken = false;

  ~Impl() {
    // Freeing the context frees everything made in it. It's never current
    // here: Apply lets go of it each frame.
    if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
  }

  bool Build(std::string* why) {
    std::string log;
    GLuint vs = Compile(GL_VERTEX_SHADER, kVertex, &log);
    if (!vs) {
      *why = "vertex shader didn't build: " + log;
      return false;
    }
    const std::pair<const char*, const char*> sources[] = {
        {"shrink", kShrink},   {"resample", kResample}, {"pack_g", kGuidePack},
        {"box", kBox},         {"ab", kGuideAb},        {"guided", kGuideOut},
        {"touch", kTouch},     {"weigh", kWeigh},       {"unweigh", kUnweigh},
        {"blend", kBlend},     {"pack", kPack},         {"cut", kCut}};
    for (const auto& s : sources) {
      GLuint fs = Compile(GL_FRAGMENT_SHADER, std::string(kCommon) + s.second,
                          &log);
      if (!fs) {
        *why = std::string(s.first) + " shader didn't build: " + log;
        return false;
      }
      GLuint p = glCreateProgram();
      glAttachShader(p, vs);
      glAttachShader(p, fs);
      glLinkProgram(p);
      glDeleteShader(fs);
      GLint ok = 0;
      glGetProgramiv(p, GL_LINK_STATUS, &ok);
      if (!ok) {
        *why = std::string(s.first) + " shader didn't link";
        return false;
      }
      programs[s.first] = p;
    }
    glDeleteShader(vs);
    glGenVertexArrays(1, &vao);
    return glGetError() == GL_NO_ERROR;
  }

  // A texture by name at this size and format, made or remade as needed;
  // with `target`, also something to draw into.
  Tex& Texture(const std::string& name, int w, int h, GLenum format,
               bool target) {
    Tex& t = textures[name];
    if (t.w != w || t.h != h || t.format != format) {
      if (t.fbo) glDeleteFramebuffers(1, &t.fbo);
      if (t.tex) glDeleteTextures(1, &t.tex);
      t = Tex();
      glGenTextures(1, &t.tex);
      glBindTexture(GL_TEXTURE_2D, t.tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, format, w, h);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      t.w = w;
      t.h = h;
      t.format = format;
    }
    if (target && !t.fbo) {
      glGenFramebuffers(1, &t.fbo);
      glBindFramebuffer(GL_FRAMEBUFFER, t.fbo);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_TEXTURE_2D, t.tex, 0);
      if (glCheckFramebufferStatus(GL_FRAMEBUFFER) !=
          GL_FRAMEBUFFER_COMPLETE) {
        broken = true;
      }
    }
    return t;
  }

  Tex& Target(const std::string& name, int w, int h, GLenum format) {
    return Texture(name, w, h, format, true);
  }

  // Copies a plane of bytes in, rows `stride` apart.
  Tex& UploadBytes(const std::string& name, const uint8_t* data, int w, int h,
                   int stride) {
    Tex& t = Texture(name, w, h, GL_R8, false);
    glBindTexture(GL_TEXTURE_2D, t.tex);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, stride);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RED, GL_UNSIGNED_BYTE,
                    data);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    return t;
  }

  Tex& UploadFloats(const std::string& name, const float* data, int w, int h) {
    Tex& t = Texture(name, w, h, GL_R32F, false);
    glBindTexture(GL_TEXTURE_2D, t.tex);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RED, GL_FLOAT, data);
    return t;
  }

  void Use(const char* name) {
    program = programs[name];
    unit = 0;
    glUseProgram(program);
  }
  void Input(const char* name, const Tex& t) {
    glActiveTexture(GL_TEXTURE0 + unit);
    glBindTexture(GL_TEXTURE_2D, t.tex);
    glUniform1i(glGetUniformLocation(program, name), unit++);
  }
  void Int(const char* name, int v) {
    glUniform1i(glGetUniformLocation(program, name), v);
  }
  void Ints(const char* name, int a, int b) {
    glUniform2i(glGetUniformLocation(program, name), a, b);
  }
  void Float(const char* name, float v) {
    glUniform1f(glGetUniformLocation(program, name), v);
  }
  void Draw(const Tex& target) {
    glBindFramebuffer(GL_FRAMEBUFFER, target.fbo);
    glViewport(0, 0, target.w, target.h);
    glBindVertexArray(vao);
    glDrawArrays(GL_TRIANGLES, 0, 3);
  }

  // Box blurs `t` in place, through `tmp` of the same size and format.
  void Box(Tex& t, Tex& tmp, int r) {
    Use("box");
    Input("src", t);
    Int("r", r);
    Ints("dir", 1, 0);
    Draw(tmp);
    Use("box");
    Input("src", tmp);
    Int("r", r);
    Ints("dir", 0, 1);
    Draw(t);
  }

  // He, Sun and Tang's guided filter of `p` by `g`, into `out`.
  Tex& Guided(const Tex& g, const Tex& p, int r, float eps, bool curve,
              const std::string& out) {
    const int w = g.w, h = g.h;
    Tex& pack = Target("gf_pack", w, h, GL_RGBA32F);
    Tex& tmp = Target("gf_tmp", w, h, GL_RGBA32F);
    Tex& ab = Target("gf_ab", w, h, GL_RGBA32F);
    Use("pack_g");
    Input("g", g);
    Input("p", p);
    Draw(pack);
    Box(pack, tmp, r);
    Use("ab");
    Input("m", pack);
    Float("eps", eps);
    Draw(ab);
    Box(ab, tmp, r);
    Tex& result = Target(out, w, h, GL_R32F);
    Use("guided");
    Input("ab", ab);
    Input("g", g);
    Int("curve", curve ? 1 : 0);
    Draw(result);
    return result;
  }

  // Reads a packed plane back into `out` (w by h, rows packed).
  void ReadBack(const Tex& packed, int w, int h, uint8_t* out) {
    glBindFramebuffer(GL_FRAMEBUFFER, packed.fbo);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    if (packed.w * 4 == w) {
      glReadPixels(0, 0, packed.w, h, GL_RGBA, GL_UNSIGNED_BYTE, out);
      return;
    }
    readback.resize(static_cast<size_t>(packed.w) * 4 * h);
    glReadPixels(0, 0, packed.w, h, GL_RGBA, GL_UNSIGNED_BYTE,
                 readback.data());
    for (int y = 0; y < h; y++) {
      std::memcpy(out + static_cast<size_t>(y) * w,
                  readback.data() + static_cast<size_t>(y) * packed.w * 4, w);
    }
  }
};

namespace {

// A context on one display, or null with the reason.
std::unique_ptr<GpuEffects::Impl> TryDisplay(EGLDisplay display,
                                             std::string* renderer,
                                             std::string* why) {
  EGLint major = 0, minor = 0;
  if (!eglInitialize(display, &major, &minor)) {
    *why = "EGL wouldn't start";
    return nullptr;
  }
  const char* ext = eglQueryString(display, EGL_EXTENSIONS);
  if (!HasWord(ext, "EGL_KHR_surfaceless_context")) {
    *why = "no window-less contexts";
    return nullptr;
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) {
    *why = "no OpenGL ES";
    return nullptr;
  }
  EGLConfig config = EGL_NO_CONFIG_KHR;
  if (!HasWord(ext, "EGL_KHR_no_config_context")) {
    // Any surface type: nothing is ever drawn to a surface.
    const EGLint want[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                           EGL_SURFACE_TYPE, 0, EGL_NONE};
    EGLint n = 0;
    if (!eglChooseConfig(display, want, &config, 1, &n) || n < 1) {
      *why = "no OpenGL ES 3";
      return nullptr;
    }
  }
  const EGLint attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
  auto impl = std::make_unique<GpuEffects::Impl>();
  impl->display = display;
  impl->context = eglCreateContext(display, config, EGL_NO_CONTEXT, attrs);
  if (impl->context == EGL_NO_CONTEXT) {
    *why = "no OpenGL ES 3 context";
    return nullptr;
  }
  if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                      impl->context)) {
    *why = "context wouldn't start";
    return nullptr;
  }
  struct Release {
    EGLDisplay d;
    ~Release() {
      eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
  } release{display};
  const GLubyte* name = glGetString(GL_RENDERER);
  *renderer = name ? reinterpret_cast<const char*>(name) : "unknown";
  if (IsSoftware(*renderer)) {
    *why = "only a software renderer (" + *renderer + ")";
    return nullptr;
  }
  if (epoxy_is_desktop_gl() || epoxy_gl_version() < 30) {
    *why = "no OpenGL ES 3 on " + *renderer;
    return nullptr;
  }
  if (!epoxy_has_gl_extension("GL_EXT_color_buffer_float")) {
    *why = "no float targets on " + *renderer;
    return nullptr;
  }
  if (!impl->Build(why)) {
    *why += " on " + *renderer;
    return nullptr;
  }
  return impl;
}

}  // namespace

std::unique_ptr<GpuEffects> GpuEffects::Create(std::string* why) {
  if (!epoxy_has_egl()) {
    *why = "no EGL library";
    return nullptr;
  }
  const char* client = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
  if (!HasWord(client, "EGL_EXT_platform_base")) {
    *why = "no EGL driver with window-less displays";
    return nullptr;
  }
  std::vector<EGLDisplay> displays;
  // GPUs themselves (NVIDIA's driver, newer Mesa), skipping Mesa's software
  // one; then Mesa's window-less display, which picks a GPU itself.
  if (HasWord(client, "EGL_EXT_platform_device") &&
      HasWord(client, "EGL_EXT_device_enumeration")) {
    EGLDeviceEXT devices[8];
    EGLint n = 0;
    if (eglQueryDevicesEXT(8, devices, &n)) {
      for (EGLint i = 0; i < n; i++) {
        const char* ext = eglQueryDeviceStringEXT(devices[i], EGL_EXTENSIONS);
        if (HasWord(ext, "EGL_MESA_device_software")) continue;
        EGLDisplay d = eglGetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT,
                                                devices[i], nullptr);
        if (d != EGL_NO_DISPLAY) displays.push_back(d);
      }
    }
  }
  if (HasWord(client, "EGL_MESA_platform_surfaceless")) {
    EGLDisplay d = eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA,
                                            EGL_DEFAULT_DISPLAY, nullptr);
    if (d != EGL_NO_DISPLAY) displays.push_back(d);
  }
  *why = "no GPU found";
  for (EGLDisplay d : displays) {
    std::string renderer;
    auto impl = TryDisplay(d, &renderer, why);
    if (impl) {
      std::unique_ptr<GpuEffects> gpu(new GpuEffects());
      gpu->impl_ = std::move(impl);
      gpu->renderer_ = renderer;
      return gpu;
    }
  }
  return nullptr;
}

GpuEffects::~GpuEffects() = default;

bool GpuEffects::Apply(const I420& in, const Look& look, uint8_t* out_y,
                       uint8_t* out_u, uint8_t* out_v) {
  Impl& g = *impl_;
  if (g.broken) return false;
  if (!eglMakeCurrent(g.display, EGL_NO_SURFACE, EGL_NO_SURFACE, g.context)) {
    return false;
  }
  struct Release {
    EGLDisplay d;
    ~Release() {
      eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
  } release{g.display};
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

  const int w = in.width, h = in.height;
  const int cw = (w + 1) / 2, ch = (h + 1) / 2;
  const int gf = std::max(1, w / kGuideWidth);
  const int gw = (w + gf - 1) / gf, gh = (h + gf - 1) / gf;
  using Tex = Impl::Tex;
  Tex& y = g.UploadBytes("y", in.y, w, h, in.stride_y);
  Tex& u = g.UploadBytes("u", in.u, cw, ch, in.stride_u);
  Tex& v = g.UploadBytes("v", in.v, cw, ch, in.stride_v);
  Tex& mask = g.UploadFloats("mask", look.mask, look.mask_width,
                             look.mask_height);

  // The model's mask, refined against the picture's brightness.
  Tex& guide = g.Target("guide", gw, gh, GL_R32F);
  g.Use("shrink");
  g.Input("src", y);
  g.Int("factor", gf);
  g.Float("div", 255.0f);
  g.Draw(guide);
  Tex& coarse = g.Target("coarse", gw, gh, GL_R32F);
  g.Use("resample");
  g.Input("src", mask);
  g.Ints("to", gw, gh);
  g.Draw(coarse);
  Tex& refined = g.Guided(guide, coarse, kGuideRadius, kGuideEps, true,
                          "refined");

  const Tex* luma = &y;
  if (look.touch_up > 0) {
    Tex& smooth =
        g.Guided(guide, guide, kTouchRadius, kTouchEps, false, "smooth");
    Tex& touched = g.Target("touched", w, h, GL_R8);
    g.Use("touch");
    g.Input("ys", y);
    g.Input("us", u);
    g.Input("vs", v);
    g.Input("smooth_", smooth);
    g.Input("person", refined);
    g.Float("amount", kTouchMost * look.touch_up);
    g.Float("inv", 1 / (kTouchDetail * kTouchDetail));
    g.Float("soft", kSkinSoft);
    g.Draw(touched);
    luma = &touched;
  }

  const Tex* planes[3] = {luma, &u, &v};
  const int widths[3] = {w, cw, cw}, heights[3] = {h, ch, ch};
  uint8_t* outs[3] = {out_y, out_u, out_v};
  const char* names[3] = {"0", "1", "2"};

  if (!look.picture && !look.blur) {
    // Only touch up: the brightness comes back, the color is as it was.
    if (luma != &y) {
      Tex& packed = g.Target("out0", (w + 3) / 4, h, GL_RGBA8);
      g.Use("pack");
      g.Input("plane", *luma);
      g.Int("width", w);
      g.Draw(packed);
      g.ReadBack(packed, w, h, out_y);
    } else {
      for (int r = 0; r < h; r++) {
        std::memcpy(out_y + static_cast<size_t>(r) * w,
                    in.y + static_cast<size_t>(r) * in.stride_y, w);
      }
    }
    for (int r = 0; r < ch; r++) {
      std::memcpy(out_u + static_cast<size_t>(r) * cw,
                  in.u + static_cast<size_t>(r) * in.stride_u, cw);
      std::memcpy(out_v + static_cast<size_t>(r) * cw,
                  in.v + static_cast<size_t>(r) * in.stride_v, cw);
    }
    return !g.broken && glGetError() == GL_NO_ERROR;
  }

  Tex* backgrounds[3] = {};
  Tex* person = &refined;
  if (look.picture) {
    // After touch up, as on the CPU, which used the mask before the cut.
    Tex& cut = g.Target("refined_cut", gw, gh, GL_R32F);
    g.Use("cut");
    g.Input("src", refined);
    g.Float("cut", kPictureCut);
    g.Draw(cut);
    person = &cut;
    if (g.picture_version != look.picture_version || g.picture_w != w ||
        g.picture_h != h) {
      for (int i = 0; i < 3; i++) {
        g.UploadFloats(std::string("picture") + names[i],
                       look.picture[i].data(), widths[i], heights[i]);
      }
      g.picture_version = look.picture_version;
      g.picture_w = w;
      g.picture_h = h;
    }
    for (int i = 0; i < 3; i++) {
      backgrounds[i] = &g.textures[std::string("picture") + names[i]];
    }
  } else {
    const int factor = std::max(1, w / kSmallWidth);
    for (int i = 0; i < 3; i++) {
      // As background_blur.cc: shrink, weigh by background, blur, unweigh.
      const int f = i == 0 ? factor : std::max(1, factor / 2);
      const int sw = (widths[i] + f - 1) / f, sh = (heights[i] + f - 1) / f;
      const int scale = i == 0 ? factor : 2 * f;
      const int r = std::max(1, (kBlurRadius * factor + scale / 2) / scale);
      const std::string n = names[i];
      Tex& small = g.Target("small" + n, sw, sh, GL_R32F);
      g.Use("shrink");
      g.Input("src", *planes[i]);
      g.Int("factor", f);
      g.Float("div", 1.0f);
      g.Draw(small);
      Tex& acc = g.Target("acc" + n, sw, sh, GL_RGBA32F);
      Tex& tmp = g.Target("acc_tmp" + n, sw, sh, GL_RGBA32F);
      g.Use("weigh");
      g.Input("small", small);
      g.Input("refined", refined);
      g.Draw(acc);
      for (int p = 0; p < kBlurPasses; p++) g.Box(acc, tmp, r);
      Tex& bg = g.Target("bg" + n, sw, sh, GL_R32F);
      g.Use("unweigh");
      g.Input("acc", acc);
      g.Float("fallback", i == 0 ? 16.0f : 128.0f);
      g.Draw(bg);
      backgrounds[i] = &bg;
    }
  }
  Tex* packed[3];
  for (int i = 0; i < 3; i++) {
    packed[i] = &g.Target(std::string("out") + names[i], (widths[i] + 3) / 4,
                          heights[i], GL_RGBA8);
    g.Use("blend");
    g.Input("plane", *planes[i]);
    g.Input("bg", *backgrounds[i]);
    g.Input("refined", *person);
    g.Int("width", widths[i]);
    g.Draw(*packed[i]);
  }
  for (int i = 0; i < 3; i++) {
    g.ReadBack(*packed[i], widths[i], heights[i], outs[i]);
  }
  return !g.broken && glGetError() == GL_NO_ERROR;
}

}  // namespace tala
