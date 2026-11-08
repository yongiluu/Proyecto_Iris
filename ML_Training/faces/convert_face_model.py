"""Convierte SFace (OpenCV Zoo, Apache-2.0) de ONNX a TFLite para la app.

Fuente: https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
SHA256: 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79

No usa onnx2tf: el grafo es una MobileFaceNet secuencial (Conv/BN/PRelu + Gemm),
asi que se reconstruye en Keras nodo por nodo (NCHW -> NHWC) y se copian los pesos.
La normalizacion (x - 127.5) * 0.0078125 queda DENTRO del modelo: la app entrega
pixeles RGB 0..255 en float32, NHWC [1,112,112,3]. Salida: [1,128] (sin normalizar L2).

Uso (desde la raiz del repo):
  ML_Training/.venv/Scripts/python.exe ML_Training/faces/convert_face_model.py \
      --onnx RUTA/face_recognition_sface_2021dec.onnx \
      --out App_Flutter/assets/face_embedder.tflite --quant dynamic

Requiere: tensorflow, onnx, onnxruntime, numpy.
"""
import argparse
import hashlib
import os

import numpy as np

EXPECTED_SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_keras(onnx_path):
    import onnx
    from onnx import numpy_helper
    import tensorflow as tf

    m = onnx.load(onnx_path)
    g = m.graph
    W = {t.name: numpy_helper.to_array(t) for t in g.initializer}
    attrs = lambda n: {a.name: onnx.helper.get_attribute_value(a) for a in n.attribute}

    inp = tf.keras.Input(shape=(112, 112, 3), batch_size=1, name="input_rgb_0_255")
    T = {"data": inp}
    pending = []  # (layer, weights)
    spatial = True  # si el tensor actual es NHWC (antes del Flatten)

    for n in g.node:
        op = n.op_type
        a = attrs(n)
        x = T[n.input[0]]
        name = n.output[0]
        if op in ("Sub", "Mul"):
            c = float(np.asarray(W[n.input[1]]).reshape(-1)[0])
            y = (x - c) if op == "Sub" else (x * c)
            print(f"  {op} escalar = {c}")
        elif op == "Conv":
            w = W[n.input[1]]  # (out, in/group, kh, kw)
            group = a.get("group", 1)
            kh, kw = a["kernel_shape"]
            sh, sw = a["strides"]
            pt, pl, pb, pr = a["pads"]
            assert a.get("dilations", [1, 1]) == [1, 1]
            bias = W[n.input[2]] if len(n.input) > 2 else None
            if pt or pl or pb or pr:
                x = tf.keras.layers.ZeroPadding2D(((pt, pb), (pl, pr)))(x)
            cin = x.shape[-1]
            if group == 1:
                layer = tf.keras.layers.Conv2D(w.shape[0], (kh, kw), (sh, sw), "valid",
                                               use_bias=bias is not None, name=name)
                kw_ = [w.transpose(2, 3, 1, 0)]
            else:
                assert group == cin == w.shape[0] and w.shape[1] == 1, "solo depthwise"
                layer = tf.keras.layers.DepthwiseConv2D((kh, kw), (sh, sw), "valid",
                                                        use_bias=bias is not None, name=name)
                kw_ = [w.transpose(2, 3, 0, 1)]  # (kh,kw,C,1)
            if bias is not None:
                kw_.append(bias)
            y = layer(x)
            pending.append((layer, kw_))
        elif op == "BatchNormalization":
            gamma, beta, mean, var = (W[i] for i in n.input[1:5])
            layer = tf.keras.layers.BatchNormalization(axis=-1, epsilon=a["epsilon"], name=name)
            y = layer(x)
            pending.append((layer, [gamma, beta, mean, var]))
        elif op == "PRelu":
            slope = W[n.input[1]].reshape(-1)
            layer = tf.keras.layers.PReLU(shared_axes=[1, 2], name=name)
            y = layer(x)
            pending.append((layer, [slope.reshape(1, 1, -1)]))
        elif op == "Dropout":
            y = x  # inferencia: identidad
        elif op == "Flatten":
            # ONNX aplana en orden NCHW: transponer antes de aplanar para mantener el orden.
            y = tf.keras.layers.Permute((3, 1, 2))(x)
            y = tf.keras.layers.Flatten()(y)
            spatial = False
        elif op == "Gemm":
            assert a.get("transA", 0) == 0 and a.get("transB", 0) == 1
            assert a.get("alpha", 1.0) == 1.0 and a.get("beta", 1.0) == 1.0
            w, b = W[n.input[1]], W[n.input[2]]
            layer = tf.keras.layers.Dense(w.shape[0], name=name)
            y = layer(x)
            pending.append((layer, [w.T, b]))
        else:
            raise NotImplementedError(op)
        T[name] = y

    out = T[g.output[0].name]
    model = tf.keras.Model(inp, out, name="sface_embedder")
    for layer, ws in pending:
        layer.set_weights([np.asarray(v, dtype=np.float32) for v in ws])
    return model


def to_tflite(model, quant):
    import tensorflow as tf

    conv = tf.lite.TFLiteConverter.from_keras_model(model)
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]  # sin Flex
    if quant == "dynamic":
        conv.optimizations = [tf.lite.Optimize.DEFAULT]
    elif quant == "fp16":
        conv.optimizations = [tf.lite.Optimize.DEFAULT]
        conv.target_spec.supported_types = [tf.float16]
    return conv.convert()


def run_tflite(blob, x):
    import tensorflow as tf

    it = tf.lite.Interpreter(model_content=blob)
    it.allocate_tensors()
    i, o = it.get_input_details()[0], it.get_output_details()[0]
    outs = []
    for xi in x:
        it.set_tensor(i["index"], xi[None].astype(np.float32))
        it.invoke()
        outs.append(it.get_tensor(o["index"])[0].copy())
    return np.stack(outs)


def run_onnx(onnx_path, x_nhwc):
    import onnxruntime as ort

    s = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    return np.concatenate([s.run(None, {"data": xi[None].transpose(0, 3, 1, 2).astype(np.float32)})[0]
                           for xi in x_nhwc])


def cos_rows(a, b):
    a = a / np.linalg.norm(a, axis=1, keepdims=True)
    b = b / np.linalg.norm(b, axis=1, keepdims=True)
    return (a * b).sum(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", required=True)
    ap.add_argument("--out", default="App_Flutter/assets/face_embedder.tflite")
    ap.add_argument("--quant", choices=["dynamic", "fp16", "none"], default="dynamic")
    ap.add_argument("--check-images", nargs="*", default=[],
                    help="imagenes 112x112 alineadas (opcional) para la comparacion ONNX vs TFLite")
    args = ap.parse_args()

    digest = sha256(args.onnx)
    print("SHA256 ONNX:", digest, "(OK)" if digest == EXPECTED_SHA256 else "(DISTINTO al esperado!)")

    model = build_keras(args.onnx)
    blob = to_tflite(model, args.quant)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(blob)
    print(f"TFLite escrito: {args.out} ({len(blob) / 1e6:.2f} MB, quant={args.quant})")

    # Paridad con ONNX (onnxruntime): ruido + imagenes opcionales.
    rng = np.random.default_rng(0)
    xs = [rng.uniform(0, 255, (112, 112, 3)).astype(np.float32) for _ in range(4)]
    if args.check_images:
        import cv2
        for p in args.check_images:
            im = cv2.imread(p)[:, :, ::-1]  # BGR -> RGB
            xs.append(cv2.resize(im, (112, 112)).astype(np.float32))
    x = np.stack(xs)
    ref = run_onnx(args.onnx, x)
    keras_out = model.predict(x, batch_size=1, verbose=0)
    tfl = run_tflite(blob, x)
    print("coseno Keras  vs ONNX:", np.round(cos_rows(keras_out, ref), 5))
    print("coseno TFLite vs ONNX:", np.round(cos_rows(tfl, ref), 5))


if __name__ == "__main__":
    main()
