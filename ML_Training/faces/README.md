# Reconocimiento de caras en el teléfono (SFace → TFLite)

Modelo: `App_Flutter/assets/face_embedder.tflite` (9,9 MB, int8 dinámico, solo ops builtin de TFLite, sin Flex).

## Origen y licencia

- Modelo: **SFace** (MobileFaceNet entrenada con la pérdida SFace), de OpenCV Zoo.
- URL: https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
- Licencia: **Apache-2.0** (archivo `LICENSE` de `models/face_recognition_sface/` en opencv_zoo). Uso en la app permitido; incluir el aviso de licencia Apache-2.0 en los créditos de la app.
- SHA256 del ONNX: `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79` (38,7 MB)

## Conversión

`convert_face_model.py` reconstruye la red en Keras nodo por nodo desde el ONNX (Conv/BN/PReLU/Gemm, NCHW→NHWC, sin onnx2tf), copia los pesos y exporta a TFLite con cuantización dinámica int8 (pesos int8, activaciones float):

```
ML_Training/.venv/Scripts/python.exe ML_Training/faces/convert_face_model.py \
    --onnx RUTA/face_recognition_sface_2021dec.onnx \
    --out App_Flutter/assets/face_embedder.tflite --quant dynamic
```

Ops resultantes: CONV_2D, DEPTHWISE_CONV_2D, PRELU, PAD, SUB, MUL, ADD, TRANSPOSE, RESHAPE, FULLY_CONNECTED.

Paridad con el ONNX original (onnxruntime): Keras = 1,0000; TFLite int8 en 1434 caras reales alineadas: coseno medio **0,9990** (mínimo 0,9974). La exactitud en LFW es la misma que la del ONNX (ver tabla).

## Contrato de entrada / salida

| | |
|---|---|
| Entrada | `float32` `[1, 112, 112, 3]`, NHWC |
| Canales | **RGB** (no BGR) |
| Valores | píxeles **0..255 tal cual** (la normalización `(x − 127.5) × 0.0078125` ya está dentro del modelo) |
| Salida | `float32` `[1, 128]`, **sin normalizar**: hacer L2-normalize y comparar con producto punto (= coseno) |

## Recorte recomendado (con ML Kit)

La red espera caras **alineadas** como en ArcFace/SFace (112×112, ojos en posición fija). Activar landmarks en ML Kit (`FaceDetectorOptions(enableLandmarks: true)`).

**Recomendado — alineación por los dos ojos** (similitud exacta de 2 puntos):

1. Tomar los dos ojos de ML Kit y ordenarlos por x **en la imagen**: el de menor x es `L`, el otro `R` (ojo: `FaceLandmarkType.leftEye` de ML Kit es el ojo izquierdo *de la persona*, que en la foto suele quedar a la derecha).
2. Destinos en la imagen 112×112: `L → (38.2946, 51.6963)`, `R → (73.5318, 51.5014)`.
3. Escala `s = |dst_R − dst_L| / |R − L|`, ángulo `a = atan2(dst) − atan2(R − L)`; matriz `M = [[s·cos a, −s·sin a, tx], [s·sin a, s·cos a, ty]]` con `t = dst_L − rot·L`.
4. Remuestrear (warpAffine, bilineal) a 112×112, bordes en negro. Rotar la foto según la orientación EXIF/cámara **antes**.

Con 5 puntos (ojos, nariz, comisuras de la boca) y la plantilla completa de ArcFace (`nariz (56.0252, 71.7366)`, `boca (41.5493, 92.3655)`, `(70.7299, 92.2041)`) se gana un poco (tabla), pero la base de la nariz de ML Kit no es exactamente la punta de la nariz de la plantilla; no lo probé con ML Kit.

**No usar** solo el bounding box: cae a ~92 % aunque se rote por los ojos (ver tabla).

## Umbral (coseno entre embeddings L2-normalizados)

Evaluación en LFW (funneled), detector YuNet (Apache/MIT, OpenCV Zoo) para simular los landmarks de ML Kit. Umbral elegido en 400 pares de `pairsDevTrain` (200 mismo / 200 distinto), medido en 500 pares de `pairsDevTest` (250 / 250). Muestra pequeña a propósito (PC compartido).

| Recorte | Mejor umbral (train) | Exactitud test | Exactitud a 0,363 | Mismo: media / p5 | Distinto: media / p99 / máx |
|---|---|---|---|---|---|
| 5 puntos, ONNX original | 0,368 | 98,4 % | 98,4 % | 0,656 / 0,462 | 0,082 / 0,319 / 0,372 |
| 5 puntos, TFLite | 0,364 | 98,4 % | 98,4 % | 0,656 / 0,466 | 0,083 / 0,322 / 0,375 |
| **2 ojos, TFLite** | 0,363 | **97,0 %** | 97,0 % | 0,634 / 0,363 | 0,096 / 0,317 / 0,404 |
| Caja +20 % margen | 0,397 | 92,4 % | 90,8 % | 0,563 / 0,306 | 0,218 / 0,453 / 0,473 |
| Caja +20 % rotada por ojos | 0,414 | 92,8 % | 91,0 % | 0,565 / 0,308 | 0,217 / 0,454 / 0,487 |

Con alineación por ojos, umbral 0,40 (sin falsos positivos en train): test 96,8 %, falsos aceptados 0,4 %, rechazos 6,0 %.

**Recomendación para la app** (decir un nombre equivocado a una persona ciega es peor que no decir nada):

- `coseno ≥ 0,40` → "es Raúl".
- `0,30 ≤ coseno < 0,40` → "puede ser Raúl" (o no decir nombre).
- `< 0,30` → persona desconocida.
- Guardar 3–5 fotos por persona (frente, leve giro, distinta luz) y usar el **máximo** coseno contra sus embeddings; exigir además que el mejor supere al segundo candidato por ≥ 0,05.
- Ignorar caras pequeñas (distancia entre ojos < ~30 px en la foto original) o muy giradas (|headEulerAngleY| > ~30°): ahí el modelo pierde exactitud.

Limitaciones: LFW son fotos de famosos (no cámara del teléfono); los landmarks fueron de YuNet, no de ML Kit. Validar el umbral con fotos reales de la app.
