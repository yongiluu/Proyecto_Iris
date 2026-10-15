# Proyecto Iris - Release

Este repositorio contiene el código fuente completo del Proyecto Iris, un asistente inteligente visual y conversacional integrado en hardware portátil. El proyecto se divide en el firmware del hardware (ESP32-S3) y la aplicación cliente (Flutter).

## 🚀 La Revolución Inalámbrica (Arquitectura BLE)

El sistema funciona al 100% mediante **Bluetooth Low Energy (BLE)**, sin Wi-Fi ni WebSockets: menor consumo de batería, sin configurar Hotspots y conexión automática ("Plug & Play").

**Características clave:**
- **Auto-descubrimiento BLE:** La app escanea y se conecta automáticamente al dispositivo `Iris_ESP32` sin hardcodear direcciones IP, y reconecta sola si se pierde el enlace.
- **Transmisión de audio bidireccional:** El audio del micrófono I2S viaja en tiempo real a Flutter, y las respuestas (TTS) vuelven para reproducirse en el altavoz.
- **Visión artificial inalámbrica:** La app pide una foto JPEG a la placa; esta la envía en fragmentos por BLE con *backpressure* y la app valida que llegue completa.
- **Edge AI en la placa:** detección de personas (TensorFlow Lite Micro) y análisis de audio (FFT + red neuronal) locales.
- **Agente en la nube:** la app transcribe (Whisper), consulta al agente (modelo en Azure AI Foundry, por defecto `gpt-4.1-mini`) y devuelve la voz.

## Estructura del Proyecto

```text
Proyecto_Iris_Release/
├── App_Flutter/      # App móvil (frontend + IA)
└── Hardware_ESP32/   # Firmware del microcontrolador (ESP32-S3)
```

## 1. Aplicación Móvil (App_Flutter)

Construida con Flutter, actúa como el cerebro del sistema: procesa el audio recibido del ESP32, transcribe, se comunica con el agente y devuelve el audio de respuesta.

**Cómo correr la app:**
1. Asegúrate de tener Flutter instalado.
2. Abre la carpeta `App_Flutter` en tu terminal.
3. Copia `.env.template` a `.env` y completa las claves (Azure Foundry, Azure Speech, Hugging Face, LocationIQ, OpenWeather, Azure Search).
4. Ejecuta `flutter pub get` para instalar dependencias.
5. Conecta tu celular Android por USB (con depuración USB activada).
6. Ejecuta `flutter run` para compilar e instalar la app.

> ⚠️ `.env` se empaqueta dentro del APK, así que las claves son extraíbles. Está bien para el PoC; para producción hay que llamar a las APIs desde un backend propio.

## 2. Firmware del Prototipo (Hardware_ESP32)

Escrito en C++ con PlatformIO. Actúa como periférico BLE usando la librería NimBLE. Está dividido en módulos: `mic_driver`, `audio_player`, `camera_driver`, `ble_manager`, `photo_transfer`, `vision_task` y los modelos de Edge AI.

**Cómo compilar y subir el código:**
1. Abre la carpeta `Hardware_ESP32` usando PlatformIO en VS Code.
2. Elige el entorno: `esp32-s3-devkitc-1` (prototipo grande, por defecto) o `seeed_xiao_esp32s3` (prototipo 2), con `pio run -e <entorno>` o desde la barra inferior.
3. Conecta el ESP32 por USB y presiona "Upload".
4. *(Solo el entorno XIAO incluye `-DARDUINO_USB_MODE=1` y `-DARDUINO_USB_CDC_ON_BOOT=1`, que envían el Monitor Serial por el USB nativo. El devkit usa su puerto UART.)*

## 🔌 Conexiones de Hardware

Asegúrate de conectar los pines a sus respectivos VCC (3.3V o 5V) y GND. La fuente de verdad de los pines es `Hardware_ESP32/include/config.h`.

### ESP32-S3 devkit (prototipo grande)

**🎙️ Micrófono I2S (INMP441)**
- **SCK / BCLK** -> Pin 42
- **WS** -> Pin 41
- **SD / DOUT** -> Pin 40
- **L/R (Canal)** -> GND (32-bit, canal izquierdo, desplazado a 16-bit con saturación).

**🔊 Amplificador de audio I2S (MAX98357A)**
- **LRC** -> Pin 1
- **BCLK** -> Pin 2
- **DIN** -> Pin 21

**🔘 Botón físico (push-to-talk)**
- Un pin del botón -> Pin 14
- El otro pin -> GND (usa resistencia pull-up interna).

**📷 Cámara (OV2640)**
Configuración estándar D0-D7, XCLK, PCLK, VSYNC, HREF, SIOD, SIOC, PWDN, RESET definidos en `config.h`. Normalmente trabaja en escala de grises 96x96 (Edge AI). Cuando la app pide una foto (`CMD_TAKE_PHOTO`) se reconfigura a JPEG 640x480, se envía por BLE (`CMD_PHOTO_START:<bytes>` → fragmentos → `CMD_PHOTO_END`) y vuelve a grises.

### XIAO ESP32S3 Sense (prototipo 2)
- Micrófono PDM integrado: CLK -> GPIO42, DATA -> GPIO41.
- Amplificador MAX98357A: LRC -> GPIO1 (D0), BCLK -> GPIO2 (D1), DIN -> GPIO3 (D2).
- Botón push-to-talk -> GPIO4 (D3).

## Protocolo BLE

| Característica | UUID | Sentido | Contenido |
|---|---|---|---|
| RX | `6E400002-...` | app -> placa | Solo audio TTS (PCM 16-bit mono 16 kHz) |
| TX | `6E400003-...` | placa -> app | Audio del micrófono (PCM 16-bit mono 16 kHz) |
| CMD | `6E400004-...` | ambos | `CMD_PTT_START/STOP`, `CMD_TAKE_PHOTO`, `CMD_BEEP_THINKING`, `CMD_PHOTO_START:<n>`, `CMD_PHOTO_END`, `CMD_PHOTO_ERROR` |
| PHOTO | `6E400005-...` | placa -> app | Fragmentos de la foto JPEG |

## Problemas Frecuentes

- **Audio roto o entrecortado:** Si al mover el prototipo el audio suena roto o deja de funcionar, es un falso contacto o un cortocircuito en los cables que van a la bornera del altavoz.
- **La foto llega corrupta a la App:** La app descarta fotos incompletas (tamaño distinto al anunciado o sin cabecera JPEG). Revisa el monitor serial; el *backpressure* (`PHOTO_CHUNK_DELAY_MS` en `config.h`) evita la corrupción por saturar la cola BLE. Presiona de nuevo.
- **No suena el beep de "pensando":** los comandos (`CMD_BEEP_THINKING`, `CMD_TAKE_PHOTO`) viajan por la característica CMD, no por la de audio.
- **Error en el Monitor Serial (Upload failed):** Si PlatformIO lanza error de "Write timeout", cierra el monitor serial integrado de VS Code, desconecta y vuelve a conectar la placa.
