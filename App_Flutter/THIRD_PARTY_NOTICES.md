# Avisos de terceros

## SFace (reconocimiento de caras) — `assets/face_embedder.tflite`

Modelo SFace de OpenCV Zoo (https://github.com/opencv/opencv_zoo, `models/face_recognition_sface`),
convertido a TFLite por `ML_Training/faces/convert_face_model.py`.
Licencia: Apache License 2.0 — https://www.apache.org/licenses/LICENSE-2.0
Cambios: conversion de ONNX a TFLite con pesos int8; sin reentrenar.

## Google ML Kit (texto y caras en el telefono)

Se usa a traves de `google_mlkit_text_recognition` y `google_mlkit_face_detection`, bajo los
terminos de ML Kit de Google: https://developers.google.com/ml-kit/terms
