import serial
import wave
import collections
import keyboard # pip install pyserial keyboard
import time
import os

# ==========================================
# CONFIGURACIÓN
# ==========================================
SERIAL_PORT = 'COM3' # <--- CAMBIA ESTO AL PUERTO DE TU ESP32 (Ej: COM3, COM4)
BAUD_RATE = 921600
SAMPLE_RATE = 16000
CHANNELS = 1
SAMPWIDTH = 2
BUFFER_DURATION_SEC = 1.5 # Mantenemos 1.5s en memoria para asegurar que capturemos la palabra completa

buffer_size = int(SAMPLE_RATE * BUFFER_DURATION_SEC * SAMPWIDTH)
# deque nos permite tener un buffer circular (FIFO) de tamaño fijo
rolling_buffer = collections.deque(maxlen=buffer_size)

os.makedirs("dataset", exist_ok=True)

def main():
    print("Conectando al ESP32 por Serial...")
    try:
        ser = serial.Serial(SERIAL_PORT, BAUD_RATE)
    except Exception as e:
        print(f"Error abriendo {SERIAL_PORT}: {e}")
        print("Asegúrate de que el Monitor Serie de PlatformIO esté CERRADO.")
        return

    print("\n" + "="*50)
    print("✅ ¡CONECTADO Y ESCUCHANDO!")
    print("="*50)
    print("INSTRUCCIONES:")
    print("1. Di la palabra 'Hey Iris'.")
    print("2. Inmediatamente presiona la tecla ESPACIO (o Enter).")
    print("3. Se guardará el último segundo de audio.")
    print("4. Presiona 'q' o 'Esc' para salir del script.")
    print("="*50 + "\n")

    counter = 1
    
    # Limpiamos basura inicial del serial
    ser.flushInput()
    
    try:
        while True:
            # Salida del script
            if keyboard.is_pressed('q') or keyboard.is_pressed('esc'):
                print("Saliendo...")
                break

            # Leer datos crudos asegurando que leemos bloques de 2 bytes (16-bits) para no desfasar
            if ser.in_waiting >= 2:
                bytes_to_read = ser.in_waiting - (ser.in_waiting % 2)
                data = ser.read(bytes_to_read)
                rolling_buffer.extend(data)
                
            # Guardar el audio al presionar espacio o enter
            if keyboard.is_pressed('space') or keyboard.is_pressed('enter'):
                target_bytes = SAMPLE_RATE * SAMPWIDTH # Exactamente 1 segundo
                
                if len(rolling_buffer) >= target_bytes:
                    print(f"💾 Guardando muestra {counter:02d}...", end=" ")
                    
                    # Extraemos exactamente el último segundo de la memoria RAM
                    audio_data = list(rolling_buffer)[-target_bytes:]
                    
                    filename = f"dataset/hey_iris_{counter:02d}.wav"
                    with wave.open(filename, 'wb') as wf:
                        wf.setnchannels(CHANNELS)
                        wf.setsampwidth(SAMPWIDTH)
                        wf.setframerate(SAMPLE_RATE)
                        wf.writeframes(bytes(audio_data))
                    
                    print(f"¡Guardado como {filename}!")
                    counter += 1
                    
                    # Vaciamos el buffer y aplicamos un retraso para evitar dobles pulsaciones
                    rolling_buffer.clear()
                    time.sleep(0.5) 
                else:
                    print("⚠️ Aún no hay suficiente audio en el buffer. Espera un segundo.")
                    time.sleep(0.5)

    except KeyboardInterrupt:
        print("\nInterrumpido por el usuario.")
    finally:
        ser.close()
        print("Puerto serial cerrado.")

if __name__ == '__main__':
    main()
