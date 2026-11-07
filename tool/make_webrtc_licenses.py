#!/usr/bin/env python3
"""Writes assets/licenses/libwebrtc.txt, the licenses of what's in libwebrtc.so.

The prebuilt zip carries only the wrapper's MIT license, but the library also
compiles in WebRTC and the libraries below. The list comes from the source paths
and strings in libwebrtc.so (m150.7871.07), named as in WebRTC's own
tools_webrtc/libs/generate_licenses.py. An extra entry does no harm; a missing
one does, so recheck the list whenever binary_version changes.

Texts come from each project's current source, except WebRTC and the wrapper,
which use the release Tala ships. Any failed download stops the script, so the
file is never written with a gap.

Run it by hand and commit the result. The build doesn't use the network for it.
"""

import base64
import pathlib
import urllib.request

WEBRTC = 'https://raw.githubusercontent.com/webrtc-sdk/webrtc/m150_release/'
WRAPPER = ('https://raw.githubusercontent.com/webrtc-sdk/libwebrtc/'
           'libwebrtc.m150.7871.07/')
CHROMIUM = ('https://chromium.googlesource.com/chromium/src/third_party/+/'
            'refs/heads/main/')
GITHUB = 'https://raw.githubusercontent.com/'

COMPONENTS = [
    ('libwebrtc', [WRAPPER + 'LICENSE', WRAPPER + 'NOTICE']),
    ('WebRTC', [WEBRTC + 'LICENSE', WEBRTC + 'PATENTS']),
    ('Abseil', [GITHUB + 'abseil/abseil-cpp/master/LICENSE']),
    ('BoringSSL', [GITHUB + 'google/boringssl/main/LICENSE']),
    ('CRC32C', [GITHUB + 'google/crc32c/main/LICENSE']),
    ('dav1d', [GITHUB + 'videolan/dav1d/master/COPYING']),
    ('FFmpeg', [
        'https://chromium.googlesource.com/chromium/third_party/ffmpeg/+/'
        'refs/heads/master/LICENSE.md',
        GITHUB + 'FFmpeg/FFmpeg/master/COPYING.LGPLv2.1',
    ]),
    ('libaom', [
        'https://aomedia.googlesource.com/aom/+/refs/heads/main/LICENSE',
        'https://aomedia.googlesource.com/aom/+/refs/heads/main/PATENTS',
    ]),
    ('libc++ and libc++abi', [GITHUB + 'llvm/llvm-project/main/libcxx/LICENSE.TXT']),
    ('libjpeg-turbo', [GITHUB + 'libjpeg-turbo/libjpeg-turbo/main/LICENSE.md']),
    ('libsrtp', [GITHUB + 'cisco/libsrtp/main/LICENSE']),
    ('libvpx', [
        GITHUB + 'webmproject/libvpx/main/LICENSE',
        GITHUB + 'webmproject/libvpx/main/PATENTS',
    ]),
    ('libyuv', [
        'https://chromium.googlesource.com/libyuv/libyuv/+/refs/heads/main/LICENSE',
    ]),
    ('OpenH264', [GITHUB + 'cisco/openh264/master/LICENSE']),
    ('Opus', [GITHUB + 'xiph/opus/main/COPYING']),
    ('PFFFT', [CHROMIUM + 'pffft/LICENSE']),
    ('RNNoise', [CHROMIUM + 'rnnoise/COPYING']),
    ('zlib', [CHROMIUM + 'zlib/LICENSE']),
    ('fft (WebRTC)', [WEBRTC + 'modules/third_party/fft/LICENSE']),
    ('g711 (WebRTC)', [WEBRTC + 'modules/third_party/g711/LICENSE']),
    ('g722 (WebRTC)', [WEBRTC + 'modules/third_party/g722/LICENSE']),
    ('ooura (WebRTC)', [WEBRTC + 'common_audio/third_party/ooura/LICENSE']),
    ('spl_sqrt_floor (WebRTC)',
     [WEBRTC + 'common_audio/third_party/spl_sqrt_floor/LICENSE']),
]

# Matches parseBundledLicenses in lib/src/licenses.dart.
MARKER = '@@@ '


def fetch(url):
    googlesource = 'googlesource.com' in url
    request = urllib.request.Request(
        url + ('?format=TEXT' if googlesource else ''),
        headers={'User-Agent': 'tala-make-webrtc-licenses'},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read()
    if googlesource:
        body = base64.b64decode(body)
    text = body.decode('utf-8').replace('\r\n', '\n').strip()
    if not text:
        raise ValueError(f'empty license: {url}')
    if any(line.startswith(MARKER) for line in text.split('\n')):
        raise ValueError(f'license text contains the marker: {url}')
    return text


def main():
    sections = []
    for name, urls in COMPONENTS:
        print(name)
        texts = '\n\n'.join(fetch(url) for url in urls)
        sections.append(f'{MARKER}{name}\n{texts}\n')
    out = pathlib.Path(__file__).parent.parent / 'assets/licenses/libwebrtc.txt'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text('\n'.join(sections), encoding='utf-8')
    print(f'{out}: {out.stat().st_size} bytes')


if __name__ == '__main__':
    main()
