# ML_Training — Modelos Edge AI de Iris

Entrenamiento de los modelos TensorFlow Lite Micro que corren **dentro de la placa** (sin internet).

| Modelo | Estado | Qué detecta |
|---|---|---|
| Audio (`audio/`) | ✅ pipeline completo, modelo v3 (ESC-50 + UrbanSound8K + voz chilena) reforzado con audios de la app | `fondo`, `voz`, `bocina`, `sirena`, `perro` |
| Visión (`vision/`) | ✅ modelo v5 (MobileNet 0,5, Open Images) reforzado con fotos de la app | `nada`, `persona`, `vehiculo`, `escalera`, `puerta`, `cruce` |
| Cercanía (`vision/proximity_*`) | ✅ v2 reforzada con fotos de la app; pitidos apagados por ahora | `libre`, `cerca`, `muy_cerca` |
| Wake word (`wakeword/`) | ✅ v1 con las tomas de la app (una voz) | "Oye Iris" |

## Recolectar datos reales con la app (con o sin prototipo)

La app tiene una pantalla **Misiones de datos** (ícono 📋 arriba a la derecha en la pantalla principal). Te guía misión por misión ("Audio de calle 3/8", "Puertas 50/100") y guarda los audios y fotos en el celular, así que puedes grabar en la calle sin PC. En cada misión eliges la fuente:

- **Placa** (cuando llegue el prototipo): el micrófono y la cámara reales por Bluetooth. Es lo mejor.
- **Celular** (ya, sin prototipo): la cámara del celular convertida a 96×96 grises, igual que la placa, y el micrófono a 16 kHz sin filtros. No es el mismo sensor, pero sí tus calles, puertas, escaleras y micros. El modelo aprende esas escenas y después basta poco fine-tuning con la placa. Lleva el celular a la altura del pecho.

El origen queda en el nombre de cada archivo (`...__placa-<fecha>` o `...__cel-<fecha>`).

1. Sube una vez el firmware normal a la XIAO: `cd Hardware_ESP32 && pio run -e seeed_xiao_esp32s3 -t upload`.
2. En la app, elige el modo **Placa ESP32**, abre **Misiones de datos** y completa las misiones (~15 min de audio y ~750 fotos). Lleva la placa donde la usaría la persona. Cada grabación avisa si se perdió audio por Bluetooth, y puedes borrar la última toma si salió mal.
3. Pasa los datos al PC: botón **Exportar** (zip por Drive, correo, etc.) o, por USB, copia la carpeta `Android/data/<app>/files/iris_dataset`.
4. Impórtalos y reentrena, desde `ML_Training/`:
   ```bash
   python import_phone_data.py iris_dataset_XXXX.zip
   python audio/prepare_dataset.py && python audio/train.py --finetune && python audio/export_model.py
   python vision/prepare_dataset.py && python vision/train.py --finetune && python vision/export_model.py
   cd ../Hardware_ESP32 && pio run -e seeed_xiao_esp32s3 -t upload
   ```

Las misiones se editan en `App_Flutter/lib/features/data_collection/missions.dart`. El ambiente de cada grabación (casa, calle, transporte) queda en el nombre del archivo, para entrenar más adelante un modelo de ambiente. Los firmwares `*_audio_capture` y `*_photo_capture` con cable USB siguen sirviendo para pruebas en el escritorio.

### Reentrenar todo con tus datos: un solo comando

Después de exportar el zip desde la app (o con la carpeta copiada por USB):

```bash
python ciclo_datos_reales.py iris_dataset_XXXX.zip
```

Hace todo en orden, un trabajo pesado a la vez (~2–3 h en CPU):
1. Respalda los modelos actuales en `models/antes_<fecha>/`.
2. Importa los datos.
3. Etiqueta las fotos de la misión de cercanía con el profesor de profundidad.
4. Hace fine-tuning de los tres modelos desde los actuales.
5. Exporta los archivos del firmware.
6. **Compara cada modelo nuevo con el anterior sobre el mismo test** (`compare_models.py`).
7. Verifica la librería del firmware (`tests/test_tflm_kernels.py`) y compila la XIAO.

Todo queda en `ciclo_<fecha>.log`. Si un modelo nuevo salió peor, se vuelve al anterior con `export_model.py --tflite models/antes_<fecha>/<modelo>.tflite`. Con `--solo vision,cercania` se reentrena solo una parte.

## Qué hace la app con lo que detecta la placa

- **Visión:** aviso hablado y vibración ("Adelante hay una escalera"). En modo **Celular** el mismo modelo corre en el teléfono y avisa igual (ver "Probar visión sin el prototipo").
- **Audio:** **contexto silencioso.** Una persona ciega suele oír la sirena antes que el modelo, así que por defecto no se avisa en voz alta (`_speakAudioAlerts` en `assistant_screen.dart`).
- La placa manda cada 10 s un resumen de lo que más oyó y vio (`CMD_AUDIO_CONTEXT` / `CMD_VISION_CONTEXT`). Cuando el usuario pregunta algo, la app le pasa ese resumen y las alertas de los últimos 2 minutos a la IA de la nube como contexto (`SensorContext`). Por ejemplo, "se escuchan personas hablando", "puerta al frente", "se escuchó una sirena hace 20 s".

## Velocidad en la placa: ESP-NN (2026-10-16)

La librería TFLM que usaba el firmware no traía las optimizaciones del ESP32-S3. Ahora el firmware usa una copia local (`Hardware_ESP32/lib/TensorFlowLite_ESP32`, ver su `IRIS.md`) con los kernels **ESP-NN** de Espressif, que usan las instrucciones vectoriales del chip. Espressif mide su *person detection*, que es la misma red que nuestro modelo de visión (MobileNetV1 0,25 a 96×96), en el ESP32-S3: **2.300 ms → 54 ms por imagen**. Por eso la placa ahora mira cada 0,5 s (`VISION_INTERVAL_MS`). Antes, una sola inferencia tardaba más de 1 s.

**Cómo se verificó, sin la placa:**
- `python tests/test_tflm_kernels.py` compila la librería del firmware en el PC (versión C de ESP-NN) y corre 1.000 ejemplos de cada modelo. La clase coincide con TensorFlow en el 100 % y las salidas son idénticas en más del 99 %. Con `--reference`, los kernels originales dan exactamente lo mismo que ESP-NN.
- Este test encontró **dos errores que afectaban a la placa desde antes**:
  1. El convertidor nuevo cuantizaba la capa final por canal, y el TFLM de la placa solo entiende una escala. La placa calculaba mal los puntajes: cambiaba la clase en ~9 % de las imágenes. `export_model.py` ahora exporta esa capa por tensor y se niega a exportar si vuelve a pasar.
  2. Un `buffer_idx` sin inicializar en el softmax de ESP-NN.
- Además, la tabla píxel→int8 de la cámara ahora la genera el export (`kVisionInputLut`). Antes la calculaba la placa con `float` y redondeaba distinto que Python en la mitad de los píxeles.
- Las métricas de este README ahora se miden con los kernels de referencia de TFLite (`BUILTIN_REF`), que son los que imita la placa.

**En la placa:** al arrancar, cada modelo corre un ejemplo de prueba y lo compara con la salida esperada del PC. Así queda verificado también el ensamblador del S3, y además se mide el tiempo:

```text
[Vision IA] Autotest OK: 60 ms por imagen (ESP-NN optimizado), clase puerta, max dif 0
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

**Demo completa para presentar** (visión + sonido a la vez, con la webcam y el micrófono del notebook, los mismos modelos int8 y umbrales que la placa):

```bash
python demo_pc.py              # Q para salir, S para simular la cámara OV2640
```

Solo audio:

```bash
python audio/live_demo.py                  # usa el micrófono del notebook
python audio/live_demo.py --wav sirena.wav # o un archivo (busca sirenas/bocinas en YouTube o freesound.org)
```

Muestra los puntajes cada 0,5 s y marca 🔔 cuando la placa mandaría una alerta.

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

Primer `ciclo_datos_reales.py` con el export de la app (`iris_dataset_20261018_202009.zip`): 492 fotos de cercanía, 50–200 fotos por clase de visión, 19 audios de fondo, 5 de voz, 3 de bocina, 3 de sirena y 3 de perro, 20 tomas de "Oye Iris" y 8 de frases parecidas. Todo fue grabado con el **celular**, no con la placa. Cada modelo se reforzó con fine-tuning desde el anterior.

**Medido con tus datos reales, que el modelo anterior nunca vio.** Es la medida más honesta que tenemos:

| Modelo | Antes (sin tus datos) | Después (reforzado) |
|---|---|---|
| Visión v5 → v5 + tus fotos | personas 36/60, cruces 38/100, falsos sobre "nada" 107/400 (27 %) | 48/60, 93/100, 51/400 (13 %) (*) |
| Audio v3 → v3 + tus audios (tomas de test) | bocina 35 % (31 ventanas), falsas con tu voz 24 % | **bocina 71 %**, falsas con tu voz 22 % |
| Cercanía v2 → v2 + tus fotos | "muy cerca" avisado 70 %, falsos con camino libre 30 % (492 fotos) | test (1 tanda de 40): muy cerca 6/6, falsos 16/24 |

(*) Casi todas tus tandas de fotos quedaron en train, así que la columna "después" de visión es optimista. La única tanda de test (25 fotos de escalera) bajó de 19 a 15. En el test de Open Images (8.383 recortes), v5 + tus fotos queda así: personas **64 %** (antes 59 %), con simulación OV2640 **57 %** (antes 48 %). Escalera baja de 79 a 75 % y cruce de 66 a 61 %. Los avisos falsos quedan casi iguales (7,0 % vs 6,8 %).

Conclusiones:
- Con fotos reales, los modelos entrenados con internet rinden bastante peor. Por eso sirven las misiones. **Visión queda en v5 + tus fotos** (`models/vision_v6_candidato/`). v5 puro queda en `models/vision_v5/`.
- La cercanía da muchos avisos falsos con fotos reales: **los pitidos quedan apagados** en la placa (`PROXIMITY_BEEPS_ENABLED 0`) y en la app (`kProximityBeepsEnabled = false`). El nivel igual llega a la IA como contexto silencioso.
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

# Modelo de visión (`vision/`)

```text
cámara OV2640 96×96 grises ─► MobileNetV1 0.5 int8 (cada 0,5 s) ─► promedio de 2 frames ─► CMD_VISION_EVENT por BLE ─► la app vibra y avisa
```

- Clases (en `vision/config.py`): `nada`, `persona`, `vehiculo`, `escalera`, `puerta`, `cruce` (paso de cebra). Se avisa de todas menos `nada`, con umbral `ALERT_THRESHOLD` = 0,75 y sin repetir la misma clase antes de 8 s (`VISION_EVENT_COOLDOWN_MS`). La app además calla cada clase por 20 s.
- La entrada es exactamente lo que da la cámara (`FRAMESIZE_96X96`, `PIXFORMAT_GRAYSCALE`). El firmware convierte cada píxel con una tabla calculada de la cuantización del modelo, así que no hay que tocar código al reentrenar.
- La red es MobileNetV1 0,5 (v1–v3 usaban 0,25, como el *person detection* de Google), partiendo de pesos de ImageNet pasados a un canal. Usa solo `CONV_2D`, `DEPTHWISE_CONV_2D`, `AVERAGE_POOL_2D`, `FULLY_CONNECTED` y `SOFTMAX`, sin PAD, MEAN, SHAPE, STRIDED_SLICE ni PACK. `export_model.py` falla si aparece otra op.
- Pesa ~968 KB en flash y usa ~170 KB de arena (v1–v3: 306 KB y ~87 KB): la pide al heap, en RAM interna o, si no alcanza, en PSRAM.

**Datos:** subconjunto de **Open Images V7**. Se toman las cajas de validation y test (~100 MB de CSV) y, en streaming, las fotos de train con escaleras o puertas, que son raras. El CSV de 2,3 GB no se guarda. Cada foto se baja, se pasa a grises y se reduce a 256 px (~30 KB). De cada foto se sacan recortes cuadrados donde el objeto cubre al menos 10–15 % de la imagen. "Nada" son fotos sin esas clases más zonas vacías de las fotos con objetos (calles sin autos, paredes sin puertas).

**Simulación de la OV2640** (`vision/augment.py`): poca luz con más ruido, exposición y gamma, viñeteado, desenfoque y movimiento, baja resolución, ruido de sensor, artefactos JPEG, inclinación leve y zoom. Se aplica al azar en cada época. El reporte mide el test limpio y también un "test cámara" degradado con semilla fija.

## Visión v5 (2026-10-18): clase `cruce` (paso de cebra)

v5 es la misma red de v4 (MobileNetV1 0,5) con una sexta clase, `cruce`. Hay pocas fotos públicas: Open Images tiene 848 fotos etiquetadas "zebra crossing"/"crosswalk" (`vision/crosswalk_labels.py`), pero solo 349 se pueden bajar. De cada una salen 4 recortes. Además, `nada` suma los errores de v4 (*hard negatives*). Entrenamiento desde ImageNet, 25 épocas.

| Mismo test v5 (8.358 recortes), umbral 0,75, int8 | v4 | **v5 (actual)** |
|---|---|---|
| Exactitud (sin contar `cruce`, que v4 no conoce) | 84,0 % | 83,3 % (con `cruce`) |
| Avisos falsos sobre "nada" (limpio / simulación OV2640) | 5,5 % / 5,1 % | 6,8 % / 5,5 % |
| Persona / vehículo / escalera / puerta (limpio) | 58 / 85 / 75 / 75 % | 59 / 84 / **79** / 73 % |
| Detección media de las 4 clases (limpio / OV2640) | 73,2 % / 65,8 % | 73,7 % / 65,9 % |
| **Cruce detectado** (limpio / OV2640) | — | **66 % / 60 %** (avisos falsos de `cruce` sobre "nada": 0,2–0,3 %) |

En las 4 clases de antes, v5 rinde igual que v4. Escalera mejora y puerta empeora un poco. Tiene ~1 punto más de avisos falsos en el test limpio y casi lo mismo con la simulación de la cámara. A cambio, reconoce pasos de cebra. **Ojo:** el test de `cruce` son solo 168 recortes de unas 40 fotos, así que ese 66 % es una estimación gruesa. Con las fotos de la misión "Cruces peatonales" de la app (`ciclo_datos_reales.py`) debería subir bastante.

Para volver a v4 sin reentrenar (respaldo local en `models/vision_v4/`): `python vision/export_model.py --tflite models/vision_v4/vision_scenes_int8.tflite`. Además hay que dejar `CLASSES` sin `"cruce"` en `vision/config.py` y en la app.

Los semáforos no se agregaron: en grises no se distingue rojo de verde. Esa pregunta la responde la IA en la nube con la foto a color del celular.

## Resultados del modelo de visión v4 (2026-10-16): red más grande

Con ESP-NN la placa es ~40 veces más rápida, así que ya cabe una red más grande. v4 usa **MobileNetV1 0,5** en vez de 0,25 (los mismos datos de v3, pesos de ImageNet).

| Mismo test v3 (8.199 recortes), umbral 0,75 | v3 (MobileNet 0,25) | **v4 (MobileNet 0,5, actual)** |
|---|---|---|
| Exactitud general | 82,9 % | **84,6 %** |
| **Avisos falsos sobre "nada"** | 5,4 % | **4,8 %** |
| Detección media de las 4 clases | 70,6 % | **73,9 %** |
| Persona / vehículo / escalera / puerta | 57 / 82 / 72 / 71 % | **59 / 86 / 76 / 75 %** |
| Con simulación OV2640: avisos falsos / detección media | 5,4 % / 64,2 % | **4,4 % / 65,5 %** |
| Tamaño en flash / arena | 306 KB / ~87 KB | 968 KB / 170 KB |

v4 es mejor en todos los umbrales. Hace ~4 veces más cálculo: Espressif mide 54 ms para la red 0,25 con ESP-NN, así que v4 debería andar en ~100–300 ms. Probablemente use PSRAM, porque sus 170 KB de arena no caben en la RAM interna junto a Bluetooth y audio. El autotest al arrancar muestra el tiempo real.

**Si v4 resulta lenta en la placa**, se vuelve a v3 sin reentrenar:

```bash
python vision/export_model.py --tflite models/vision_v3/vision_scenes_int8.tflite
```

(`models/vision_v3/` es un respaldo local que no está en git. Si no lo tienes, `git show 96c026a:ML_Training/models/vision_scenes_int8.tflite > v3.tflite`. Ojo: ese archivo trae la capa final por canal y el export lo va a rechazar, así que hay que reconvertirlo desde `vision_scenes.keras` de ese commit.)

### Historial: v1 → v3 (MobileNet 0,25)


v1 a v3 usan la misma red (MobileNetV1 0,25, 306 KB, ~87 KB de arena). Lo que cambia son los datos:

- **v1:** ~17 mil fotos de Open Images.
- **v2:** ~48 mil fotos, rotación de Open Images corregida y **negativos difíciles**. El modelo v1 se confundía con el 26 % de las fotos de "nada" del train, y esas reciben recortes extra.
- **v3 (actual):** ~63 mil fotos, con el doble de personas (la clase más débil) y más vehículos, más una segunda ronda de negativos difíciles buscada con v2. v2 ya solo se confundía con el 12 % de las fotos de "nada".

Cada versión se comparó con la anterior **sobre el mismo test** (fotos que ningún modelo vio), con el modelo int8 de la placa, 1 frame y sin promediar.

| Test v3 (8.199 recortes) | v2 (umbral 0,7) | **v3 (umbral 0,75, actual)** |
|---|---|---|
| Exactitud general | 82,0 % | **82,8 %** |
| **Avisos falsos sobre "nada"** | 5,9 % | **5,4 %** |
| Avisos correctos (persona / vehículo / escalera / puerta) | 55 / 80 / 75 / 72 % | **57 / 82** / 72 / 72 % |
| Con simulación OV2640: avisos falsos / detección media | 5,7 % / 64,7 % | 5,5 % / 64,2 % |

| Test v2 (6.376 recortes) | v1 (umbral 0,8) | v2 (umbral 0,7) |
|---|---|---|
| Exactitud general | 80,2 % | 83,8 % |
| Avisos falsos sobre "nada" | 8,9 % | 5,9 % |
| Detección media de las 4 clases | 71 % | 71 % |

En resumen: de v1 a v3 los avisos falsos bajaron de ~9 % a ~5,4 % por frame con la misma detección (o +4–5 puntos de detección a igual nivel de avisos falsos). De v2 a v3 la mejora es chica (+2 puntos en personas y un poco menos de falsos). **Con datos públicos ya estamos cerca del techo: el próximo salto viene de fotos reales (misiones de la app).**

Barrido de umbrales de v3 (test v3, imagen limpia):

| Umbral | 0,6 | 0,7 | 0,75 | 0,8 | 0,9 |
|---|---|---|---|---|---|
| Avisos falsos sobre "nada" | 9,9 % | 6,6 % | 5,4 % | 3,9 % | 1,9 % |
| Detección media de las 4 clases | 78 % | 73 % | 71 % | 68 % | 59 % |

El umbral se cambia en `vision/config.py` (`ALERT_THRESHOLD`) y se aplica sin reentrenar con `python vision/export_model.py --tflite models/vision_scenes_int8.tflite`. La placa además promedia 2 frames, lo que debería bajar algo los falsos (no está medido).

**Limitaciones conocidas (léelas antes de confiar en el modelo):**
- **Nunca vio la cámara real.** Las cifras son sobre fotos de internet, encuadradas por fotógrafos. En la placa (altura del pecho, movimiento, OV2640) seguramente serán peores, hasta hacer el fine-tuning con las misiones de la app (con la placa o con el celular).
- **Persona sigue siendo la clase más débil** (57 % de avisos correctos, 49 % con la simulación): muchas fotos de "nada" tienen formas parecidas a personas.
- **No es un detector de obstáculos ni de distancia**: reconoce si al frente hay una persona, un vehículo, una escalera o una puerta. Postes, hoyos o ramas no son ninguna de esas clases. Un sensor de distancia (VL53L1X) queda para el prototipo 3.
- Las escaleras vienen de solo ~3.600 fotos (3 recortes cada una, correlacionados), así que su cifra es algo optimista. "Escalera" incluye escaleras mecánicas.
- La rotación se corrigió en las fotos de validation/test. En las de train de Open Images se omitió (`--skip-train-rotations`, el CSV es de 640 MB): afecta a ~1 % de esas fotos.
- No se mide aquí: tiempo por inferencia en la placa. La librería TFLM de la placa no trae las optimizaciones ESP-NN, así que podría tardar del orden de 1 s por frame. Ver el log al arrancar.

## Cercanía: ¿voy a chocar con algo? (`vision/proximity_*.py`)

El modelo de clases solo sabe si al frente hay una persona, un vehículo, una escalera o una puerta: una pared lisa para él es "nada". Para avisar antes de chocar hay un **segundo modelo chico** que, con la misma imagen 96×96 en grises, responde **libre / cerca (< 1,5 m) / muy cerca (< 0,7 m)**. Corre en la placa justo después del de clases (MobileNet 0,25, ~300 KB, unos 50 ms con ESP-NN). Avisa con **pitidos que se aceleran** desde la propia placa, como el sensor de retroceso de un auto: cada 0,8 s si está "cerca" y cada 0,25 s, más agudo, si está "muy cerca". También manda `CMD_PROXIMITY:<nivel>:<%>` por BLE, para que la app vibre.

**De dónde salen las distancias:**
- Un modelo "profesor" grande de profundidad, *Depth Anything V2* métrico (interior, versión chica), estima en metros la distancia de cada píxel de las fotos de Open Images (`vision/depth_labels.py`, ~1 s por foto en CPU). Es demasiado grande para la placa: solo sirve para etiquetar.
- **NYU Depth V2** aporta 1.449 fotos de interiores con profundidad real medida con Kinect (`vision/nyu_to_labels.py`).
- La etiqueta es la distancia más cercana (percentil 10) en la zona central de la imagen, sin el borde de abajo, porque ahí suele aparecer el suelo.
- Casi no hay fotos públicas tomadas a 50 cm de una pared. Por eso el train agrega **vistas acercadas con zoom**: acercar la imagen 1/s veces equivale aprox. a caminar hasta quedar a s·d metros, y la distancia se recalcula. El test no usa este truco.
- **Lo que más va a mejorar este modelo** son tus grabaciones de la misión "Acercarse a obstáculos" de la app: guardan la foto a color, que después etiqueta el profesor.

```bash
python vision/depth_labels.py --n 15000                 # profesor sobre Open Images (~4 h en CPU; retoma si se corta)
python vision/nyu_to_labels.py nyu_depth_v2_labeled.mat --delete   # opcional, profundidad real
python vision/depth_labels.py --source data/proximity_board --name board --n 0   # tus fotos de la misión
python vision/proximity_train.py --rebuild
python vision/proximity_export.py
```

**Límites (importante para la demo):** es una estimación con una cámara de 96×96 en grises. Debería detectar paredes, puertas, muebles y personas al frente a menos de ~1 m. **No** detecta hoyos, escalones hacia abajo ni cosas delgadas (postes finos, ramas), y se equivoca más con poca luz. Un sensor de distancia (VL53L1X, prototipo 3) es la solución de fondo.

**Resultados v2 (2026-10-18, actual):** ~15 mil fotos de Open Images etiquetadas por el profesor + NYU, con vistas acercadas. Test de 1.662 fotos sin trucar (ningún modelo las vio), modelo int8, 1 frame:

| | v1 (umbral 0,8) | **v2 (umbral 0,7)** |
|---|---|---|
| Test limpio: "muy cerca" (< 0,7 m) avisado | 73 % | **73 %** |
| Test limpio: pitidos falsos con el camino libre | 7,9 % | **6,3 %** |
| Con simulación OV2640: "muy cerca" avisado | 78 % | 69 % |
| Con simulación OV2640: pitidos falsos | 15,1 % | **6,5 %** |
| "Cerca" (0,7–1,5 m) avisado (limpio) | 40 % | 41 % |

La v1 pitaba el doble con la cámara mala, porque había aprendido que "borroso" es "cerca": las vistas con zoom quedaban más borrosas. La v2 pierde resolución al azar en todas las fotos, así que la cámara de la placa casi no cambia sus resultados. A igual nivel de pitidos falsos, la v2 detecta ~10 puntos más con la cámara simulada. La placa además promedia 2 frames (no medido).

## Entrenar visión

Desde `ML_Training/` (con el mismo `.venv` del audio):

```bash
python vision/download_datasets.py --skip-train-rotations   # ~63 mil fotos: ~4 GB de descarga, ~2 GB en disco, ~1,5 h
python vision/prepare_dataset.py --hard-negatives models/vision_scenes_int8.tflite   # recortes -> data/vision_dataset.npz (~40 min)
python vision/train.py --epochs 25 --workers 4   # MobileNet 0,5: ~3 h 45 min en CPU, ~20 min en GPU (no corras otra cosa pesada)
python vision/export_model.py             # int8 + valida ops + genera vision_model_data.h/.cpp
cd ../Hardware_ESP32 && pio run -e seeed_xiao_esp32s3 -t upload
```

Al arrancar, la placa debe imprimir `[Vision IA] Listo: 5 clases, arena X/... bytes`. Para ver los puntajes de cada frame, pon `VISION_EVENTS_DEBUG 1` en `config.h`.

## Probar visión sin el prototipo

```bash
python vision/live_demo.py              # webcam del notebook, recortada al centro y reducida a 96×96 grises
python vision/live_demo.py --simulate   # además la degrada como la OV2640 (tecla S para alternar)
python vision/live_demo.py --images carpeta/   # clasifica fotos sueltas
```

**En el celular (modo Celular de la app, sin placa):** el mismo `vision_scenes_int8.tflite` corre dentro de la app con `tflite_flutter`, sin internet. Sirve para mostrar la detección local aunque el prototipo no esté listo (por ejemplo en la final de los eAwards).

- Elige **Celular** en la pantalla principal y apunta la cámara trasera hacia adelante, a la altura del pecho. Al ver una puerta, dice "Adelante hay una puerta" y vibra.
- Hace lo mismo que el firmware (`tflite_vision.cpp`): 1 foto por segundo, recorte cuadrado central a 96×96 grises (`PhoneCapture.jpegToGray`, igual que las misiones), cuantización con los parámetros del tensor de entrada, promedio de 2 frames, umbral 0,75 y sin repetir la misma clase antes de 8 s. La app además calla cada clase por 20 s. Cada 10 s guarda la clase más vista como contexto para la IA (`SensorContext`).
- En cada foto corre también el modelo de **cercanía** (`assets/proximity_int8.tflite`, misma imagen, clases `libre`/`cerca`/`muy_cerca`, promedio de 2 frames, umbral 0,7 sobre cerca + muy cerca, igual que `proximity.cpp`). **Los pitidos y la vibración están apagados por ahora** (`kProximityBeepsEnabled = false` en `assistant_screen.dart`): con fotos reales daba 30–60 % de avisos falsos con el camino libre. El nivel solo llega como contexto silencioso a la IA. Con la constante en `true`, avisa como sensor de retroceso, sin voz: pitido y vibración cada 800 ms (cerca) o cada 250 ms y más agudo (muy cerca). En modo Módulo la placa pita sola y manda `CMD_PROXIMITY:<nivel>:<%>`; el celular solo vibra al mismo ritmo. Al reentrenar, copia también `models/proximity_int8.tflite` a `../App_Flutter/assets/`.
- Se pausa mientras hablas con Iris o abres las misiones (la cámara saca una foto a la vez). Mientras corre, la cámara saca fotos seguidas: gasta más batería.
- Código: `App_Flutter/lib/services/ai/phone_vision_service.dart`. **Al reentrenar**, copia el modelo nuevo a la app: `cp models/vision_scenes_int8.tflite ../App_Flutter/assets/`. Si cambian las clases o el umbral, actualiza también las constantes de ese archivo.
- No es la cámara de la placa: el celular ve más nítido y con mejor luz, así que en la demo seguramente detecte mejor que la XIAO.

## Fotos reales de la placa (XIAO, prototipo 2)

Es lo que más va a mejorar el modelo: la cámara real, a la altura y con el ángulo reales.

```bash
cd Hardware_ESP32
pio run -e seeed_xiao_esp32s3_photo_capture -t upload     # manda los frames 96x96 por USB (~5 por segundo)
cd ../ML_Training
python vision/capture_photos.py --label nada --count 300 --note casa       # una foto cada 0,5 s mientras caminas
python vision/capture_photos.py --label puerta --count 100 --note casa
python vision/capture_photos.py --label escalera --count 100 --note edificio
python vision/capture_photos.py --label vehiculo --count 100 --note calle
python vision/capture_photos.py --label persona --manual                     # ESPACIO guarda cada foto
```

Las fotos quedan en `data/vision_board/<clase>/`. Después corre `prepare_dataset.py`, `train.py --finetune` y `export_model.py`, y vuelve a subir el firmware normal. Prioriza `nada` en muchos lugares distintos: es lo que evita los avisos falsos. Sirve también para revisar si la cámara quedó al revés (en ese caso, ver `camera_driver.cpp`).

## Visión en Lambda

El CPU alcanza para esta red, pero en Lambda se pueden usar más datos:

```bash
python vision/download_datasets.py --scale 4    # 4x más fotos por clase (hay ~36 mil de personas, ~24 mil de vehículos)
python vision/prepare_dataset.py && python vision/train.py --epochs 60 && python vision/export_model.py
```

Para más escaleras y puertas, agrega `"persona"`/`"vehiculo"` a `TRAIN_SEARCH_CLASSES` en `download_datasets.py` (el filtrado de train trae todas sus fotos) o suma otra fuente. **VizWiz** (fotos tomadas por personas ciegas) quedó pendiente: no tiene etiquetas de estas clases, y sus zips (>10 GB) no caben en el disco local.

## Licencias de los datos

ESC-50 y UrbanSound8K son **CC BY-NC** (uso no comercial), y la voz chilena (OpenSLR 71) es **CC BY-SA 4.0**. Sirven para el prototipo y la investigación. Para un producto comercial habría que reentrenar con datos propios o con licencia compatible.

Open Images V7: las anotaciones son **CC BY 4.0** y las fotos vienen de Flickr con licencia **CC BY 2.0** (Google no garantiza la licencia de cada foto). El modelo de visión no guarda fotos, pero el dataset local (`data/vision_images/`) no se debe redistribuir.
