#ifndef AUDIO_PLAYER_H
#define AUDIO_PLAYER_H

#include <Arduino.h>

bool initAudioPlayer();

// Encola PCM 16-bit mono 16 kHz. No bloquea la pila BLE: si el buffer esta lleno se descarta lo que no cabe.
void playAudioBuffer(const uint8_t* payload, size_t length);

// Tono corto de "pensando". Llamar desde el loop, no desde callbacks BLE.
void playThinkingBeep();

// true mientras Iris habla por el parlante (o acaba de llegar audio para reproducir). Mientras tanto la
// placa no manda avisos ni escucha el microfono: los avisos cortaban la respuesta y el microfono
// oia la voz de Iris (falsos "Oye Iris" y alertas).
bool isIrisSpeaking();

// Bytes de voz escritos al amplificador desde la ultima llamada (diagnostico sin monitor serial).
size_t takePlayedBytes();

// Volumen de la voz y los tonos, 5-100 (50 por defecto). save = guardarlo para el proximo arranque.
void setVolumePercent(int percent, bool save = true);
int getVolumePercent();

// Calla a Iris: descarta el audio que quedaba por reproducir (al apretar el boton para preguntar otra cosa).
void stopPlayback();

// La app avisa cuanto audio viene (CMD_AUDIO_BEGIN:<bytes>). Con eso la placa empieza a sonar solo cuando
// lo que falta llegara antes de que se acabe lo que ya tiene: una vez que empieza, no se corta.
void beginAudioStream(size_t totalBytes);

// Al terminar de recibir una respuesta: true una vez, con los bytes recibidos y los anunciados
// (si recibidos < anunciados se perdieron paquetes BLE). Llamar desde el loop.
bool takeAudioStreamReport(size_t* received, size_t* expected);

// Tono senoidal (ej. pitidos de cercania). Llamar desde el loop, no desde callbacks BLE.
void playTone(float frequencyHz, int durationMs);

#endif
