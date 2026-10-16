# ML_Training — Modelos Edge AI de Iris

Entrenamiento de los modelos TensorFlow Lite Micro que corren **dentro de la placa** (sin internet).

| Modelo | Estado | Qué detecta |
|---|---|---|
| Audio (`audio/`) | ✅ pipeline completo, modelo v2 (ESC-50 + UrbanSound8K + voz chilena) | `fondo`, `voz`, `bocina`, `sirena`, `perro` |
| Visión (`vision/`) | ✅ pipeline completo, modelo v1 entrenado con Open Images | `nada`, `persona`, `vehiculo`, `escalera`, `puerta` |

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

## Qué hace la app con lo que detecta la placa

- **Visión:** aviso hablado y vibración ("Adelante hay una escalera").
- **Audio:** **contexto silencioso.** Una persona ciega suele oír la sirena antes que el modelo, así que por defecto no se avisa en voz alta (`_speakAudioAlerts` en `assistant_screen.dart`).
- La placa manda cada 10 s un resumen de lo que más oyó y vio (`CMD_AUDIO_CONTEXT` / `CMD_VISION_CONTEXT`). Cuando el usuario pregunta algo, la app le pasa ese resumen y las alertas de los últimos 2 minutos a la IA de la nube como contexto (`SensorContext`). Por ejemplo, "se escuchan personas hablando", "puerta al frente", "se escuchó una sirena hace 20 s".

## Cómo funciona el modelo de audio

```text
micrófono 16 kHz ─► log-mel 40 bandas cada 20 ms ─► ventana de 1 s (49×40) ─► DS-CNN int8 ─► CMD_AUDIO_EVENT por BLE ─► la app vibra y avisa
```

- Las features se calculan **igual** en Python (`audio/features.py`) y en el firmware (`Hardware_ESP32/src/audio_frontend.cpp`). `tests/test_frontend.py` compila el código C++ en el PC y verifica que den lo mismo.
- Las tablas del firmware (ventana, filtros mel) y el modelo se **generan** con `export_model.py`. No se editan a mano.
- La placa corre la red cada 0,5 s en su propia tarea, la pausa mientras se aprieta el botón y manda como alerta solo `bocina`, `sirena` y `perro` (umbral `ALERT_THRESHOLD` = 0,7 de `config.py`, sin repetir antes de 5 s). La app las usa como contexto silencioso (ver arriba).

## Resultados del modelo de audio v2 (2026-10-15)

Entrenado en CPU con ESC-50, **UrbanSound8K** y voz chilena (OpenSLR 71), sin datos de la placa. UrbanSound8K multiplica por ~10 las bocinas, sirenas y perros reales. Se midió sobre el test nuevo: 4.431 ventanas de grabaciones que el modelo no vio (fold 10 de UrbanSound8K + ESC-50 + voz). Para comparar de forma justa, v1 se midió sobre ese mismo test. Ambos son el modelo int8 que corre en la placa:

| | v1 (solo ESC-50) | **v2 (actual)** |
|---|---|---|
| Exactitud general | 84,7 % | **88,3 %** |
| Bocina / sirena / perro reconocidos | 66 / 56 / 66 % | **92 / 62 / 81 %** |
| Voz / fondo | 96 / 87 % | 96 / 89 % |
| Alertas detectadas con umbral 0,7 | 57,9 % | **69,7 %** |
| Falsas alarmas sobre fondo/voz | 4,5 % | **3,5 %** |
| Con umbral 0,8 | 52,9 % / 3,4 % | 64,2 % / 2,5 % |

Tamaño: 29 KB en flash, ~2,6 M multiplicaciones por inferencia, arena ~63 KB.

**Limitaciones conocidas:**
- La **sirena** es la clase más débil (62 %): se confunde con sonidos sostenidos o tonales.
- Ahora hay ~130–360 ventanas de test por alerta (v1 tenía ~45), así que las cifras son bastante más confiables. Aun así, nunca escuchó el micrófono PDM de la XIAO.
- En la app, el audio se usa como **contexto silencioso**, no como aviso hablado (ver arriba).

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

# Modelo de visión (`vision/`)

```text
cámara OV2640 96×96 grises ─► MobileNetV1 0.25 int8 (1 vez por segundo) ─► promedio de 2 frames ─► CMD_VISION_EVENT por BLE ─► la app vibra y avisa
```

- Clases (en `vision/config.py`): `nada`, `persona`, `vehiculo`, `escalera`, `puerta`. Se avisa de todas menos `nada`, con umbral `ALERT_THRESHOLD` = 0,7 y sin repetir la misma clase antes de 8 s (`VISION_EVENT_COOLDOWN_MS`). La app además calla cada clase por 20 s.
- La entrada es exactamente lo que da la cámara (`FRAMESIZE_96X96`, `PIXFORMAT_GRAYSCALE`). El firmware convierte cada píxel con una tabla calculada de la cuantización del modelo, así que no hay que tocar código al reentrenar.
- La red es MobileNetV1 0,25 (como el *person detection* de Google), partiendo de pesos de ImageNet pasados a un canal. Usa solo `CONV_2D`, `DEPTHWISE_CONV_2D`, `AVERAGE_POOL_2D`, `FULLY_CONNECTED` y `SOFTMAX`, sin PAD, MEAN, SHAPE, STRIDED_SLICE ni PACK. `export_model.py` falla si aparece otra op.
- Pesa ~306 KB en flash, hace ~7,3 M MAC por imagen y usa ~87 KB de arena: la pide al heap, en RAM interna o, si no alcanza, en PSRAM.

**Datos:** subconjunto de **Open Images V7**. Se toman las cajas de validation y test (~100 MB de CSV) y, en streaming, las fotos de train con escaleras o puertas, que son raras. El CSV de 2,3 GB no se guarda. Cada foto se baja, se pasa a grises y se reduce a 256 px (~30 KB). De cada foto se sacan recortes cuadrados donde el objeto cubre al menos 10–15 % de la imagen. "Nada" son fotos sin esas clases más zonas vacías de las fotos con objetos (calles sin autos, paredes sin puertas).

**Simulación de la OV2640** (`vision/augment.py`): poca luz con más ruido, exposición y gamma, viñeteado, desenfoque y movimiento, baja resolución, ruido de sensor, artefactos JPEG, inclinación leve y zoom. Se aplica al azar en cada época. El reporte mide el test limpio y también un "test cámara" degradado con semilla fija.

## Resultados del modelo de visión v1

Entrenado en CPU (30 épocas, ~50 min) con ~24,6 mil recortes de ~13,9 mil fotos de Open Images, sin fotos de la placa. Se midió sobre el test (3.269 recortes de fotos que no vio al entrenar) con el modelo **int8**, que es lo que corre en la placa:

| | Test limpio | Test con simulación OV2640 |
|---|---|---|
| Exactitud general | 82,7 % | 78,4 % |
| Recall nada / persona / vehículo / escalera / puerta | 74 / 72 / 89 / 89 / 86 % | 73 / 64 / 82 / 82 / 83 % |
| Avisos correctos con umbral 0,8 (persona / vehículo / escalera / puerta) | 54 / 82 / 78 / 73 % | 42 / 74 / 70 / 69 % |
| **Avisos falsos sobre "nada"** (umbral 0,8, 1 frame) | **10,8 %** | **9,6 %** |
| Aviso de la clase equivocada | 1,8 % | 2,4 % |

Con umbral 0,7 se detecta ~5 puntos más, pero los avisos falsos suben a ~14 %. Por eso v1 usa 0,8. La placa además promedia 2 frames, lo que debería bajar algo los falsos (no está medido).

**Limitaciones conocidas (léelas antes de confiar en el modelo):**
- **Nunca vio la cámara real.** Las cifras son sobre fotos de internet, encuadradas por fotógrafos. En la placa (altura del pecho, movimiento, OV2640) seguramente serán peores hasta hacer el fine-tuning con `capture_photos.py`.
- **Persona es la clase más débil** (54 % de avisos correctos, 42 % con la simulación) y la que más avisos falsos genera sobre "nada": muchas fotos de "nada" tienen formas o reflejos parecidos a personas. El *person detection* genérico de Google, entrenado con 115 mil fotos, era probablemente mejor para personas solas. A cambio, este modelo suma vehículos, escaleras y puertas.
- Un ~10 % de avisos falsos por frame sigue siendo mucho para avisos de voz: la placa no repite una clase antes de 8 s y la app calla cada clase por 20 s. Con fotos reales de `nada` esto debería mejorar bastante.
- Las escaleras vienen de solo ~3.600 fotos (3 recortes cada una, correlacionados), así que su cifra es algo optimista. "Escalera" incluye escaleras mecánicas.
- Algunas fotos de Open Images vienen giradas 90° (no se aplicó su metadato de rotación): es ruido menor en el entrenamiento.
- No se mide aquí: tiempo por inferencia en la placa (MobileNet 0,25 a 96×96 suele tardar unos cientos de ms sin optimizaciones ESP-NN; la placa infiere 1 vez por segundo) ni la RAM real libre con BLE + audio + visión. Ver el log al arrancar.

## Entrenar visión

Desde `ML_Training/` (con el mismo `.venv` del audio):

```bash
python vision/download_datasets.py        # ~2,4 GB de descarga (la mayoría en streaming), ~0,6 GB en disco, ~45 min
python vision/prepare_dataset.py          # recortes etiquetados -> data/vision_dataset.npz (~10 min)
python vision/train.py                    # ~55 min en CPU (30 épocas), ~5 min en GPU
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
