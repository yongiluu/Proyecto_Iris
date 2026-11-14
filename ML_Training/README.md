# ML_Training — Modelos Edge AI de Iris

Entrenamiento de los modelos TensorFlow Lite Micro que corren **dentro de la placa** (sin internet).

| Modelo | Estado | Qué detecta |
|---|---|---|
| Audio (`audio/`) | ✅ pipeline completo, modelo v3 (ESC-50 + UrbanSound8K + voz chilena) reforzado con audios de la app | `fondo`, `voz`, `bocina`, `sirena`, `perro` |
| Wake word (`wakeword/`) | ✅ v1 con las tomas de la app (una voz) | "Oye Iris" |
| **Lector de texto (`ocr/`)** | 🧪 en desarrollo: lector de líneas entrenado con texto sintético; falta el detector de dónde hay texto | letreros, etiquetas, precios, horarios, direcciones (texto impreso grande) |
| **Retina: descripción de escenas a color (`scene/`)** | 🧪 en desarrollo: pipeline completo, profesor en Lambda pendiente | frase en español: lugar, objetos con color y posición, personas, peligros. Ver [`scene/README.md`](scene/README.md) |

La cámara de la placa entrega **color 160x120**, y Retina recibe ese frame completo. La conversión de la cámara está en `Hardware_ESP32/src/image_convert.cpp` y su referencia en Python en `camara/board_image.py` (verificado por `tests/test_image_convert.py`); el cuadrado central 96x96 en grises solo lo usa ya el medidor de luz de la placa. Los registros de entrenamiento van a `logs/`.

**Modelos retirados (2026-11):** los antiguos modelos de visión en grises 96x96, `vision_scenes` (clases `persona`, `vehiculo`, `escalera`, `puerta`, `cruce`) y `proximity` (cercanía), ya no corren en la placa ni en la app y se borraron del repositorio junto con su código (`vision/`). Los reemplaza **Retina**. Ver [Modelos en grises retirados](#modelos-en-grises-retirados-visión-y-cercanía).

## Recolectar datos reales con la app (con o sin prototipo)

La app tiene una pantalla **Misiones de datos** (ícono 📋 arriba a la derecha en la pantalla principal). Te guía misión por misión ("Audio de calle 3/8", "Puertas 50/100") y guarda los audios y fotos en el celular, así que puedes grabar en la calle sin PC. En cada misión eliges la fuente:

- **Placa** (cuando llegue el prototipo): el micrófono y la cámara reales por Bluetooth. Es lo mejor.
- **Celular** (ya, sin prototipo): la cámara del celular convertida a color 160×120, como la de la placa, y el micrófono a 16 kHz sin filtros. No es el mismo sensor, pero sí tus calles, puertas, escaleras y micros. Después basta poco fine-tuning con la placa. Lleva el celular a la altura del pecho.

El origen queda en el nombre de cada archivo (`...__placa-<fecha>` o `...__cel-<fecha>`).

1. Sube una vez el firmware normal a la XIAO: `cd Hardware_ESP32 && pio run -e seeed_xiao_esp32s3 -t upload`.
2. En la app, elige el modo **Placa ESP32**, abre **Misiones de datos** y completa las misiones (~15 min de audio y ~750 fotos). Lleva la placa donde la usaría la persona. Cada grabación avisa si se perdió audio por Bluetooth, y puedes borrar la última toma si salió mal.
3. Pasa los datos al PC: botón **Exportar** (zip por Drive, correo, etc.) o, por USB, copia la carpeta `Android/data/<app>/files/iris_dataset`.
4. Impórtalos y reentrena, desde `ML_Training/`:
   ```bash
   python import_phone_data.py iris_dataset_XXXX.zip
   python audio/prepare_dataset.py && python audio/train.py --finetune && python audio/export_model.py
   cd ../Hardware_ESP32 && pio run -e seeed_xiao_esp32s3 -t upload
   ```
   Las fotos quedan a color en `data/scene_board/` (las que no son color 160x120 se saltan con un aviso). Las etiqueta el profesor de Retina (`scene/label_teacher.py`, fuente `board`; ver [`scene/README.md`](scene/README.md)).

Las misiones se editan en `App_Flutter/lib/features/data_collection/missions.dart`. El ambiente de cada grabación (casa, calle, transporte) queda en el nombre del archivo, para entrenar más adelante un modelo de ambiente. Los firmwares `*_audio_capture` y `*_photo_capture` con cable USB siguen sirviendo para pruebas en el escritorio.

### Reentrenar todo con tus datos: un solo comando

Después de exportar el zip desde la app (o con la carpeta copiada por USB):

```bash
python ciclo_datos_reales.py iris_dataset_XXXX.zip
```

Hace todo en orden, un trabajo pesado a la vez:
1. Respalda los modelos actuales en `models/antes_<fecha>/`.
2. Importa los datos (las fotos van a `data/scene_board/` para Retina).
3. Hace fine-tuning del modelo de audio desde el actual y entrena la wake word "Oye Iris".
4. Exporta los archivos del firmware.
5. **Compara el modelo de audio nuevo con el anterior sobre el mismo test** (`compare_models.py`).
6. Verifica la librería del firmware (`tests/test_tflm_kernels.py`) y compila la XIAO.

Todo queda en `ciclo_<fecha>.log`. Si el modelo nuevo salió peor, se vuelve al anterior con `audio/export_model.py --tflite models/antes_<fecha>/audio_events_int8.tflite`. Con `--solo audio` o `--solo wake` se reentrena solo una parte. Retina no se reentrena aquí: necesita al profesor en GPU (ver `scene/README.md`).

## Qué hace la app con lo que detecta la placa

- **Escenas (Retina):** "¿qué hay adelante?" lo contesta la placa sin internet cuando la nube no responde, y el modo en vivo describe cada cambio de la escena (`CMD_SCENE` / `CMD_SCENE_LIVE`).
- **Audio:** **contexto silencioso.** Una persona ciega suele oír la sirena antes que el modelo, así que por defecto no se avisa en voz alta (`_speakAudioAlerts` en `assistant_screen.dart`).
- La placa manda cada 10 s un resumen de lo que más oyó (`CMD_AUDIO_CONTEXT`). Cuando el usuario pregunta algo, la app le pasa ese resumen y las alertas de los últimos 2 minutos a la IA de la nube como contexto (`SensorContext`). Por ejemplo, "se escuchan personas hablando", "se escuchó una sirena hace 20 s".

## Velocidad en la placa: ESP-NN (2026-10-16)

La librería TFLM que usaba el firmware no traía las optimizaciones del ESP32-S3. Ahora el firmware usa una copia local (`Hardware_ESP32/lib/TensorFlowLite_ESP32`, ver su `IRIS.md`) con los kernels **ESP-NN** de Espressif, que usan las instrucciones vectoriales del chip. Espressif mide su *person detection*, que era la misma red que nuestro antiguo modelo de visión en grises (MobileNetV1 0,25 a 96×96, ya retirado), en el ESP32-S3: **2.300 ms → 54 ms por imagen**. Antes, una sola inferencia tardaba más de 1 s.

**Cómo se verificó, sin la placa:**
- `python tests/test_tflm_kernels.py` compila la librería del firmware en el PC (versión C de ESP-NN) y corre 1.000 ejemplos de cada modelo. La clase coincide con TensorFlow en el 100 % y las salidas son idénticas en más del 99 %. Con `--reference`, los kernels originales dan exactamente lo mismo que ESP-NN.
- Este test encontró **dos errores que afectaban a la placa desde antes**:
  1. El convertidor nuevo cuantizaba la capa final por canal, y el TFLM de la placa solo entiende una escala. La placa calculaba mal los puntajes: cambiaba la clase en ~9 % de las imágenes. `export_model.py` ahora exporta esa capa por tensor y se niega a exportar si vuelve a pasar.
  2. Un `buffer_idx` sin inicializar en el softmax de ESP-NN.
- Las métricas de este README ahora se miden con los kernels de referencia de TFLite (`BUILTIN_REF`), que son los que imita la placa.

**En la placa:** al arrancar, cada modelo corre un ejemplo de prueba y lo compara con la salida esperada del PC. Así queda verificado también el ensamblador del S3, y además se mide el tiempo:

```text
[Audio IA] Autotest OK: 8.0 ms por inferencia, clase sirena, max dif 0
```

(Los tiempos son de ejemplo: los reales se verán con el prototipo.) Si sale `FALLO`, sube `pio run -e seeed_xiao_esp32s3_tflm_ref -t upload`, que usa los kernels sin optimizar, y compara.

## Cómo funciona el modelo de audio

```text
micrófono 16 kHz ─► log-mel 40 bandas cada 20 ms ─► ventana de 1 s (49×40) ─► DS-CNN int8 ─► CMD_AUDIO_EVENT por BLE ─► la app vibra y avisa
```

- Las features se calculan **igual** en Python (`audio/features.py`) y en el firmware (`Hardware_ESP32/src/audio_frontend.cpp`). `tests/test_frontend.py` compila el código C++ en el PC y verifica que den lo mismo.
- Las tablas del firmware (ventana, filtros mel) y el modelo se **generan** con `export_model.py`. No se editan a mano.
- La placa corre la red cada 0,5 s en su propia tarea, la pausa mientras se aprieta el botón y manda como alerta solo `bocina`, `sirena` y `perro` (umbral `ALERT_THRESHOLD` = 0,7 de `config.py`, sin repetir antes de 5 s). La app las usa como contexto silencioso (ver arriba).

## Resultados del modelo de audio v3 (2026-10-16)

Entrenado en CPU con ESC-50, **UrbanSound8K** y voz chilena (OpenSLR 71), sin datos de la placa. UrbanSound8K multiplica por ~10 las bocinas, sirenas y perros reales. v3 además suma 2 copias aumentadas de los "fondos difíciles" (campanas, aspiradora, motores, viento: `HARD_NEGATIVE_FACTOR = 2`), que antes se confundían con sirena. Todo se midió sobre el mismo test: 4.431 ventanas que ningún modelo vio (fold 10 de UrbanSound8K + ESC-50 + voz), con el modelo int8 de la placa:

| | v1 (solo ESC-50) | v2 (+ UrbanSound8K) | **v3 (actual)** |
|---|---|---|---|
| Exactitud general | 84,7 % | 88,3 % | 87,9 % |
| Alertas detectadas / falsas alarmas (umbral 0,7) | 57,9 % / 4,5 % | 69,7 % / 3,5 % | **71,4 % / 3,3 %** |
| Ídem con umbral 0,8 | 52,9 % / 3,4 % | 64,2 % / 2,5 % | **67,7 % / 2,2 %** |
| Bocina / sirena / perro detectados (umbral 0,7) | — | 86 / 56 / 77 % | 72 / 62 / 80 % |
| Voz / fondo reconocidos | 96 / 87 % | 96 / 89 % | 97 / 88 % |

v3 es mejor que v2 en todos los umbrales (detecta más **y** con menos falsas alarmas) y es más parejo entre clases. Pierde algo en bocinas y gana en sirenas. Tamaño: 29 KB en flash, ~2,6 M multiplicaciones, arena ~63 KB.

**Limitaciones conocidas:**
- La **sirena** sigue siendo la clase más débil (62 %).
- Hay ~130–360 ventanas de test por alerta (v1 tenía ~45), así que las cifras son bastante confiables. Aun así, nunca escuchó el micrófono PDM de la XIAO.
- En la app el audio se usa como **contexto silencioso**, no como aviso hablado (ver arriba).

## Puesta en marcha (una vez)

```bash
cd ML_Training
python -m venv --system-site-packages .venv
.venv\Scripts\activate          # en Linux/Lambda: source .venv/bin/activate
pip install -r requirements.txt
```

## Entrenar (todo el flujo)

Todos los comandos se corren desde `ML_Training/`.

```bash
python audio/download_datasets.py --urbansound --cleanup   # ESC-50 + voz chilena + UrbanSound8K (~9 GB de descarga, ~1 h)
python audio/prepare_dataset.py               # ventanas de 1 s + simulación del micrófono -> data/audio_dataset.npz
python audio/train.py                         # ~20 min en CPU, ~2 min en GPU
python audio/export_model.py                  # int8 + genera los archivos del firmware
python tests/test_frontend.py                 # verifica que firmware y Python calculen lo mismo
```

Después, compila y sube el firmware normal (`cd Hardware_ESP32 && pio run -t upload`).

Los resultados quedan en `models/audio_report_float.txt` y `models/audio_report_int8.txt`. El número que más importa es la línea final: **alertas detectadas** contra **falsas alarmas sobre fondo/voz**.

## Probar sin el prototipo

Audio, con el micrófono del notebook y el mismo modelo int8 y umbrales que la placa:

```bash
python audio/live_demo.py                  # usa el micrófono del notebook
python audio/live_demo.py --wav sirena.wav # o un archivo (busca sirenas/bocinas en YouTube o freesound.org)
```

Muestra los puntajes cada 0,5 s y marca 🔔 cuando la placa mandaría una alerta. Para Retina: `python scene/demo.py` (galería HTML con la frase del alumno para cada foto).

## Datos reales con cable USB (alternativa a la app)

El modelo v1 nunca ha "oído" el micrófono real. Con 10–20 minutos de grabaciones de la placa mejora mucho.

0. **Primero, verifica que el modelo arranque.** Sube el firmware normal y abre el monitor serial. Debe aparecer `[Audio IA] Listo: 5 clases, arena X/64512 bytes`.
   - Si dice `AllocateTensors fallo`, sube `kAudioTensorArenaSize`.
   - Para ver los puntajes en vivo, pon `AUDIO_EVENTS_DEBUG 1` en `config.h`. Ahí sabrás si el micrófono llega con buen nivel: en silencio debería ganar `fondo`.
1. Sube el firmware de captura (manda el micrófono crudo por USB, sin BLE):
   ```bash
   cd Hardware_ESP32
   pio run -e esp32-s3-devkitc-1_audio_capture -t upload     # devkit
   pio run -e seeed_xiao_esp32s3_audio_capture -t upload     # XIAO
   ```
2. Graba, desde `ML_Training/`:
   ```bash
   python audio/capture_from_board.py --label fondo --seconds 120 --note pieza
   python audio/capture_from_board.py --label fondo --seconds 120 --note calle
   python audio/capture_from_board.py --label voz --seconds 90
   python audio/capture_from_board.py --label sirena --seconds 30   # reproduce sirenas desde un parlante a varias distancias
   python audio/capture_from_board.py --label bocina --seconds 30
   python audio/capture_from_board.py --label perro --seconds 30
   ```
   Prioriza `fondo` en lugares distintos (casa, calle, micro, con la placa en el bolsillo o colgada). Es lo que evita las falsas alarmas.
3. Reentrena: `prepare_dataset.py` incluye `data/board/` automáticamente.
   ```bash
   python audio/prepare_dataset.py
   python audio/train.py --finetune
   python audio/export_model.py
   ```
4. Vuelve a subir el firmware normal.

## Entrenar en Lambda (NVIDIA Inception) o AWS

Para estos modelos chicos **no hace falta**: el CPU alcanza. Conviene en estos casos:
- Probar modelos más grandes (`train.py --width 1.5`) o más épocas (`--epochs 80`).

En una instancia de Lambda (Ubuntu, con GPU):
```bash
git clone https://github.com/yongiluu/Proyecto_Iris.git && cd Proyecto_Iris/ML_Training
python3 -m venv .venv && source .venv/bin/activate
pip install "tensorflow[and-cuda]" -r requirements.txt
python audio/download_datasets.py --urbansound --cleanup
python audio/prepare_dataset.py && python audio/train.py --epochs 80 && python audio/export_model.py
```
Luego copia a tu PC los archivos generados (`Hardware_ESP32/include/audio_model_data.h`, `Hardware_ESP32/src/audio_model_data.cpp`, `models/`) o haz commit desde la instancia. **Apaga la instancia al terminar**: se cobra por hora.

## Cambiar clases o features

1. Edita `audio/config.py` (`CLASSES`, `ALERT_CLASSES`, mapeos de datasets o parámetros del front-end).
2. Corre `prepare_dataset.py`, `train.py` y `export_model.py`.
3. Si agregas una alerta, añade su frase en `_audioAlertPhrases` (`App_Flutter/lib/features/assistant/screens/assistant_screen.dart`).

---

## Primeros datos reales de la app (2026-10-18): resultados del ciclo

(Registro histórico: visión y cercanía se retiraron después, ver más abajo.) Primer `ciclo_datos_reales.py` con el export de la app (`iris_dataset_20261018_202009.zip`): 492 fotos de cercanía, 50–200 fotos por clase de visión, 19 audios de fondo, 5 de voz, 3 de bocina, 3 de sirena y 3 de perro, 20 tomas de "Oye Iris" y 8 de frases parecidas. Todo fue grabado con el **celular**, no con la placa. Cada modelo se reforzó con fine-tuning desde el anterior.

**Medido con tus datos reales, que el modelo anterior nunca vio.** Es la medida más honesta que tenemos:

| Modelo | Antes (sin tus datos) | Después (reforzado) |
|---|---|---|
| Visión v5 → v5 + tus fotos | personas 36/60, cruces 38/100, falsos sobre "nada" 107/400 (27 %) | 48/60, 93/100, 51/400 (13 %) (*) |
| Audio v3 → v3 + tus audios (tomas de test) | bocina 35 % (31 ventanas), falsas con tu voz 24 % | **bocina 71 %**, falsas con tu voz 22 % |
| Cercanía v2 → v2 + tus fotos | "muy cerca" avisado 70 %, falsos con camino libre 30 % (492 fotos) | test (1 tanda de 40): muy cerca 6/6, falsos 16/24 |

(*) Casi todas tus tandas de fotos quedaron en train, así que la columna "después" de visión es optimista. La única tanda de test (25 fotos de escalera) bajó de 19 a 15. En el test de Open Images (8.383 recortes), v5 + tus fotos queda así: personas **64 %** (antes 59 %), con simulación OV2640 **57 %** (antes 48 %). Escalera baja de 79 a 75 % y cruce de 66 a 61 %. Los avisos falsos quedan casi iguales (7,0 % vs 6,8 %).

Conclusiones:
- Con fotos reales, los modelos entrenados con internet rinden bastante peor. Por eso sirven las misiones. (Visión v5 + tus fotos quedó como respaldo local en `models/vision_v6_candidato/`.)
- La cercanía daba muchos avisos falsos con fotos reales: sus pitidos quedaron apagados hasta que se retiró.
- Audio: la voz del usuario a veces dispara alertas en ventanas sueltas. El firmware promedia 2 inferencias, lo que debería bajar esos avisos, pero falta medirlo en la placa.

# Wake word "Oye Iris" (`wakeword/`)

```text
micrófono ─► log-mel (el mismo del modelo de audio) ─► DS-CNN 0,5 int8 (16 KB, cada 240 ms) ─► "Oye Iris" ─► tono + CMD_WAKE_WORD + CMD_PTT_START
```

La placa hace lo mismo que al apretar el botón: manda tu pregunta a la app y **corta sola** cuando dejas de hablar. Corta tras 0,9 s de silencio, si no hablas en 4 s o a los 10 s como máximo. También manda los 0,5 s de audio de antes de la detección, para no perder el comienzo de la pregunta ("Oye Iris, ¿qué hay adelante?"). La app no necesita cambios: recibe el mismo `CMD_PTT_START`/`CMD_PTT_STOP` que con el botón. Si aprietas el botón mientras habla el wake word, desde ahí manda el botón. Todo se configura en `include/config.h` (`WAKE_WORD_ENABLED`, `WAKE_*_MS`).

**Datos:** las misiones "Iris Wake Word" de la app (20 tomas de 30 s con ~12 "Oye Iris" cada una y 8 tomas de frases parecidas). `prepare_wake.py` corta cada "Oye Iris" por energía (242 tramos). En train, cada uno se usa 40 veces con otra velocidad (0,88–1,12x), otra posición, ruido de calle o casa y el micrófono simulado. Los negativos son las frases parecidas, los bordes de las tomas sin la frase completa, tus fondos y voz, 4.000 archivos de voz chilena (OpenSLR 71) y todo el dataset del modelo de audio. Las tomas se separan **enteras** en train, val y test.

**Resultado (2026-10-19), audio continuo de test, int8, umbral 0,90.** Se simula la placa: una ventana cada 240 ms y 2 s sin volver a activarse.

| | |
|---|---|
| "Oye Iris" detectados (4 tomas que el modelo no vio, 50 frases) | **44/50 = 88 %** |
| Activaciones falsas con 62 min de voz chilena (otros hablantes) | **0** (con umbral 0,83: 1) |
| Activaciones falsas con frases parecidas / tus fondos y voz | 0 / 0 (pero son solo 0,5 y 1,3 min de test) |
| Tamaño / arena declarada | 16 KB / 43 KB (el arranque muestra el uso real) |

**Limitaciones honestas:**
- Todas las frases son de **una sola persona** y grabadas con el celular. Con otras voces y con el micrófono de la placa puede despertar menos. Para mejorarlo, que otras personas graben la misión.
- En las tomas de test hay 4 activaciones que no calzan con ningún tramo cortado. Probablemente son "Oye Iris" que el corte por energía descartó (muy largos o pegados), así que se cuentan como falsas por precaución.

```bash
python wakeword/prepare_wake.py && python wakeword/train_wake.py && python wakeword/export_wake.py
python wakeword/export_wake.py --umbral 0.9        # fijar el umbral (por defecto lo elige: <= 1 activación falsa por hora)
```

`ciclo_datos_reales.py` ya incluye este paso (`--solo wake`). El monitor serial muestra `[Wake word] Autotest OK: x ms` al arrancar y `[Wake word] Oye Iris (93%)` en cada detección. Con `AUDIO_EVENTS_DEBUG 1` también imprime los puntajes > 0,3.

# Modelos en grises retirados (visión y cercanía)

**Retirados en 2026-11.** Hasta entonces la placa corría dos modelos chicos sobre el cuadrado central de la cámara en grises 96×96:

- **`vision_scenes`** (MobileNetV1 0,5, ~968 KB, Open Images + fotos de la app): `nada`, `persona`, `vehiculo`, `escalera`, `puerta`, `cruce`. La v5 detectaba ~59 % de personas, ~84 % de vehículos, ~79 % de escaleras, ~73 % de puertas y ~66 % de cruces, con ~7 % de avisos falsos por frame sobre "nada" (test de Open Images, int8).
- **`proximity`** (cercanía, MobileNetV1 0,25, ~300 KB, etiquetado por Depth Anything V2 + NYU Depth V2): `libre`, `cerca`, `muy_cerca`. Con fotos reales daba 30–60 % de avisos falsos con el camino libre, y sus pitidos estaban apagados.

**Por qué se retiraron:** la cámara pasó a color 160×120 y **Retina** (`scene/`), el modelo de escenas a color, sabe todo lo que sabía el de clases (personas, vehículos, escaleras, puertas, cruces por el lugar) y además describe colores, posiciones y el lugar. La cercanía no era confiable con una cámara; la solución de fondo es un sensor de distancia (VL53L1X, prototipo 3). Retirarlos libera flash y RAM en la placa.

Se borraron el código (`vision/`: descarga de Open Images, recortes, simulación OV2640, entrenamiento, export y demo), los modelos (`models/vision_scenes*`, `models/proximity*`), el firmware (`vision_task`, `tflite_vision`, `proximity`) y el modelo en la app. Lo que sigue en uso pasó a [`camara/`](camara/): `board_image.py` (referencia de la conversión de imagen de la placa) y `capture_photos.py` (fotos reales a color). Para recuperar algo, está en la historia de git (por ejemplo `git show 6c89bd7:ML_Training/vision/train.py`); los respaldos locales `models/vision_v*/` y `models/proximity_v1/` no están en git.

## Fotos reales de la placa (XIAO, prototipo 2)

Es lo que más va a mejorar a Retina: la cámara real, a la altura y con el ángulo reales.

```bash
cd Hardware_ESP32
pio run -e seeed_xiao_esp32s3_photo_capture -t upload     # manda los frames a color 160x120 por USB
cd ../ML_Training
python camara/capture_photos.py --note pasillo --count 300   # una foto cada 0,5 s mientras caminas
python camara/capture_photos.py --note casa --manual         # ESPACIO guarda cada foto
```

Las fotos quedan a color en `data/scene_board/` y las etiqueta el profesor (`scene/label_teacher.py`, fuente `board`). Después, vuelve a subir el firmware normal. Sirve también para revisar si la cámara quedó al revés (en ese caso, ver `camera_driver.cpp`).

## Licencias de los datos

ESC-50 y UrbanSound8K son **CC BY-NC** (uso no comercial), y la voz chilena (OpenSLR 71) es **CC BY-SA 4.0**. Sirven para el prototipo y la investigación. Para un producto comercial habría que reentrenar con datos propios o con licencia compatible.

Open Images V7: las anotaciones son **CC BY 4.0** y las fotos vienen de Flickr con licencia **CC BY 2.0** (Google no garantiza la licencia de cada foto). Los modelos no guardan fotos, pero los datasets locales (`data/scene/images/`) no se deben redistribuir.
