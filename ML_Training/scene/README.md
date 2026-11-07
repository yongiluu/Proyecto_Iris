# Descripción de escenas en la placa (Iris)

> **Objetivo:** que la ESP32-S3, sin internet, mire con su cámara y diga algo como
> *"Parece que estás en un pasillo. Adelante hay una puerta café y un cuadro. Al fondo hay una persona. No detecto peligros."*

Hasta donde sabemos, una descripción de escenas **en español, orientada a seguridad, en tiempo real y dentro de un microcontrolador de ~8 MB** para personas ciegas sería algo nuevo. Este README es también el borrador del método para un paper o un concurso.

## La idea en una frase

Un modelo de visión y lenguaje grande (el **profesor**, ej. Qwen2.5-VL en una GPU de Lambda) llena un **formulario fijo** sobre miles de fotos. Un modelo chico (el **alumno**, ~0,9 M de parámetros, int8) aprende a llenar ese mismo formulario mirando solo lo que ve la placa (160x120 a color). Después, una gramática en español convierte el formulario en una frase. Esa técnica se llama **destilación de conocimiento**.

```text
              Lambda (GPU)                                      Placa (ESP32-S3)
 foto grande ──► profesor (Qwen2.5-VL) ──► formulario JSON        cámara 160x120 RGB565
                                              │                        │
                                              ▼                        ▼
                        alumno aprende a imitarlo ───────────► alumno int8 (MobileNetV2 0,35)
                                                                        │ formulario
                                                                        ▼
                                                     describe: "Adelante hay una puerta café…"
```

¿Por qué un formulario y no texto libre? Un modelo que *genera* texto necesita cientos de millones de parámetros; la placa tiene 8 MB. Con el formulario el alumno solo clasifica, que es lo que una red chica hace bien, y la frase sale de reglas auditables: **no puede inventar palabras ni peligros que no están en el formulario**. El texto libre generado en la placa (un decodificador diminuto, ~1–2 M de parámetros) es la **versión 2** del proyecto. Para eso el profesor ya guarda el campo `detalle`.

## El formulario (`vocab.py`, `schema.py`)

| Campo | Valores |
|---|---|
| `objetos` | 43 tipos (persona, auto, puerta, escalera, silla, semáforo, cuadro…), cada uno con `posicion` (izquierda/centro/derecha), `distancia` (cerca < 1,5 m / medio / lejos > 4 m) y `color` (11 colores; solo los objetos donde el color sirve) |
| `peligros` | escalera hacia abajo/arriba, escalón, obstáculo en el suelo, obstáculo a la altura de la cabeza, vehículo cerca, borde de la vereda, puerta de vidrio, hoyo |
| `personas` | 0, 1, 2, 3+ |
| `lugar` / `interior` | pasillo, cocina, calle, vereda, cruce, parque… / sí-no |
| `calidad` | buena, oscura, borrosa, tapada |
| `detalle` | frase libre (para la v2) |

Lo desconocido (`null`) no se entrena: así se mezclan etiquetas parciales (automáticas) con completas (profesor).

## Reglas de seguridad de la frase (`describe.py`)

- Primero los peligros. Si el modelo duda (puntaje entre 0,3 y 0,6), dice *"Atención: podría haber un escalón"* en vez de callarse.
- **Nunca dice "no hay peligros".** Como mucho dice *"No detecto peligros"*, y solo si la imagen es buena y **todos** los peligros puntúan bajo 0,15.
- Si la imagen está oscura, borrosa o tapada, lo dice (*"La imagen está muy oscura; no puedo describir bien"*). Para eso se entrena con ejemplos arruinados a propósito.
- Un modelo que nunca vio etiquetas de peligros (solo etiquetas automáticas) **no dice nada de peligros**. Esa información queda en `models/scene_student.json`.

## Qué ve la placa

La cámara ahora vive a **color, 160x120 (RGB565)**, con el campo de visión completo. Antes vivía en grises 96x96.

- **Descripción de escenas:** usa el frame completo a color.
- **Modelos de clases y de cercanía (grises 96x96):** usan el cuadrado central convertido a grises en la placa (`image_convert.cpp`). La versión en Python es `vision/board_image.py`, y `tests/test_image_convert.py` comprueba que den **exactamente** lo mismo.
- **Fotos para la nube:** siguen siendo JPEG a color de 640x480.

El entrenamiento simula la cámara: pérdida de color RGB565 (idéntica a la placa), balance de blancos, poca luz, ruido, viñeteado y desenfoque (`dataset.py`).

## Cómo correrlo

### En el PC (prueba del pipeline, sin profesor)

```bash
cd ML_Training
python scene/download_images.py            # 12 mil fotos a color + etiquetas automáticas (~0,5 GB)
python scene/train.py --labels auto        # alumno con etiquetas automáticas (CPU, ~1 h)
python scene/export_model.py               # int8 + métricas
python scene/demo.py                       # galería: data/scene/demo_alumno.html
```

Las **etiquetas automáticas** salen de las cajas de Open Images y de los colores de los píxeles. Sirven para probar todo y como respaldo, pero no tienen peligros y son ruidosas.

### En Lambda (el profesor de verdad)

1. Crea una instancia con GPU en el panel de Lambda. Para Qwen2.5-VL-7B basta una **A10 (24 GB)**; una A100 o H100 va más rápido. Para el 32B se necesita A100 80 GB o H100.
2. Entra por SSH y corre:
   ```bash
   git clone https://github.com/yongiluu/Proyecto_Iris.git && cd Proyecto_Iris/ML_Training
   bash scene/lambda/run_all.sh
   ```
   El script baja 60 mil fotos, levanta vLLM con el profesor y etiqueta. **Primero prueba con 10 fotos e imprime las frases**: revísalas. Después entrena el alumno en la GPU, lo exporta a int8 y arma la demo.
3. Trae las etiquetas y el modelo con los `scp` que imprime al final, y **apaga la instancia**.

Las etiquetas del profesor (`data/scene/labels_teacher_*.jsonl`) son lo más valioso: con ellas se puede reentrenar cuantas veces se quiera en el PC sin volver a pagar GPU.

### Fotos reales de la placa (lo que más mejora el modelo)

```bash
cd Hardware_ESP32 && pio run -e seeed_xiao_esp32s3_photo_capture -t upload
cd ../ML_Training
python vision/capture_photos.py --note pasillo --count 300   # sin clase: solo color para escenas
python vision/capture_photos.py --label puerta --note casa   # con clase: además, gris 96x96 para el modelo de clases
```

Las fotos a color quedan en `data/scene_board/`, y `label_teacher.py` las etiqueta junto con las de Open Images (fuente `board`). Prioriza **lugares reales de uso**: pasillos, escaleras, veredas, cruces, micro, la universidad.

## Resultados

### v0 (2026-11-07): solo etiquetas automáticas, entrenado en CPU

12 mil fotos de Open Images (10 mil para entrenar), 14 épocas (~1 h). Medido sobre 940 fotos de test con el **modelo int8**, que es lo que correría en la placa:

| | |
|---|---|
| Tamaño | 1,13 MB de flash (reemplazando al modelo de clases, el programa crece solo ~0,14 MB). Arena ~380 KB en PSRAM |
| Ops | ADD, CONV_2D, DEPTHWISE_CONV_2D, FULLY_CONNECTED, LOGISTIC, MUL, RESHAPE, SOFTMAX: todas existen en el TFLM de la placa |
| Objetos | precisión 58 %, recall 53 %, F1 55,5 %. Lo mejor: persona 73 %, auto 69 %, bus 75 %. Lo peor: espejo, paraguas, cortina y poste (cosas chicas o con pocos ejemplos) |
| Posición / distancia / color | 68 % / 74 % / 44 % de acierto |
| Personas / lugar / calidad | 80 % / 81 % / 99,7 % |
| Peligros | sin entrenar: las etiquetas automáticas no los tienen, así que el modelo **no dice nada de peligros** |
| int8 frente a float32 | F1 55,5 % frente a 56 %: la cuantización casi no pierde |

Frases reales del test:

- *"Parece que estás en la calle. Adelante, muy cerca, hay un árbol. A tu derecha hay un edificio gris."* Es correcta, pero se le escapan los semáforos, autos y personas de una esquina.
- *"Parece que estás en la calle. Adelante hay una persona, una moto negra y una bicicleta gris."* Viene de una foto de motos en una pista: **la bicicleta es inventada**.

**Lectura:** la cadena completa funciona, de la foto 160x120 a la frase en español. Los techos son conocidos:

- las etiquetas automáticas son ruidosas y no tienen peligros,
- los colores de las etiquetas automáticas son heurísticos (de ahí el 44 %),
- los objetos chicos casi no se ven en 160x120.

El siguiente salto viene del profesor en Lambda y de las fotos reales de la placa.

## Métricas (para el paper)

`train.py` y `export_model.py` reportan sobre el test (fotos que el modelo no vio):

- **Objetos:** precisión, recall y F1 (multi-etiqueta), con los peores y mejores por clase.
- **Posición, distancia y color:** acierto sobre objetos presentes con etiqueta.
- **Personas, lugar y calidad:** acierto.
- **Peligros:** cuántas veces avisa y cuántas falsas alarmas da. **Esta es la métrica crítica**: preferimos avisar de más.
- **Frases de ejemplo:** alumno frente a profesor.

Pendiente para el paper: evaluación con personas sobre fotos reales de la placa (¿la frase es correcta y útil?), latencia y consumo medidos en la placa, y comparación contra describir en la nube.

## Próximos pasos

1. **Profesor en Lambda** con 60 mil fotos y la primera versión real del alumno.
2. **Integración en el firmware:**
   - Pasar `describe.py` a C++ y correr el alumno int8 en la placa, que mandaría `CMD_SCENE:<frase>` a la app.
   - **Memoria:** el alumno pesa ~0,9 MB (894 mil parámetros). El programa ya usa el 83,5 % de su partición de 3,3 MB, pero el alumno **reemplaza** al modelo de clases actual (`vision_scenes`, ~1 MB): sabe todo lo que ese sabe (personas, vehículos, escaleras, puertas, cruces por el lugar) y más. Así cabe sin cambiar particiones.
   - Si algún día no cabe, la XIAO tiene 8 MB, pero cambiar particiones requiere grabar **una vez por USB**: no se puede por WiFi.
3. **Fotos reales** de la placa etiquetadas por el profesor, y fine-tuning.
4. **v2 generativa:** un decodificador diminuto que genere texto libre en la placa (vocabulario de ~1.500 palabras), entrenado con las frases y el campo `detalle` del profesor.
5. Reentrenar los modelos de clases y cercanía directo a color: hoy siguen en grises.

## Licencias

- **Open Images:** las anotaciones son CC BY 4.0 y las fotos son de Flickr, con licencia CC BY 2.0 (hay que dar atribución si se publican fotos).
- **Qwen2.5-VL:** licencia Apache 2.0 en 7B y 32B. El modelo de 72B tiene licencia propia; revisarla antes de usarlo.
