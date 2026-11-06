#!/usr/bin/env python3
"""Generates Tala's icons into assets/icon. Needs numpy and Pillow.

The app icon is a weathered Ansuz cut into flat blue. Small sizes use a plain
rough rune, because texture doesn't survive there.
"""
import random
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024
BLUE = (0, 130, 201)
PAINT = (226, 226, 214)


def noise(seed, octaves):
    r = np.random.default_rng(seed)
    out = np.zeros((S, S))
    for n, a in octaves:
        g = (r.random((n, n)) * 255).astype("uint8")
        out += a * np.asarray(Image.fromarray(g).resize((S, S), Image.BICUBIC), float) / 255
    out -= out.min()
    return out / out.max()


def blur(a, radius):
    im = Image.fromarray((np.clip(a, 0, 1) * 255).astype("uint8"))
    return np.asarray(im.filter(ImageFilter.GaussianBlur(radius)), float) / 255


def cut(d, a, b, wa, wb, rng, rough):
    """One chisel stroke: mostly straight, slow wander, a few real chips."""
    a, b = np.array(a, float), np.array(b, float)
    v = b - a
    u = v / np.linalg.norm(v)
    n = np.array([-u[1], u[0]])
    steps = 48

    def side():
        p1, p2 = rng.uniform(0, 6.3), rng.uniform(0, 6.3)
        out = []
        for i in range(steps + 1):
            t = i / steps
            e = rough * (1.1 * np.sin(t * 5 + p1) + 0.7 * np.sin(t * 11 + p2))
            if rng.random() < 0.07:
                e -= rng.uniform(rough, rough * 2.6)
            out.append(e)
        return out

    l, r = side(), side()
    left, right = [], []
    for i in range(steps + 1):
        t = i / steps
        w = (wa + (wb - wa) * t) / 2
        c = a + v * t
        left.append(c + n * (w + l[i]))
        right.append(c - n * (w + r[i]))
    start = a - u * wa * 0.45 + n * rng.uniform(-wa * 0.2, wa * 0.2)
    end = b + u * wb * 0.8 + n * rng.uniform(-wb * 0.25, wb * 0.25)
    d.polygon([tuple(p) for p in [start] + left + [end] + right[::-1]], fill=255)


def rune_mask(rough):
    """Ansuz: the stave sits left of centre to balance the rune, and each arm is
    its own cut that starts across the stave and slopes down to the right."""
    rng = random.Random(5)
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    c = S / 2
    p = lambda x, y: (c + x, c + y)
    cut(d, p(-108, -392), p(-92, 378), 118, 84, rng, rough)
    cut(d, p(-150, -318), p(232, -74), 90, 56, rng, rough)
    cut(d, p(-146, -92), p(226, 150), 86, 54, rng, rough)
    m = m.filter(ImageFilter.GaussianBlur(1.6)).point(lambda v: 255 if v > 118 else 0)
    return np.asarray(m, float) / 255


def rounded_alpha():
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle([6, 6, S - 7, S - 7], radius=int(S * 0.2), fill=255)
    return np.asarray(m.filter(ImageFilter.GaussianBlur(1.2)), float) / 255


def carved():
    mask = rune_mask(rough=5)
    field = np.ones((S, S, 3)) * np.array(BLUE, float)
    m = mask[..., None]
    grit = noise(31, ((64, 0.5), (128, 0.7), (256, 0.9), (512, 0.7)))[..., None]
    # V-groove: two facets meeting along the centre of each cut.
    gy, gx = np.gradient(blur(mask, 16))
    facet = np.clip((gx + gy) * 26, -1, 1)[..., None]
    floor = np.array(PAINT, float) * (0.74 + 0.34 * (grit - 0.5)) * (1 + facet * 0.42)
    # Old paint: dirt and the surface show through in patches.
    wear = noise(32, ((32, 0.6), (64, 0.8), (128, 0.8), (256, 0.6)))[..., None]
    worn = np.clip((wear - 0.56) * 3.2, 0, 0.78)
    floor = floor * (1 - worn) + field * 0.62 * worn
    out = field * (1 - m) + floor * m
    # Only the cut's own lip is shaded, so the surround stays flat blue.
    ly, lx = np.gradient(blur(mask, 3))
    out *= 1 + np.clip((lx + ly) * -5.5, -0.5, 0.55)[..., None]
    rgba = np.dstack([np.clip(out, 0, 255), rounded_alpha() * 255]).astype("uint8")
    return Image.fromarray(rgba, "RGBA")


def flat(size):
    big = size * 8
    mask = Image.fromarray((rune_mask(rough=3) * 255).astype("uint8")).resize((big, big), Image.LANCZOS)
    im = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.2), fill=BLUE + (255,))
    im.paste((255, 255, 255, 255), (0, 0), mask)
    return im.resize((size, size), Image.LANCZOS)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "assets/icon")
    out.mkdir(parents=True, exist_ok=True)
    app = carved()
    app.save(out / "tala.png")
    app.resize((512, 512), Image.LANCZOS).save(out / "tala-512.png")
    for size in (64, 48, 32, 24, 22, 16):
        flat(size).save(out / f"tala-small-{size}.png")


if __name__ == "__main__":
    main()
