# Personas conocidas EN LA PLACA (plan)

Hoy el reconocimiento corre en el celular (SFace, 9,9 MB, `App_Flutter/assets/face_embedder.tflite`) con
la foto de la cámara de la placa. La meta es que la placa lo haga sola, sin celular, como el lector de
texto y la descripción de escenas.

## Por qué no se puede copiar SFace a la placa

- SFace pesa 9,9 MB con pesos int8: no cabe en la partición `modelos` (2 MB, compartida con el lector y
  las escenas).
- Su entrada es 112x112 a color alineada por los ojos: la placa necesita además encontrar la cara y los ojos.

## Plan: dos modelos chicos, entrenados por destilación (como las escenas)

1. **Detector de caras** (~60 KB, como el detector de texto de `ocr/detector.py`): frame 160x120 o
   320x240 en grises → mapa de celdas con "aquí hay una cara" y la posición de los ojos (regresión por
   celda). Datos: cajas "Human face" de Open Images (CC-BY). Hoy hay ~6.600 caras en las fotos ya
   bajadas (`data/vision_images`, grises 385x256). Para la posición de los ojos se usa un detector
   grande como profesor (YuNet de OpenCV, MIT) sobre las mismas fotos.
2. **Huella de la cara** (alumno, ~300-500 KB int8): MobileFaceNet reducida, 64x64 o 96x96 en grises,
   entrenada para imitar la huella de SFace (profesor) con pérdida coseno. Es la misma receta que el
   alumno de escenas: el profesor etiqueta, el alumno aprende. Necesita MUCHAS caras distintas: bajar
   las caras de Open Images train (cientos de miles, CC-BY) en Lambda.
3. **Comparación en la placa**: las huellas de las personas guardadas viven en la NVS (128 floats x 5
   fotos x 10 personas = 25 KB) y se comparan con coseno, igual que `known_faces_service.dart`.
   Guardar a alguien: "Oye Iris, recuerda a Raúl" → la placa saca 5 fotos y guarda sus huellas.

## Cómo medir si sirve

- Huella del alumno vs SFace: coseno medio entre ambas en caras de prueba (meta ≥ 0,9).
- Exactitud en pares de LFW con el mismo umbral calibrado (meta ≥ 90 %; SFace da 97 %).
- En la placa: tiempo por foto (meta < 1 s) y memoria (arena en PSRAM).

## Orden sugerido

1. Detector de caras (CPU del PC alcanza, datos ya bajados).
2. Bajar caras de Open Images y destilar la huella (Lambda).
3. Tarea `face_task.cpp` en la placa (modelos "caras_detector" y "caras_huella" en la partición) y
   `CMD_WHO` / `CMD_REMEMBER:<nombre>` en el protocolo.
