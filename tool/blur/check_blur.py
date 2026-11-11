"""Times Tala's background blur and draws its result on a picture.

    /tmp/v/bin/pip install numpy pillow
    /tmp/v/bin/python tool/blur/check_blur.py picture.jpg out-dir

Writes blur-<width>x<height>.png for a 1280x720 and a 640x480 camera frame
made from the picture (stretched, as a camera's would be framed).
"""
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'third_party/flutter_webrtc/linux')


def to_i420(rgb):
    r, g, b = [rgb[:, :, i].astype(np.float32) for i in range(3)]
    y = 16 + 0.257 * r + 0.504 * g + 0.098 * b
    u = 128 - 0.148 * r - 0.291 * g + 0.439 * b
    v = 128 + 0.439 * r - 0.368 * g - 0.071 * b
    h, w = y.shape
    pad = lambda p: np.pad(p, ((0, h % 2), (0, w % 2)), mode='edge')
    u = pad(u).reshape(h // 2 + h % 2, 2, w // 2 + w % 2, 2).mean((1, 3))
    v = pad(v).reshape(h // 2 + h % 2, 2, w // 2 + w % 2, 2).mean((1, 3))
    q = lambda p: np.clip(p + 0.5, 0, 255).astype(np.uint8)
    return b''.join(q(p).tobytes() for p in (y, u, v))


def from_i420(data, w, h):
    cw, ch = (w + 1) // 2, (h + 1) // 2
    a = np.frombuffer(data, np.uint8)
    y = a[:w * h].reshape(h, w).astype(np.float32)
    u = a[w * h:w * h + cw * ch].reshape(ch, cw).repeat(2, 0).repeat(2, 1)[:h, :w] - 128.0
    v = a[w * h + cw * ch:].reshape(ch, cw).repeat(2, 0).repeat(2, 1)[:h, :w] - 128.0
    l = 1.164 * (y - 16)
    rgb = np.stack([l + 1.596 * v, l - 0.392 * u - 0.813 * v, l + 2.017 * u], -1)
    return Image.fromarray(np.clip(rgb + 0.5, 0, 255).astype(np.uint8))


def main(picture, out_dir):
    tmp = tempfile.mkdtemp()
    exe = os.path.join(tmp, 'check')
    subprocess.run(['g++', '-std=c++14', '-O3', '-Wall', '-Werror', '-I', SRC,
                    os.path.join(SRC, 'selfie_segmenter.cc'),
                    os.path.join(SRC, 'background_blur.cc'),
                    os.path.join(ROOT, 'tool/blur/check_blur_main.cc'), '-o', exe],
                   check=True)
    src = Image.open(picture).convert('RGB')
    for w, h in ((1280, 720), (640, 480)):
        frame = np.asarray(src.resize((w, h), Image.BILINEAR))
        fin, fout = os.path.join(tmp, 'in'), os.path.join(tmp, 'out')
        open(fin, 'wb').write(to_i420(frame))
        r = subprocess.run([exe, str(w), str(h), fin, fout, '30'], check=True,
                           capture_output=True, text=True)
        print(r.stdout.strip())
        path = os.path.join(out_dir, f'blur-{w}x{h}.png')
        from_i420(open(fout, 'rb').read(), w, h).save(path)
        print('  ->', path)


if __name__ == '__main__':
    main(*sys.argv[1:])
