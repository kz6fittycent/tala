"""Checks Tala's noise suppression on speech mixed with made-up noise.

    python3 tool/noise/check_noise.py [out-dir]

Needs g++, numpy and sox. The speech is ALSA's own test recordings
(/usr/share/sounds/alsa, from alsa-utils); the noise is a fan (low rumble)
and keyboard clicks, added at about 13 dB below the speech. For 48, 32 and
16 kHz it prints the delay, how much of the speech's strength comes through
while someone speaks (near 0 dB is good) and how much noise is left between
words (very negative is good); with an out-dir it writes noisy-*.wav and cleaned-*.wav to listen to.
"""
import os
import subprocess
import sys
import tempfile

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PLUGIN = os.path.join(ROOT, 'third_party/flutter_webrtc')
RNNOISE = os.path.join(PLUGIN, 'third_party/rnnoise')
RNNOISE_SOURCES = ['denoise.c', 'rnn.c', 'pitch.c', 'kiss_fft.c', 'celt_lpc.c', 'nnet.c',
                   'nnet_default.c', 'parse_lpcnet_weights.c', 'rnnoise_data.c',
                   'rnnoise_tables.c']
SPEECH = ['Front_Center', 'Front_Left', 'Rear_Right', 'Side_Left']


def build(tmp):
    objs = []
    for src in RNNOISE_SOURCES:
        obj = os.path.join(tmp, src + '.o')
        subprocess.run(['gcc', '-O2', '-Wno-cpp', '-c', '-I', os.path.join(RNNOISE, 'include'),
                        '-I', os.path.join(RNNOISE, 'src'), os.path.join(RNNOISE, 'src', src),
                        '-o', obj], check=True)
        objs.append(obj)
    exe = os.path.join(tmp, 'check')
    subprocess.run(['g++', '-std=c++17', '-O2', '-Wall', '-Werror',
                    '-I', os.path.join(PLUGIN, 'linux'), '-I', os.path.join(RNNOISE, 'include'),
                    os.path.join(PLUGIN, 'linux/noise_suppressor.cc'),
                    os.path.join(ROOT, 'tool/noise/check_noise_main.cc')] + objs + ['-lm', '-o', exe],
                   check=True)
    return exe


def speech(rate):
    raw = b''.join(subprocess.run(
        ['sox', f'/usr/share/sounds/alsa/{name}.wav', '-r', str(rate), '-c', '1', '-b', '16',
         '-e', 'signed', '-t', 'raw', '-'], check=True, capture_output=True).stdout
        for name in SPEECH)
    return np.frombuffer(raw, np.int16).astype(np.float32)


def noise(n, rate, level):
    rng = np.random.default_rng(1)
    fan = np.convolve(rng.standard_normal(n), np.ones(rate // 1200) / (rate // 1200), mode='same')
    fan *= 0.5 * level / fan.std()
    clicks = np.zeros(n)
    decay = rate // 1200
    for t in rng.integers(0, n - 6 * decay, size=n * 6 // rate):
        clicks[t:t + 6 * decay] += (rng.standard_normal(6 * decay)
                                    * np.exp(-np.arange(6 * decay) / decay) * 3 * level)
    return (fan + clicks).astype(np.float32)


def wav(path, audio, rate):
    subprocess.run(['sox', '-t', 'raw', '-r', str(rate), '-c', '1', '-b', '16', '-e', 'signed', '-',
                    path], input=np.clip(audio, -32768, 32767).astype(np.int16).tobytes(),
                   check=True)


def main(out_dir=None):
    tmp = tempfile.mkdtemp()
    exe = build(tmp)
    for rate in (48000, 32000, 16000):
        s = speech(rate)
        nz = noise(len(s), rate, 0.22 * s.std())
        fin, fout = os.path.join(tmp, 'in'), os.path.join(tmp, 'out')
        (s + nz).tofile(fin)
        r = subprocess.run([exe, str(rate), fin, fout], check=True, capture_output=True, text=True)
        out = np.fromfile(fout, np.float32)
        # The cleaned audio comes out a little late; line it up with the speech.
        k = len(out)
        lag = max(range(0, rate // 10), key=lambda d: float(np.dot(out[d:k], s[:k - d])))
        aligned = out[lag:k]
        clean = s[:k - lag]
        # In 10 ms pieces: while someone speaks, how much of the speech's
        # strength comes through; between words, how much noise is left.
        n = rate // 100
        pieces = len(clean) // n
        energy = lambda a: (a[:pieces * n].reshape(pieces, n) ** 2).mean(1)
        speech_e, noise_e, out_e = energy(clean), energy(nz[:len(clean)]), energy(aligned)
        talking = speech_e > 10 * noise_e.mean()
        quiet = speech_e < 0.01 * noise_e.mean()
        kept = 10 * np.log10(out_e[talking].sum() / speech_e[talking].sum())
        left = 10 * np.log10(out_e[quiet].sum() / noise_e[quiet].sum())
        print(f'{r.stdout.strip()}, {lag * 1000 / rate:.0f} ms late. Speaking: speech at '
              f'{kept:+.1f} dB. Between words: noise at {left:+.1f} dB.')
        if out_dir:
            wav(os.path.join(out_dir, f'noisy-{rate}.wav'), s + nz, rate)
            wav(os.path.join(out_dir, f'cleaned-{rate}.wav'), out, rate)


if __name__ == '__main__':
    main(*sys.argv[1:])
