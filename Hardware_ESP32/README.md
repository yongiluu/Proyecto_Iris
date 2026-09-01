##Estructura del Proyecto (Tree)
```
Hardware_ESP32/
├── include/               # headers (.h)
│   ├── audio_player.h     # audio driver I2S
│   ├── camera_driver.h    # camera driver and server HTTP
│   └── config.h           # wifi credentials, pinout and parameters
├── src/
│   ├── audio_player.cpp   # audio processing
│   ├── camera_driver.cpp  # jpeg capture and server HTTP for app (/capture)
│   └── main.cpp
├── platformio.ini
└── README.md
```
##Componentes de Hardware Necesarios
- Núcleo y Visión
    - Procesador principal: ESP32-S3 con 8MB de PSRAM integrada (Ej: Seeed Studio XIAO ESP32S3 Sense o ESP32-S3-CAM DevKit).
    - Sensor de Imagen: Cámara OV2640 o OV5640 conectada mediante bus flexible FPC.
- Sistema de Audio (Salida)
    - Amplificador I2S: Módulo MAX98357A (DAC + Amplificador Clase D).
    - Reproductor: Micro altavoz de 8 ohm/1W.
- Alimentación y Controles
    - Batería: LiPo de 3.7V (350mAh - 500mAh).
    - Gestión de Carga: Módulo TP4056 (o el circuito de carga integrado si se usa la placa XIAO).
    - Interacción: Pulsador SMD / Push Button de 2 pines (para activar lectura en fases avanzadas).
    - Interruptor: Switch ON/OFF pequeño.
    
