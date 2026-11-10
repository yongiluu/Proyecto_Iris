# Todo a color en la placa (plan)

La cámara de la XIAO (OV2640, o OV3660 en lotes nuevos: la placa lo dice al arrancar) ve a color, y lo
innovador es que la placa entienda lo que ve sin internet. Hoy hay modelos que todavía trabajan en grises
por razones históricas. Este es el estado y el camino.

## Qué usa cada modelo hoy

| Modelo | Entrada | Por qué | Plan |
|---|---|---|---|
| Descripción de escenas (`scene_task`) | **color** 160x120 | — | Es el modelo principal: describe, avisa en vivo y, con el profesor, peligros |
| Avisos de visión (`vision_scenes`) | grises 96x96 | Fue el primero (prototipo 1), entrenado con fotos de internet en grises | **Se jubila**: la cabeza de presencia del modelo de escenas ya ve persona, auto, escalera, puerta, y la de peligros los avisos |
| Cercanía (`proximity`) | grises 96x96 | Igual que el anterior | **Se jubila**: la cabeza de distancia (cerca / medio / lejos) del modelo de escenas lo cubre |
| Lector de texto (OCR) | grises 640x480 | El texto se lee por contraste: el color no ayuda y a 640x480 una foto a color ocupa el doble de memoria (600 KB vs 300 KB) | Se queda en grises a propósito; la foto se saca a color y se convierte en la placa si hace falta |

## Pasos

1. **Profesor en Lambda** (`scene/lambda/run_all.sh`): etiqueta las fotos con peligros (escalón, poste,
   hoyo, vehículo cerca...). El alumno se re-entrena con esas etiquetas y la bandera "peligros entrenados".
2. **Fotos reales de la placa a color** (`vision/capture_photos.py`, 160x120 RGB565): el alumno aprendió con
   fotos de internet; con fotos de la cámara real mejora mucho (ya pasó con visión: ver
   `iris-datos-reales-hallazgos`).
3. Con el alumno nuevo midiendo igual o mejor que `vision_scenes` y `proximity` en las mismas fotos,
   **apagar esos dos modelos** y que los avisos salgan del modo en vivo. La cámara queda siempre a color y
   el programa libera ~1,3 MB (que pasan a la partición de modelos).
4. Más resolución: con 160x120, MobileNetV2 0.35 debería correr en ~1 s en el ESP32-S3 (estimado; falta
   medirlo en la placa). A 320x240 serían unas 4 veces más cálculos (demasiado lento para el modo en vivo). Se puede usar más resolución solo para "más detalle".
