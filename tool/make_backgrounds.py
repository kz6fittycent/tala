"""Draws Tala's built-in call backgrounds into assets/backgrounds/.

    python3 tool/make_backgrounds.py

Needs numpy and Pillow. Every picture is drawn here from numbers alone, so
they're Tala's own: no photos, no one else's art. The same seed always gives
the same pictures. Each is 1920x1080 JPEG plus a 320x180 thumbnail for the
picker.
"""
import os

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'assets', 'backgrounds')
W, H = 1920, 1080


def grid():
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    return x / W, y / H


def lerp(a, b, t):
    a, b = np.asarray(a, np.float32), np.asarray(b, np.float32)
    return a + (b - a) * t[..., None]


def bokeh(img, rng, count, colors, rmin, rmax, alpha, blur):
    """Soft out-of-focus discs, as lights behind a camera's focus."""
    layer = np.zeros((H, W, 3), np.float32)
    weight = np.zeros((H, W), np.float32)
    x, y = grid()
    x, y = x * W, y * H
    for _ in range(count):
        cx, cy = rng.uniform(0, W), rng.uniform(0, H)
        r = rng.uniform(rmin, rmax)
        c = np.asarray(colors[rng.integers(len(colors))], np.float32)
        d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
        disc = np.clip((r - d) / 3, 0, 1) * rng.uniform(0.5, 1.0)
        layer += disc[..., None] * c
        weight += disc
    soft = Image.fromarray(np.clip(layer, 0, 255).astype(np.uint8))
    soft = np.asarray(soft.filter(ImageFilter.GaussianBlur(blur)), np.float32)
    wsoft = Image.fromarray(np.clip(weight * 255, 0, 255).astype(np.uint8))
    wsoft = np.asarray(wsoft.filter(ImageFilter.GaussianBlur(blur)),
                       np.float32)[..., None] / 255
    return img * (1 - wsoft * alpha) + soft * alpha


def vignette(img, strength):
    x, y = grid()
    d = np.sqrt((x - 0.5) ** 2 + ((y - 0.5) * H / W) ** 2) / 0.6
    return img * (1 - strength * np.clip(d, 0, 1) ** 2)[..., None]


def grain(img, rng, amount):
    # A little noise keeps the gradients from banding once encoded.
    return img + rng.normal(0, amount, img.shape[:2])[..., None]


def sky_blue(rng):
    x, y = grid()
    img = lerp((18, 92, 150), (150, 205, 235), np.clip(1 - y * 0.9 - x * 0.3, 0, 1))
    img = bokeh(img, rng, 26, [(255, 255, 255), (200, 235, 255)], 30, 110, 0.35, 14)
    return grain(vignette(img, 0.25), rng, 1.5)


def warm_wall(rng):
    x, y = grid()
    # A plain painted wall lit from the upper left.
    light = np.clip(1.15 - np.sqrt((x - 0.2) ** 2 + (y - 0.1) ** 2) * 0.9, 0, 1)
    img = lerp((150, 128, 108), (232, 214, 190), light)
    return grain(vignette(img, 0.2), rng, 2.0)


def dusk_hills(rng):
    x, y = grid()
    sky = lerp((250, 170, 110), (60, 70, 130), np.clip(1 - y * 1.6, 0, 1) ** 1.3)
    img = sky
    layers = [(0.55, (95, 80, 120)), (0.66, (70, 60, 100)),
              (0.78, (45, 42, 75)), (0.9, (28, 28, 52))]
    for base, color in layers:
        phase = rng.uniform(0, 6.3, 3)
        ridge = (base
                 + 0.04 * np.sin(x * 5.0 + phase[0])
                 + 0.02 * np.sin(x * 13.0 + phase[1])
                 + 0.008 * np.sin(x * 37.0 + phase[2]))
        hill = np.clip((y - ridge) * H / 2, 0, 1)
        img = img * (1 - hill[..., None]) + np.asarray(color, np.float32) * hill[..., None]
    return grain(img, rng, 1.5)


def night_lights(rng):
    x, y = grid()
    img = lerp((14, 18, 32), (30, 40, 66), np.clip(y, 0, 1))
    img = bokeh(img, rng, 40, [(255, 196, 120), (255, 150, 90), (120, 190, 255),
                               (255, 230, 180)], 18, 70, 0.8, 10)
    return grain(vignette(img, 0.3), rng, 1.5)


def green_leaves(rng):
    x, y = grid()
    img = lerp((40, 80, 45), (120, 160, 90), np.clip(1 - y * 0.8 + x * 0.2, 0, 1))
    img = bokeh(img, rng, 60, [(60, 110, 50), (150, 190, 100), (30, 70, 40)],
                40, 150, 0.7, 22)
    img = bokeh(img, rng, 18, [(250, 245, 210)], 15, 45, 0.45, 8)
    return grain(vignette(img, 0.25), rng, 1.5)


# Order is the picker's; names are stored in settings, so keep them.
PICTURES = [
    ('sky', sky_blue),
    ('wall', warm_wall),
    ('hills', dusk_hills),
    ('leaves', green_leaves),
    ('lights', night_lights),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    for i, (name, draw) in enumerate(PICTURES):
        rng = np.random.default_rng(2026 + i)
        img = Image.fromarray(np.clip(draw(rng) + 0.5, 0, 255).astype(np.uint8))
        img.save(os.path.join(OUT, f'{name}.jpg'), quality=86, optimize=True,
                 progressive=True)
        img.resize((320, 180), Image.LANCZOS).save(
            os.path.join(OUT, f'{name}-small.jpg'), quality=85, optimize=True)
        print(name)


if __name__ == '__main__':
    main()
