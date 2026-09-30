# Proyecto Iris - Release

Este repositorio contiene el código fuente completo del Proyecto Iris, un asistente inteligente visual y conversacional integrado en hardware portátil. El proyecto se divide en el firmware del hardware (ESP32-S3) y la aplicación cliente (Flutter).

## 🚀 La Revolución Inalámbrica (Arquitectura BLE)

¡El proyecto ha sido completamente rediseñado para **eliminar el uso de Wi-Fi y WebSockets**! Ahora el sistema funciona al 100% mediante **Bluetooth Low Energy (BLE)**, lo que permite un menor consumo de batería, elimina la necesidad de configurar Hotspots y hace que la conexión sea automática ("Plug & Play").

**Nuevas características clave:**
- **Auto-descubrimiento BLE:** La app escanea y se conecta automáticamente al dispositivo Iris_ESP32 sin necesidad de hardcodear direcciones IP.
- **Transmisión de Audio Bidireccional:** El audio capturado por el micrófono I2S se empaqueta y envía en tiempo real vía BLE a Flutter, y las respuestas (TTS) viajan de vuelta para reproducirse en el altavoz.
- **Visión Artificial Inalámbrica:** Captura de fotos mediante la cámara del ESP32 enviadas en fragmentos (chunks) por BLE. Utiliza un algoritmo de *'backpressure'* garantizando que las imágenes JPEG lleguen completas y sin corrupción por problemas de MTU.
- **Integración total con GPT-4o Vision:** El agente analiza el audio e imágenes capturadas por el dispositivo.

## Estructura del Proyecto

`	ext
Proyecto_Iris_Release/
├── App_Flutter/      # Código fuente de la app móvil (Frontend + IA)
└── Hardware_ESP32/   # Código fuente del microcontrolador (Hardware ESP32-S3)
`

## 1. Aplicación Móvil (App_Flutter)

Construida con Flutter, actúa como el cerebro del sistema. Procesa el audio recibido del ESP32, realiza transcripción (Whisper), se comunica con el agente (GPT-4o) y devuelve el audio de respuesta.

**Cómo correr la app:**
1. Asegúrate de tener Flutter instalado.
2. Abre la carpeta App_Flutter en tu terminal.
3. Ejecuta lutter pub get para instalar dependencias.
4. Conecta tu celular Android por USB (con depuración USB activada).
5. Ejecuta lutter run para compilar e instalar la app.

## 2. Firmware del Prototipo (Hardware_ESP32)

Escrito en C++ con PlatformIO. Actúa como periférico BLE usando la librería altamente optimizada NimBLE.

**Cómo compilar y subir el código:**
1. Abre la carpeta Hardware_ESP32 usando PlatformIO en VS Code.
2. Conecta el ESP32 por USB y presiona "Upload".
3. *(Nota: La compilación ya incluye -DARDUINO_USB_MODE=1 y -DARDUINO_USB_CDC_ON_BOOT=1 para habilitar el Monitor Serial nativo del ESP32-S3).*

## 🔌 Conexiones de Hardware (Pines ESP32-S3 WROOM)

Asegúrate de conectar los pines a sus respectivos VCC (3.3V o 5V) y GND.

### 🎙️ Micrófono I2S (INMP441)
- **SCK / BCLK** -> Pin 42
- **WS / L/R** -> Pin 41
- **SD / DOUT** -> Pin 40
- **L/R (Canal)** -> GND (Configurado a 32-bit I2S_CHANNEL_FMT_ONLY_LEFT y desplazado a 16-bit).

### 🔊 Amplificador de Audio I2S (MAX98357A)
- **LRC** -> Pin 1
- **BCLK** -> Pin 2
- **DIN** -> Pin 21

### 🔘 Botón Físico (Push-to-talk)
- **Un pin del botón** -> Pin 14
- **El otro pin del botón** -> GND (Usa resistencia pull-up interna del código).

### 📷 Cámara (OV2640)
*(Configuración estándar D0-D7, XCLK, PCLK, VSYNC, HREF, SIOD, SIOC, PWDN, RESET definidos en config.h)*.

## Problemas Frecuentes

- **Audio roto o entrecortado:** Si al mover el prototipo el audio suena roto o deja de funcionar, es un falso contacto o un cortocircuito en los cables que van a la bornera del altavoz.
- **La foto llega corrupta a la App:** Revisa el monitor serial, el algoritmo de *backpressure* (delay(20)) está diseñado para evitar esto, pero si sigues viendo errores, la cámara pudo capturar mal el cuadro. Presiona de nuevo.
- **Error en el Monitor Serial (Upload failed):** Si PlatformIO lanza error de "Write timeout", cierra el monitor serial integrado de VS Code, desconecta y vuelve a conectar la placa.