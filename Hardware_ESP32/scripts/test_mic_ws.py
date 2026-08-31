import websocket
import wave
import sys

# ==========================================
# CONFIGURACIÓN
# ==========================================
ESP32_IP = "10.151.205.172"  # <--- Revisa en tu monitor serie si la IP cambió

audio_data = bytearray()

def on_message(ws, message):
    if isinstance(message, bytes):
        audio_data.extend(message)
        print(f"🎙️ Recibiendo audio... {len(audio_data)} bytes", end='\r')
    else:
        print(f"\n📩 Comando recibido: {message}")
        if message == "CMD_PTT_STOP":
            if len(audio_data) > 0:
                print("\n💾 Botón soltado. Guardando test_mic.wav...")
                with wave.open("test_mic.wav", "wb") as wf:
                    wf.setnchannels(1)       # Mono
                    wf.setsampwidth(2)       # 16-bit
                    wf.setframerate(16000)   # 16 kHz
                    wf.writeframes(audio_data)
                print("✅ ¡Archivo guardado en tu carpeta del proyecto!")
                ws.close()
            else:
                print("\n⚠️ No se recibió audio. Mantén presionado el botón más tiempo.")

def on_error(ws, error):
    print(f"\n❌ Error de WebSocket: {error}")

def on_close(ws, close_status_code, close_msg):
    print(f"\n🔌 Conexión cerrada.")

def on_open(ws):
    print("\n✅ ¡CONECTADO EXITOSAMENTE AL ESP32!")
    print("👉 MANTÉN PRESIONADO el botón de la placa, habla 3 segundos y SUÉLTALO.")

if __name__ == "__main__":
    ws_url = f"ws://{ESP32_IP}:81/"
    print(f"Intentando conectar a {ws_url} ... (Asegúrate de que la placa esté encendida)")
    
    ws = websocket.WebSocketApp(ws_url,
                              on_open=on_open,
                              on_message=on_message,
                              on_error=on_error,
                              on_close=on_close)
    ws.run_forever()
    print("\n[Script finalizado]")
