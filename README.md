# Proyecto Iris - Release

Este repositorio contiene el c贸digo fuente completo del Proyecto Iris, un asistente inteligente integrado en hardware port谩til. El proyecto se divide en dos componentes principales: el firmware del hardware (ESP32) y la aplicaci贸n cliente (Flutter).

## Estructura del Proyecto

```text
Proyecto_Iris_Release/
鈹溾攢鈹� App_Flutter/      # C贸digo fuente de la app m贸vil (Frontend + IA)
鈹斺攢鈹� Hardware_ESP32/   # C贸digo fuente del microcontrolador (Hardware)
```

## 1. Aplicaci贸n M贸vil (App_Flutter)

La aplicaci贸n m贸vil est谩 construida con Flutter y act煤a como el cerebro y cliente del sistema. Se encarga de procesar el audio que recibe del ESP32, realizar la transcripci贸n (Speech-to-Text), comunicarse con el agente de IA de Occipital, y gestionar la interfaz de usuario.

**Caracter铆sticas principales:**
- Conexi贸n v铆a WebSocket (Puerto 81) con el ESP32.
- Gesti贸n de estados de hardware (PTT - Push To Talk).
- Recepci贸n de buffers de audio en tiempo real y decodificaci贸n.

**C贸mo correr la app:**
1. Aseg煤rate de tener Flutter instalado.
2. Abre la carpeta `App_Flutter` en tu terminal.
3. Ejecuta `flutter pub get` para instalar dependencias.
4. Conecta tu celular por USB (con depuraci贸n USB activada).
5. Ejecuta `flutter run` para compilar e instalar la app.

> **Importante:** La IP del ESP32 est谩 hardcodeada en `lib/features/assistant/screens/assistant_screen.dart`. Si la IP del ESP32 cambia, debes actualizar la constante `ESP32_IP` en ese archivo.

## 2. Firmware del Prototipo (Hardware_ESP32)

El c贸digo del ESP32 est谩 escrito en C++ y utiliza PlatformIO (o Arduino IDE). Su funci贸n principal es actuar como un servidor WebSocket que captura el audio del micr贸fono, env铆a los datos a la app m贸vil y reproduce el audio de respuesta a trav茅s de un amplificador I2S (MAX98357A).

**Caracter铆sticas principales:**
- Servidor WebSocket (Puerto 81).
- Captura de audio anal贸gico (Micr贸fono INMP441 / gen茅rico).
- Salida de audio digital I2S (MAX98357A).
- Lectura de bot贸n f铆sico (Push to Talk) y env铆o de comandos `CMD_PTT_START` / `CMD_PTT_STOP`.

**C贸mo compilar y subir el c贸digo:**
1. Abre la carpeta `Hardware_ESP32` usando PlatformIO en VS Code (o Arduino IDE).
2. Aseg煤rate de que las credenciales Wi-Fi en el c贸digo correspondan al Hotspot del celular que vas a usar.
3. Conecta el ESP32 por USB y presiona "Upload".

**Truco de conexi贸n (IP):**
Como la app necesita saber la IP del ESP32, hemos programado una funci贸n especial: **Cada vez que presionas el bot贸n f铆sico del prototipo, el ESP32 imprimir谩 su direcci贸n IP en el Monitor Serial.** Solo conecta el ESP32 a la PC, abre el monitor serial, presiona el bot贸n, copia la IP resultante, y actual铆zala en el c贸digo de Flutter.

## Problemas Frecuentes de Hardware

- **Audio roto o entrecortado:** Si al mover el prototipo el audio suena roto o deja de funcionar, es un falso contacto o un cortocircuito en los cables que van a la bornera del altavoz. Revisa que los cables est茅n bien apretados y el cobre no toque otros cables.
- **No se conecta al Hotspot:** Aseg煤rate de que el Hotspot del celular est茅 configurado para emitir en la banda de **2.4 GHz** (la opci贸n "Maximizar compatibilidad" debe estar encendida en iOS/Android). El ESP32 no soporta 5 GHz.

## Conexiones de Hardware (Pines ESP32-S3 WROOM)

A continuaci髇 se detalla el esquema de conexi髇 exacto para que el hardware funcione con el c骴igo actual. Aseg鷕ate de conectar los pines a sus respectivos VCC (3.3V o 5V) y GND.

### Micr骹ono I2S (Ej. INMP441)
- **SCK / BCLK** -> Pin 42
- **WS / L/R** -> Pin 41
- **SD / DOUT** -> Pin 40
- **L/R (Canal)** -> GND (Para usar canal izquierdo)

### Amplificador de Audio I2S (Ej. MAX98357A)
- **LRC** -> Pin 1
- **BCLK** -> Pin 2
- **DIN** -> Pin 21

### Bot髇 F韘ico (Push-to-talk)
- **Un pin del bot髇** -> Pin 14
- **El otro pin del bot髇** -> GND (Usa resistencia pull-up interna del c骴igo)

