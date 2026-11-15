#ifndef POWER_MANAGER_H
#define POWER_MANAGER_H

// Energia de la placa (ver ENERGIA.md). La placa pasa casi todo el tiempo DORMIDA (deep sleep) y la
// despierta el boton. Despierta atiende lo que se le pide y, si pasa POWER_IDLE_SLEEP_MS sin que nadie
// la use, se vuelve a dormir sola.
//
// El nucleo de Arduino que usamos no trae ahorro automatico (light sleep entre tareas), asi que no
// hay punto medio: despierta gasta ~100 mA y dormida unos pocos mA o menos.

#include <stdint.h>

// Llamar al principio de setup(). Lee por que arranco la placa.
void powerBegin();

// true si la placa estaba dormida y la desperto el boton.
bool powerWokeByButton();

// Alguien uso la placa (boton, comando de la app, una tarea trabajando): reinicia la cuenta para
// dormirse. Se puede llamar desde cualquier tarea.
void powerActivity();

// true si ya paso POWER_IDLE_SLEEP_MS sin actividad y se puede dormir (nunca con el cable USB
// conectado a un PC, para no cortar el monitor serial ni las subidas).
bool powerShouldSleep();

// Duerme la placa hasta que se apriete el boton. No vuelve: al despertar la placa arranca de cero.
// Antes de llamarla hay que apagar la camara y el Bluetooth.
[[noreturn]] void powerDeepSleep();

// ─── Bateria (necesita el divisor de voltaje de ENERGIA.md en BATTERY_ADC_PIN) ───

enum class BatteryLevel : uint8_t { Unknown, Ok, Low, Critical };

// Voltaje de la pila en milivoltios (promedio de varias lecturas), o 0 si BATTERY_SENSE_ENABLED es 0.
int batteryMillivolts();

// 0-100 segun la curva de descarga de una LiPo.
int batteryPercent(int millivolts);

BatteryLevel batteryLevel(int millivolts);

#endif
