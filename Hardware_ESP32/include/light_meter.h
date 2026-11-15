#ifndef LIGHT_METER_H
#define LIGHT_METER_H

#include <stddef.h>
#include <stdint.h>

// Detector de luz (como Seeing AI): mientras esta encendido, la placa pita cada ~0,16 s con un tono
// mas agudo cuanta mas luz ve la camara. Sirve para saber si hay una luz prendida o hacia donde esta
// la ventana. Se enciende con CMD_LIGHT_ON y se apaga con CMD_LIGHT_OFF o solo, a los 3 minutos.
// Mientras esta encendido la camara usa exposicion fija (Retina tambien ve la imagen con esa exposicion).

// Pide encenderlo/apagarlo. No bloquea (se puede llamar desde el hilo BLE): lo aplica la tarea de luz.
void requestLightMeter(bool enabled);

// true mientras el detector esta encendido (la placa no se duerme mientras tanto).
bool lightMeterActive();

// Lo llama la tarea de luz en cada vuelta: aplica lo pedido y el apagado automatico.
// Devuelve true si el detector esta encendido.
bool lightMeterUpdate();

// Lo llama la tarea de luz con cada frame en grises 96x96. Devuelve el nivel de luz 0-100.
int lightMeterStep(const uint8_t* gray, size_t length);

// Tono para un nivel de luz 0-100 (escala exponencial entre LIGHT_METER_MIN_HZ y LIGHT_METER_MAX_HZ).
float lightMeterFrequency(int level);

#endif
