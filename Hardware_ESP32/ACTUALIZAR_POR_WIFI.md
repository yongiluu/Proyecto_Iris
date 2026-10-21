# Actualizar el firmware por WiFi (caja cerrada)

Cuando la XIAO queda dentro de la caja no se puede usar el USB-C. Para subir un firmware nuevo, la placa crea su propia red WiFi y el PC le manda el código por ahí. Probado en la XIAO el 2026-10-20: la placa recibió el firmware, se reinició sola y pasó los 4 autotests.

## 1. Poner la placa en modo actualización

Cualquiera de estas tres:

- **Mantén apretado el botón de Iris 15 segundos**, hasta oír **tres tonos subiendo**. Un tono grave largo significa que no se pudo, y la placa se reinicia normal.
- Desde la app, con el comando `CMD_OTA_WIFI`. El botón en la app está pendiente.
- Con USB, escribiendo `OTA` en el monitor serial.

La placa deja de detectar cosas y abre la red **`Iris-Actualizar`**. Si en 10 minutos no recibe nada, se reinicia y vuelve a funcionar normal.

## 2. Subir el código desde el PC

**Antes, cierra la app de Iris en el celular.** Con la app conectada por Bluetooth, una subida se cortó a la mitad ("Connection was reset"); al repetirla con la app cerrada funcionó. Si se corta, la placa sigue con el firmware anterior: vuelve a ponerla en modo actualización y repite.

```bash
cd Hardware_ESP32
python tools/subir_por_wifi.py
```

El script hace lo siguiente:

1. Compila con tu WiFi normal.
2. Conecta el PC a `Iris-Actualizar`.
3. Sube el firmware. Reintenta solo si Windows tarda en conectarse.
4. Vuelve a conectar el PC a tu red de siempre.

Durante 1–2 minutos el PC no tiene internet. La placa se reinicia sola con el código nuevo.

Si prefieres hacerlo a mano: conecta el PC a `Iris-Actualizar` y corre `pio run -e seeed_xiao_esp32s3_ota -t upload`. También puedes abrir `http://192.168.4.1/update` en el navegador, con usuario `iris` y la clave de la red, y elegir `.pio/build/seeed_xiao_esp32s3_ota/firmware.bin`.

## Notas

- **Dos placas:** las dos abren una red con el mismo nombre. Actualízalas de a una, con solo una en modo actualización a la vez.
- **Clave:** `IrisOTA2026`, definida en `platformio.ini`, sección `[ota]`. Para cambiarla sin subirla a GitHub, crea `secrets.ini` (ya está en `.gitignore`) con `[ota]` y `password = otra-clave`. La clave nueva solo vale después de subir un firmware que la tenga: súbelo primero con la clave vieja.
- **Seguridad del modo actualización:** la red solo existe mientras la placa está en ese modo, pide clave WPA2 y la subida pide usuario y clave.
- **Cámara:** antes de actualizar se apaga, porque su tarea se caía mientras se escribía la flash. El reinicio la vuelve a encender.
- **Si un firmware nuevo no arranca**, ya no se puede volver a entrar al modo WiFi y hace falta el USB. Por eso, antes de subir por WiFi, conviene que compile sin errores y, si se puede, probarlo en otra placa por USB.
