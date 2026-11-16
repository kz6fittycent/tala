#!/usr/bin/env python3
"""Draws the Snap Store's featured banner into docs/store/featured-banner.jpg.

    python3 tool/make_banner.py

Needs numpy, Pillow and the Ubuntu Sans font (Ubuntu's fonts-ubuntu). The
store wants 3:1, 720x240 to 4320x1440, JPEG or PNG under 2 MB; noise against banding makes a PNG too big. The window is
docs/screenshots/main-dark.png (invented people, from make_screenshots.dart)
and the card is cut from incoming-call.png, so rerun this after those change.
Marketing graphics keep the server's product name out (see CLAUDE.md).
"""
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'docs', 'store', 'featured-banner.jpg')
FONT = '/usr/share/fonts/truetype/ubuntu/UbuntuSans[wdth,wght].ttf'
W, H = 3000, 1000
BLUE = (0, 130, 201)


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_axes([100, weight])
    return f


def backdrop():
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    # Deep navy into the icon's blue toward the lower right, with a soft glow
    # behind the window.
    t = np.clip((x / W) * 0.7 + (y / H) * 0.3, 0, 1)
    a, b = np.array((7, 26, 44), np.float32), np.array((0, 84, 138), np.float32)
    img = a + (b - a) * t[..., None] ** 1.4
    glow = np.exp(-(((x - 2200) / 900) ** 2 + ((y - 520) / 520) ** 2))
    img += glow[..., None] * np.array((0, 60, 100), np.float32)
    # Fine noise against banding.
    img += np.random.default_rng(7).normal(0, 1.2, (H, W))[..., None]
    return Image.fromarray(np.clip(img + 0.5, 0, 255).astype(np.uint8)).convert('RGBA')


def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *img.size), radius, fill=255)
    out = img.convert('RGBA')
    out.putalpha(mask)
    return out


def shadow(size, radius, blur, alpha):
    pad = blur * 3
    s = Image.new('RGBA', (size[0] + 2 * pad, size[1] + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle(
        (pad, pad, pad + size[0], pad + size[1]), radius, fill=(0, 0, 0, alpha))
    return s.filter(ImageFilter.GaussianBlur(blur)), pad


def window(shot):
    """The screenshot in a plain dark title bar, as on a GNOME desktop."""
    bar = 44
    w, h = shot.size
    win = Image.new('RGB', (w, h + bar), (36, 38, 41))
    d = ImageDraw.Draw(win)
    d.text((w / 2, bar / 2), 'Tala', font=font(20, 600), fill=(225, 225, 225),
           anchor='mm')
    # Close button, as Adwaita draws it.
    cx, cy = w - 26, bar / 2
    d.ellipse((cx - 12, cy - 12, cx + 12, cy + 12), fill=(60, 62, 66))
    d.line((cx - 5, cy - 5, cx + 5, cy + 5), fill=(225, 225, 225), width=2)
    d.line((cx - 5, cy + 5, cx + 5, cy - 5), fill=(225, 225, 225), width=2)
    win.paste(shot, (0, bar))
    return rounded(win, 14)


def paste_with_shadow(base, img, x, y, radius, blur=40, alpha=150, dy=24):
    s, pad = shadow(img.size, radius, blur, alpha)
    base.alpha_composite(s, (x - pad, y - pad + dy))
    base.alpha_composite(img, (x, y))


def main():
    base = backdrop()
    shots = os.path.join(ROOT, 'docs', 'screenshots')

    win = window(Image.open(os.path.join(shots, 'main-dark.png')).convert('RGB'))
    wx, wy = W - win.width - 150, (H - win.height) // 2
    paste_with_shadow(base, win, wx, wy, 14)

    # The incoming call card, floating over the window's lower left corner.
    card = Image.open(os.path.join(shots, 'incoming-call.png')).convert('RGB')
    card = card.crop((412, 258, 688, 442))
    card = rounded(card.resize((card.width * 3 // 2, card.height * 3 // 2),
                               Image.Resampling.LANCZOS), 44)
    paste_with_shadow(base, card, wx - 170, wy + win.height - card.height + 60,
                      44, blur=36, alpha=170)

    icon = Image.open(os.path.join(ROOT, 'assets', 'icon', 'tala-512.png'))
    icon = icon.convert('RGBA').resize((250, 250), Image.Resampling.LANCZOS)
    left = 170
    s, pad = shadow(icon.size, 50, 24, 120)
    base.alpha_composite(s, (left - pad, 230 - pad + 14))
    base.alpha_composite(icon, (left, 230))

    d = ImageDraw.Draw(base)
    d.text((left + 300, 355), 'Tala', font=font(210, 700), fill='white',
           anchor='lm')
    d.text((left, 600), 'Chat and video calls', font=font(76, 600),
           fill='white')
    d.text((left, 690), 'on your Linux desktop', font=font(76, 600),
           fill='white')
    d.text((left, 815), 'Screen sharing · Backgrounds · Polls',
           font=font(44, 400), fill=(170, 205, 230))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    base.convert('RGB').save(OUT, quality=93, optimize=True, subsampling=0)
    print(OUT, os.path.getsize(OUT) // 1024, 'KB')


if __name__ == '__main__':
    main()
