# Energía de la placa Iris (XIAO ESP32-S3 Sense)

Objetivo: pila LiPo de 500–800 mAh (máximo 1000 mAh) que dure "harto", usando los modelos locales.
Todo lo de aquí son **estimaciones** hechas con datasheets y mediciones publicadas; lo que falta medir
con la placa real está al final.

## 1. Cuánto gasta cada cosa

| Parte | Consumo | De dónde sale |
|---|---|---|
| ESP32-S3 a 240 MHz, radio apagada, CPU ociosa / un núcleo trabajando / dos núcleos | 48 / 66–88 / 81–108 mA | Datasheet ESP32-S3 v1.6, tabla 4-7 (relojes de periféricos encendidos) |
| ESP32-S3 a 80 MHz, ociosa / trabajando | 36 / 43–56 mA | Ídem |
| XIAO S3 sin nada, CPU ociosa a 160 MHz | 28 mA (medido a 3,8 V) | Qoitech |
| Light sleep de la XIAO S3 | 0,7–2,9 mA (5,5 mA con la cámara puesta) | Qoitech; ficha de Seeed |
| Deep sleep de la XIAO S3 | 13–14 µA sola; **~3 mA con la cámara puesta** | Qoitech; ficha de Seeed |
| Cámara OV2640 capturando | ~125–140 mW ≈ 35–40 mA | Datasheet OV2640 |
| Cámara OV2640 en reposo | 0,6–1 mA según datasheet; en módulos reales se han medido hasta decenas de mA | Datasheet; foros (Arducam, Nordic) |
| Amplificador MAX98357A sin sonar | 2,4 mA (se apaga solo si se detiene el reloj I2S) | Datasheet |
| Parlante hablando | ~50–150 mA mientras suena (estimado, depende del volumen) | Estimado |
| Micrófono PDM | ~1 mA con reloj | Estimado (típico de la familia) |
| Bluetooth conectado con intervalo 7,5–15 ms (como hoy) | ~+10–20 mA de promedio (estimado) | Sin dato publicado para el S3 |

Dos hechos del firmware actual que mandan en el diseño:

- **El núcleo de Arduino que usamos no trae ahorro automático** (`CONFIG_PM_ENABLE` y el "modem sleep"
  de Bluetooth están apagados en su `sdkconfig`). No hay light sleep automático entre tareas: o la
  placa está despierta, o se duerme entera y el Bluetooth se corta.
- **La XIAO Sense no tiene el pin PWDN de la cámara conectado** (`PWDN_GPIO_NUM -1`): no se puede
  cortar la cámara por un pin. Se puede apagar su reloj (`esp_camera_deinit`) y pedirle reposo por
  registro; cuánto baja de verdad hay que medirlo (Seeed publica 3 mA en deep sleep con cámara).

Tiempo de despertar desde deep sleep (estimado): arranque ~0,3–0,5 s, cámara ~0,4 s + 2–3 cuadros para
la exposición (~0,3 s), modelo Retina ~0,1–0,2 s (se lee directo de la flash; revisar su CRC es lo
que más tarda), inferencia ~0,5–1 s. **Total ~1,5–2,5 s** hasta tener la frase. El Bluetooth tarda más:
la app hoy busca la placa cada 5 s, así que reconectar toma 1–6 s (se puede bajar a ~1–2 s).

## 2. Autonomía estimada

Con el 85 % de la pila aprovechable (el regulador deja de funcionar antes de vaciarla).

| Escenario | Consumo medio | 500 mAh | 800 mAh | 1000 mAh |
|---|---|---|---|---|
| (a) Siempre encendida, como hoy (240 MHz, cámara, Bluetooth rápido, wake word y sonidos) | ~130 mA | ~3 h | ~5 h | ~6,5 h |
| (b) Dormida, despierta con el botón (60 consultas al día) | 1–3 mA dormida + ~15 mAh/día de uso | 5–10 días | 8–17 días | 9–21 días |
| (c) "Oye Iris" siempre escuchando, optimizado (80 MHz, cámara apagada, sin sonidos, Bluetooth lento) | ~45–50 mA | ~9 h | ~14 h | ~18 h |
| (d) Modo en vivo continuo | ~110–130 mA | ~3,5 h | ~5,5 h | ~7 h |

Lo que más pesa en (b) no son las consultas (cada una gasta ~0,25 mAh: 6–8 s despierta) sino el
piso dormida: con 3 mA la pila de 500 mAh se va en 6 días aunque nadie la use; si la cámara de
verdad baja a décimas de mA, serían semanas.

## 3. Lo que quedó decidido e implementado

Decisiones de Diego (2026-11-15): la placa duerme y **solo la despierta el botón** (sin "Oye Iris"
dormida); el modo en vivo se apaga solo a los 5 minutos; y a futuro la placa debe **hablar sola, sin
celular** (ver el punto 5).

### Estados

- **Dormida** (deep sleep): todo apagado. La despierta el botón (GPIO4 por `ext0`; el botón BOOT de
  la XIAO también, por `ext1`).
- **Despierta**: cámara, modelos y Bluetooth encendidos. Atiende el gesto que la despertó y, si pasan
  `POWER_IDLE_SLEEP_MS` (45 s) sin que nadie la use, se duerme sola. Mientras hay algo en curso
  (pregunta, respuesta sonando, detector de luz, modo en vivo, la app mandando comandos) no se duerme.
- **En vivo**: como antes, pero se apaga solo a los `LIVE_MAX_MS` (5 min) y lo avisa.
- Con el cable USB conectado a un PC no se duerme (para ver el monitor serial y grabarla).
- "Oye Iris" y los eventos de sonido siguen funcionando solo mientras está despierta.

### Gestos del botón (`button_gestures.h`)

| Gesto | Qué hace |
|---|---|
| Mantener, hablar y soltar | Pregunta por voz. Con el celular conectado va a la app (que prueba primero lo local); sin celular nadie puede entender la pregunta, así que al soltar la placa describe lo que ve. |
| Un toque | La placa describe lo que ve con Retina, sin internet. |
| Toque + mantener, hablar y soltar | La pregunta va directo a la nube (`CMD_CLOUD_NEXT` antes de `CMD_PTT_START`). |
| Dos toques | Descripción detallada de la nube (`CMD_CLOUD_DESCRIBE`); sin celular, la local. |
| Tres toques | Leer el texto de adelante: dice "Déjame leerlo" y después lo que leyó. |
| Mantener 15 s | Actualización por WiFi (igual que antes). |

Un toque corto se confirma 0,4 s después de soltar (hay que esperar por si viene otro). El toque que
despierta a la placa cuenta como el primero del gesto: una tarea mira el botón desde el primer
instante del arranque.

### Comandos nuevos hacia la app

- `CMD_SAY:<frase>`: la placa dice algo por su cuenta (respuesta a un toque, o un aviso). Si la app
  todavía no reconectó, la frase espera hasta 20 s.
- `CMD_CLOUD_NEXT`, `CMD_CLOUD_DESCRIBE`: ver la tabla de gestos.
- `CMD_SLEEP`: la placa se va a dormir (la app no lo anuncia como desconexión).
- `CMD_BATTERY:<mV>:<%>`: solo con el divisor de voltaje puesto.

### Batería

La XIAO S3 carga la LiPo por sus pads BAT+/BAT-, pero **no lleva el voltaje de la pila a ningún
pin**. Hace falta un divisor: BAT+ — 220 kΩ — D4 (GPIO5, ADC1) — 220 kΩ — GND, con 100 nF de D4 a
GND. Gasta 8 µA. El código ya está (`BATTERY_SENSE_ENABLED` en `config.h`, hoy en 0): con el divisor
soldado se pone en 1 y la placa avisa "queda poca batería" bajo 3,55 V y se duerme sola bajo 3,35 V.

## 4. Falta medir con la placa real

- Consumo en deep sleep con la cámara puesta (¿3 mA o menos pidiéndole reposo por registro?).
- Consumo activo real a 240 y a 80 MHz, con y sin cámara.
- Si el wake word alcanza a correr a 80 MHz.
- Tiempo real desde el toque hasta la frase, y hasta que la app reconecta.
- Consumo del parlante al volumen que se usa.

## 5. Pendiente: que la placa hable sola (sin celular)

Hoy la frase viaja por Bluetooth y la dice el celular. Para no depender de él, la placa necesita su
propia voz. Como Retina arma sus frases con un vocabulario cerrado, alcanza con trozos pregrabados:

- Grabar una vez (con la misma voz de Iris) cada pieza del vocabulario de `scene_vocab`: objetos con
  su artículo, colores, "Adelante", "A tu izquierda", "muy cerca, hay", lugares, avisos de calidad y
  las frases fijas ("Déjame leerlo", "Queda poca batería"...). Son ~200 trozos de ~0,7 s.
- Guardarlos en la partición de modelos como un paquete más ("voz"), en ADPCM de 16 kHz: ~0,6–1 MB.
- `scene_describe` ya arma la frase por partes: en vez de texto, entregar la lista de trozos y
  reproducirlos seguidos por el parlante.
- El lector de texto no tiene vocabulario cerrado: sin celular solo podría deletrear o decir "hay
  texto". Leer en voz alta de verdad necesita un sintetizador en la placa (trabajo mayor).

## Fuentes

- Datasheet ESP32-S3 v1.6 (tablas 4-7 y 4-8): https://files.seeedstudio.com/wiki/SeeedStudio-XIAO-ESP32S3/res/esp32-s3_datasheet.pdf
- Qoitech, mediciones de la XIAO ESP32-S3: https://www.qoitech.com/?p=19961
- Seeed, ficha de la XIAO ESP32S3 Sense: https://wiki.seeedstudio.com/xiao_esp32s3_getting_started
- Seeed, modos de sueño: https://wiki.seeedstudio.com/XIAO_ESP32S3_Consumption/
- Datasheet OV2640: https://cdn.robotshop.com/media/W/Wav/RB-Wav-73/pdf/OV2640-datasheet.pdf
- MAX98357A: https://www.analog.com/en/products/MAX98357A.html
- Deep sleep alto con cámara (foro Arduino): https://forum.arduino.cc/t/high-power-consumption-during-deep-sleep-on-seeed-studio-xiao-esp32s3/1325985
