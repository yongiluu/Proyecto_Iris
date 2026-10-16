# TensorFlow Lite Micro de Iris (con ESP-NN)

Copia local de `tanakamasayuki/TensorFlowLite_ESP32` 1.0.0, la librería que usaba el firmware, más los kernels optimizados **ESP-NN** de Espressif para el ESP32-S3 (instrucciones vectoriales). La versión de PlatformIO trae solo el README de ESP-NN: le quitaron los kernels.

## De dónde sale cada parte

- **TFLM (`src/tensorflow`, `src/third_party`)**: igual a la librería 1.0.0. Corresponde al commit `92ded90` (2022-06-27) de [espressif/tflite-micro-esp-examples](https://github.com/espressif/tflite-micro-esp-examples) (`components/tflite-lib`): los kernels de referencia son idénticos.
- **`src/tensorflow/lite/micro/kernels/esp_nn/*.cpp`**: los kernels ESP-NN de ese mismo commit (`add`, `conv`, `depthwise_conv`, `fully_connected`, `mul`, `pooling`, `softmax`). Se quitaron los de referencia con el mismo nombre, como hace el `CMakeLists.txt` de Espressif.
- **`src/esp_nn/` y `src/esp_nn*.h`**: [espressif/esp-nn](https://github.com/espressif/esp-nn) en `b219491` (el submódulo de ese commit). Incluye el C genérico y el ensamblador del ESP32-S3. Licencia Apache 2.0 (`src/esp_nn/LICENSE`).

## Cambios propios (marcados con `IRIS:`)

- `kernels/esp_nn/softmax.cpp`: `buffer_idx` quedaba sin inicializar cuando ESP-NN no pide buffer temporal, y se leía `dims->data[2]` en tensores `[1, N]`. Con la versión C de ESP-NN hacía que el softmax leyera memoria basura (se detectó con el test del PC).

## Cómo se activa

En `platformio.ini`, `${iris.espnn_flags}` (`-DESP_NN=1 -DCONFIG_NN_OPTIMIZED=1`) en los entornos de las placas:
- Sin `CONFIG_NN_OPTIMIZED`, ESP-NN usa su versión en C.
- Sin `ESP_NN`, los kernels vuelven al código de referencia de TFLM.

El entorno `seeed_xiao_esp32s3_tflm_ref` compila sin ESP-NN, para comparar.

## Cómo se verifica

- **En el PC:** `python ML_Training/tests/test_tflm_kernels.py` compila esta librería con la versión C de ESP-NN, corre los modelos de visión y audio sobre 1.000 ejemplos de test y compara con TensorFlow. Resultado al 2026-10-16: misma clase en el 100 % y salidas idénticas en más del 99 %. Con `--reference` usa los kernels originales, y da exactamente lo mismo.
- **En la placa:** al arrancar, los dos modelos corren un ejemplo de prueba generado por `export_model.py` y lo comparan con la salida del PC. Así se verifica también el ensamblador, que solo corre en el chip. En el monitor serial aparece algo como `[Vision IA] Autotest OK: N ms por imagen (ESP-NN optimizado) ...`. Si dice `FALLO`, sube `seeed_xiao_esp32s3_tflm_ref` y compara.
