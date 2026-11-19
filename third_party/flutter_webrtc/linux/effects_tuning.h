// The numbers behind background blur, pictures and touch up, shared by the
// CPU engine (background_blur.cc) and the GPU one (gpu_effects.cc), which
// must give the same pictures.

#ifndef TALA_EFFECTS_TUNING_H_
#define TALA_EFFECTS_TUNING_H_

namespace tala {
namespace tuning {

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

// With a picture behind the person, mask values below this count as
// background: the model's unsure fringe carries the real room's color, which
// shows as a halo against a different picture. Blurring hides it.
constexpr float kPictureCut = 0.3f;

// Touch up: each pixel of skin is pulled toward an edge-preserving smoothed
// copy of the picture (a guided filter at the guide's size), but only as far
// as it differs from it by a little: pores, blemishes and shine go, while
// eyes, brows, lips and the edges of hair and glasses differ by more and stay.
constexpr int kTouchRadius = 3;  // in guide pixels
constexpr float kTouchEps = 0.003f;
// Detail this strong, in Y levels, is half kept; much stronger is all kept.
constexpr float kTouchDetail = 10.0f;
// Skin's color, BT.601 limited range: the usual box of Cb 77 to 127 and Cr
// 133 to 173, which holds across skin tones, eased in over this many levels.
constexpr float kSkinSoft = 8.0f;
// The most of that pull the slider's top end gives: much more looks waxy,
// with the strongest specks left standing out.
constexpr float kTouchMost = 0.7f;

}  // namespace tuning
}  // namespace tala

#endif  // TALA_EFFECTS_TUNING_H_
