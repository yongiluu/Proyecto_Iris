# ML_Training — Modelos Edge AI de Iris

Entrenamiento de los modelos TensorFlow Lite Micro que corren **dentro de la placa** (sin internet).

| Modelo | Estado | Qué detecta |
|---|---|---|
| Audio (`audio/`) | ✅ pipeline completo, modelo v1 entrenado con datos públicos | `fondo`, `voz`, `bocina`, `sirena`, `perro` |
| Visión | ⏳ pendiente (hoy la placa usa el *person detection* genérico de Google) | — |

## Cómo funciona el modelo de audio

```text
micrófono 16 kHz ─► log-mel 40 bandas cada 20 ms ─► ventana de 1 s (49×40) ─► DS-CNN int8 ─► CMD_AUDIO_EVENT por BLE ─► la app vibra y avisa
```

- Las features se calculan **igual** en Python (`audio/features.py`) y en el firmware (`Hardware_ESP32/src/audio_frontend.cpp`). `tests/test_frontend.py` compila el código C++ en el PC y verifica que den lo mismo.
- Las tablas del firmware (ventana, filtros mel) y el modelo se **generan** con `export_model.py`. No se editan a mano.
- La placa corre la red cada 0,5 s en su propia tarea, la pausa mientras se aprieta el botón y avisa solo de `bocina`, `sirena` y `perro` (umbral `ALERT_THRESHOLD` = 0,7 de `config.py`, sin repetir antes de 5 s).

## Resultados del modelo v1 (2026-10-14)

Entrenado en CPU con ESC-50 y voz chilena (OpenSLR 71), sin datos de la placa. Medido sobre el test (datos que no vio al entrenar) con el modelo int8, que es lo que corre en la placa:

| | |
|---|---|
| Tamaño | 29 KB en flash, ~2,6 M multiplicaciones por inferencia |
| Exactitud general | 89,5 % |
| Voz / fondo | 96 % / 86 % de recall |
| Sirena / perro / bocina detectados | 88 % / 94 % / **43 %** |
| Con umbral 0,7 | se detecta el **70 %** de las alertas, con **4,9 %** de falsas alarmas sobre ventanas de fondo o voz |

**Limitaciones conocidas:**
- Hay solo 40 grabaciones por alerta en ESC-50 (≈45 ventanas de test por clase), así que las cifras de alertas son aproximadas.
- Las bocinas son la clase más débil.
- Los sonidos sostenidos (campanas, aspiradora, viento, gallos) a veces se confunden con sirena.

**Experimento v2 (descartado):** sumar copias extra de esos "fondos difíciles" (`HARD_NEGATIVE_FACTOR=4`) y pesos `--class-weight sqrt` bajó las falsas alarmas a 2,1 %, pero también las detecciones a 53 %. A igual nivel de falsas alarmas, v1 detecta más. Vale la pena repetirlo cuando haya más alertas (UrbanSound8K o datos de la placa).

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
python audio/download_datasets.py --cleanup   # ESC-50 + voz chilena (~1,9 GB de descarga)
python audio/prepare_dataset.py               # ventanas de 1 s + simulación del micrófono -> data/audio_dataset.npz
python audio/train.py                         # ~20 min en CPU, ~2 min en GPU
python audio/export_model.py                  # int8 + genera los archivos del firmware
python tests/test_frontend.py                 # verifica que firmware y Python calculen lo mismo
```

Después, compila y sube el firmware normal (`cd Hardware_ESP32 && pio run -t upload`).

Los resultados quedan en `models/audio_report_float.txt` y `models/audio_report_int8.txt`. El número que más importa es la línea final: **alertas detectadas** contra **falsas alarmas sobre fondo/voz**.

## Probar sin el prototipo

```bash
python audio/live_demo.py                  # usa el micrófono del notebook
python audio/live_demo.py --wav sirena.wav # o un archivo (busca sirenas/bocinas en YouTube o freesound.org)
```

Muestra los puntajes cada 0,5 s y marca 🔔 cuando la placa mandaría una alerta.

## Cuando llegue el prototipo: datos reales (lo que más mejora el modelo)

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
- Sumar **UrbanSound8K** (`download_datasets.py --urbansound`, ~6 GB): muchas más bocinas, sirenas y perros reales. Es la mejora más grande que se puede hacer sin el prototipo, pero no cabe en el disco local.
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

## Licencias de los datos

ESC-50 y UrbanSound8K son **CC BY-NC** (uso no comercial), y la voz chilena (OpenSLR 71) es **CC BY-SA 4.0**. Sirven para el prototipo y la investigación. Para un producto comercial habría que reentrenar con datos propios o con licencia compatible.
