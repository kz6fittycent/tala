"""Checks Tala's selfie segmenter against Google's reference runtime.

Builds tool/blur/check_main.cc with the engine, runs both on the same inputs
and compares the masks. Needs a venv with ai-edge-litert and numpy, and the
model file (see export_selfie_model.py):

    /tmp/v/bin/pip install ai-edge-litert numpy
    /tmp/v/bin/python tool/blur/check_segmenter.py selfie_segmenter_landscape.tflite [picture.ppm]

A binary PPM (P6) picture is scaled to 256x144 and checked too; with a
person in it, the mask should cover them.
"""
import os
import subprocess
import sys
import tempfile

import numpy as np
from ai_edge_litert.interpreter import Interpreter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'third_party/flutter_webrtc/linux')
H, W = 144, 256


def read_ppm(path):
    data = open(path, 'rb').read()
    parts, pos = [], 0
    while len(parts) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b'#':
            pos = data.index(b'\n', pos)
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        parts.append(data[pos:end])
        pos = end
    assert parts[0] == b'P6' and parts[3] == b'255'
    w, h = int(parts[1]), int(parts[2])
    img = np.frombuffer(data[pos + 1:pos + 1 + w * h * 3], np.uint8).reshape(h, w, 3)
    ys = (np.arange(H) * h // H)
    xs = (np.arange(W) * w // W)
    return img[ys][:, xs].astype(np.float32) / 255


def main(model, picture=None):
    tmp = tempfile.mkdtemp()
    exe = os.path.join(tmp, 'check')
    subprocess.run(['g++', '-std=c++17', '-O3', '-march=x86-64-v2',
                    '-I', SRC, os.path.join(SRC, 'selfie_segmenter.cc'),
                    os.path.join(ROOT, 'tool/blur/check_main.cc'), '-o', exe],
                   check=True)
    it = Interpreter(model_path=model, num_threads=1)
    it.allocate_tensors()
    inp = it.get_input_details()[0]['index']
    outp = it.get_output_details()[0]['index']

    rng = np.random.default_rng(1)
    gy, gx = np.mgrid[0:H, 0:W]
    cases = {
        'random': rng.random((H, W, 3), dtype=np.float32),
        'gradient': np.stack([gx / W, gy / H, (gx + gy) / (W + H)], -1).astype(np.float32),
    }
    if picture:
        cases['picture'] = read_ppm(picture)
    worst = 0.0
    for name, x in cases.items():
        it.set_tensor(inp, x[None])
        it.invoke()
        want = it.get_tensor(outp)[0, :, :, 0]
        fin, fout = os.path.join(tmp, 'in'), os.path.join(tmp, 'out')
        x.astype('<f4').tofile(fin)
        runs = '200' if name == 'random' else '1'
        r = subprocess.run([exe, fin, fout, runs], check=True,
                           capture_output=True, text=True)
        got = np.fromfile(fout, '<f4').reshape(H, W)
        diff = float(np.abs(got - want).max())
        worst = max(worst, diff)
        print(f'{name}: max difference {diff:.2e}, person share '
              f'{(got > 0.5).mean():.0%} (reference {(want > 0.5).mean():.0%})'
              + (f', {r.stdout.strip()}' if runs != '1' else ''))
        if name == 'picture':
            mask = (got * 255).astype(np.uint8)
            with open(os.path.join(tmp, 'mask.pgm'), 'wb') as f:
                f.write(b'P5 %d %d 255\n' % (W, H) + mask.tobytes())
            print('mask written to', os.path.join(tmp, 'mask.pgm'))
    if worst > 1e-3:
        sys.exit(f'FAILED: differs from the reference by {worst:.2e}')
    print('OK')


if __name__ == '__main__':
    main(*sys.argv[1:])
