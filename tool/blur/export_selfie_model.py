"""Turns MediaPipe's landscape selfie segmenter into C++ data for Tala.

Tala runs the model with its own small engine
(third_party/flutter_webrtc/linux/selfie_segmenter.cc), so this writes the
model's layers and its float16 weights as a C++ include instead of shipping a
.tflite file and a runtime to read it.

The model is Google's, under the Apache License 2.0 (its model card:
https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Selfie%20Segmentation.pdf).
Its checksum is pinned below.

    python3 -m venv /tmp/v && /tmp/v/bin/pip install tflite numpy
    curl -LO https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_segmenter_landscape/float16/latest/selfie_segmenter_landscape.tflite
    /tmp/v/bin/python tool/blur/export_selfie_model.py selfie_segmenter_landscape.tflite \\
        third_party/flutter_webrtc/linux/selfie_model_data.inc
"""
import hashlib
import sys

import numpy as np
import tflite

SHA256 = '490e9ea734313e0de10fa0cd9e3c6133e36ea4db2b7a49bde9ef019f72796b8e'

# Kinds the engine knows; keep in step with selfie_segmenter.cc.
CONV, DWCONV, TCONV, RELU, HSWISH, LOGISTIC, MEAN, ADD, MUL, RESIZE = range(10)

B = tflite.BuiltinOperator


def main(src, dst):
    buf = open(src, 'rb').read()
    digest = hashlib.sha256(buf).hexdigest()
    if digest != SHA256:
        sys.exit(f'unexpected model: sha256 {digest}')
    m = tflite.Model.GetRootAsModel(buf, 0)
    g = m.Subgraphs(0)

    def shape(i):
        s = [int(v) for v in g.Tensors(i).ShapeAsNumpy()]
        assert len(s) in (1, 4), s
        assert i in weights or s[0] == 1, s
        return s

    def raw(i, dtype):
        b = m.Buffers(g.Tensors(i).Buffer())
        return np.frombuffer(bytes(b.DataAsNumpy()), dtype=dtype)

    # Float16 constants reach the graph through DEQUANTIZE ops: their outputs
    # become weights.
    weights = {}
    order = []
    for k in range(g.OperatorsLength()):
        op = g.Operators(k)
        oc = m.OperatorCodes(op.OpcodeIndex())
        code = max(oc.BuiltinCode(), oc.DeprecatedBuiltinCode())
        if code == B.DEQUANTIZE:
            (i,), (o,) = op.InputsAsNumpy(), op.OutputsAsNumpy()
            assert g.Tensors(i).Type() == tflite.TensorType.FLOAT16
            weights[o] = raw(i, np.float16)
        else:
            order.append((op, oc, code))

    tensors = {}  # tflite index -> engine index
    table = []    # (h, w, c, weight offset or -1, count)
    blob = []
    offset = 0

    def ref(i):
        nonlocal offset
        if i in tensors:
            return tensors[i]
        s = shape(i)
        if i in weights:
            # Kept in TFLite's layouts: conv and transposed conv kernels
            # [O][H][W][I] (O is in the count, H W I in the shape), depthwise
            # [1][H][W][C], biases [C].
            data = weights[i]
            blob.append(data)
            table.append((s[1], s[2], s[3], offset, data.size) if len(s) == 4
                         else (1, 1, s[0], offset, data.size))
            offset += data.size
        else:
            assert len(s) == 4
            table.append((s[1], s[2], s[3], -1, s[1] * s[2] * s[3]))
        tensors[i] = len(table) - 1
        return tensors[i]

    inp = g.InputsAsNumpy()[0]
    out = g.OutputsAsNumpy()[0]
    ref(inp)
    ops = []
    for op, oc, code in order:
        ins = [i for i in op.InputsAsNumpy() if i >= 0]
        (o,) = op.OutputsAsNumpy()
        stride, same, extra = 1, 0, 0
        if code in (B.CONV_2D, B.DEPTHWISE_CONV_2D):
            opts = (tflite.Conv2DOptions if code == B.CONV_2D
                    else tflite.DepthwiseConv2DOptions)()
            t = op.BuiltinOptions()
            opts.Init(t.Bytes, t.Pos)
            assert opts.FusedActivationFunction() == 0
            assert opts.DilationHFactor() == opts.DilationWFactor() == 1
            assert opts.StrideH() == opts.StrideW()
            if code == B.DEPTHWISE_CONV_2D:
                assert opts.DepthMultiplier() == 1
            stride = opts.StrideH()
            same = 1 if opts.Padding() == tflite.Padding.SAME else 0
            kind = CONV if code == B.CONV_2D else DWCONV
            args = ins
        elif code == B.CUSTOM:
            assert oc.CustomCode() == b'Convolution2DTransposeBias'
            # TfLiteTransposeConvParams: padding (1 = same), stride w, stride h.
            padding, sw, sh = np.frombuffer(
                bytes(op.CustomOptionsAsNumpy()), dtype='<i4')
            assert padding == 1 and sw == sh == 2
            kernel = shape(ins[1])
            assert kernel[1] == kernel[2] == 2, kernel
            kind, stride, same, args = TCONV, 2, 1, ins
        elif code == B.MEAN:
            assert list(raw(ins[1], '<i4')) == [1, 2]
            kind, args = MEAN, ins[:1]
        elif code == B.RESIZE_BILINEAR:
            opts = tflite.ResizeBilinearOptions()
            t = op.BuiltinOptions()
            opts.Init(t.Bytes, t.Pos)
            assert not opts.AlignCorners() and opts.HalfPixelCenters()
            kind, args = RESIZE, ins[:1]
        elif code in (B.ADD, B.MUL):
            opts = (tflite.AddOptions if code == B.ADD else tflite.MulOptions)()
            t = op.BuiltinOptions()
            opts.Init(t.Bytes, t.Pos)
            assert opts.FusedActivationFunction() == 0
            kind, args = (ADD if code == B.ADD else MUL), ins
        else:
            kind = {B.RELU: RELU, B.HARD_SWISH: HSWISH,
                    B.LOGISTIC: LOGISTIC}[code]
            args = ins
        a = [ref(i) for i in args] + [-1] * (3 - len(args))
        ops.append((kind, stride, same, *a, ref(o)))

    data = np.concatenate(blob).view(np.uint16)
    with open(dst, 'w') as f:
        f.write('// Generated by tool/blur/export_selfie_model.py from MediaPipe\'s\n'
                '// selfie_segmenter_landscape.tflite (Apache License 2.0, Google),\n'
                f'// sha256 {SHA256}. Don\'t edit.\n\n')
        f.write(f'constexpr int kInput = {tensors[inp]};\n')
        f.write(f'constexpr int kOutput = {tensors[out]};\n\n')
        f.write('// height, width, channels, weight offset (-1: computed), count\n')
        f.write('constexpr TensorInfo kTensors[] = {\n')
        for t in table:
            f.write('    {%d, %d, %d, %d, %d},\n' % t)
        f.write('};\n\n')
        f.write('// kind, stride, same padding, inputs, output\n')
        f.write('constexpr OpInfo kOps[] = {\n')
        for o in ops:
            f.write('    {%d, %d, %d, %d, %d, %d, %d},\n' % o)
        f.write('};\n\n')
        f.write(f'// {data.size} float16 values.\n')
        f.write('constexpr uint16_t kWeights[] = {\n')
        for i in range(0, data.size, 16):
            f.write('    ' + ', '.join(str(v) for v in data[i:i + 16]) + ',\n')
        f.write('};\n')
    print(f'{len(ops)} ops, {len(table)} tensors, {data.size} weights -> {dst}')


if __name__ == '__main__':
    main(*sys.argv[1:])
