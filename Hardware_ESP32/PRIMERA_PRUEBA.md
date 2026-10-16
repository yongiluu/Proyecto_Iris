# Primera prueba con el prototipo 2 (XIAO ESP32S3 Sense)

Lista corta para el día que llega la placa. Si algo sale distinto de lo esperado, copia el texto del monitor serial y pásaselo a Claude.

## 1. Subir el firmware (VS Code + PlatformIO)

1. Conecta la XIAO por USB-C.
2. En la barra de PlatformIO, elige el entorno **`seeed_xiao_esp32s3`** (no el `esp32-s3-devkitc-1`, que es el de por defecto).
3. **Upload** y después **Monitor** (115200).

   Desde la terminal es lo mismo: `pio run -e seeed_xiao_esp32s3 -t upload -t monitor`

   Si no la detecta para subir, mantén apretado **BOOT**, aprieta y suelta **RESET**, suelta **BOOT** y vuelve a subir.

## 2. Qué mirar en el monitor serial

Al arrancar deberían aparecer estas líneas (los números cambian):

```text
[Vision IA] Autotest OK: 150 ms por imagen (ESP-NN optimizado), clase puerta, max dif 0
[Vision IA] Listo: 5 clases, arena 16xxxx/174080 bytes
[Audio IA] Autotest OK: 8.0 ms por inferencia, clase sirena, max dif 0
[Audio IA] Listo: 5 clases, arena 4xxxx/70656 bytes
Iris ESP32 listo. Esperando conexion BLE...
```

| Si ves | Qué significa / qué hacer |
|---|---|
| `Autotest OK` | Los modelos dan lo mismo que en el PC. Anota los **ms por imagen**: es el dato que faltaba. |
| `Autotest FALLO` | Sube `seeed_xiao_esp32s3_tflm_ref` (sin ESP-NN) y mira si ahí da OK. Pasa ambos textos a Claude. |
| `AllocateTensors fallo` o `Sin memoria` | Falta RAM para la arena: pásale el texto a Claude. Se puede volver a la visión v3, que es más chica. |
| Visión > 500 ms por imagen | Funciona, pero lento. Se puede subir `VISION_INTERVAL_MS` o volver a v3. |
| `Error al inicializar la camara` | Revisa que la placa de la cámara (Sense) esté bien encajada. |
| La imagen sale al revés (en las misiones) | En `src/camera_driver.cpp` hay dos líneas comentadas para darla vuelta. |

Para ver los puntajes en vivo, pon `VISION_EVENTS_DEBUG 1` y/o `AUDIO_EVENTS_DEBUG 1` en `include/config.h` y vuelve a subir.

## 3. Probar con la app

1. Instala el APK (desde `App_Flutter/`, con el celular conectado por USB y la depuración activada): `flutter install`.
2. En la app, elige el modo **Placa ESP32**. Debe decir "Bluetooth conectado".
3. Apunta la cámara a una puerta o escalera a 1–2 m: la app debería decir "Adelante hay una puerta". La placa no repite la misma clase antes de 8 s, y la app tampoco antes de 20 s.
4. Pregúntale algo a Iris ("¿qué hay a mi alrededor?"): la respuesta usa el contexto de lo que oyó y vio la placa.

## 4. Datos reales (lo que más mejora los modelos)

En la app: 📋 **Misiones de datos** → fuente **Placa**. Prioriza "nada" en lugares distintos y las puertas o escaleras de tu entorno. Después: **Exportar** → `python ML_Training/import_phone_data.py <zip>` → reentrenar (ver `ML_Training/README.md`).
