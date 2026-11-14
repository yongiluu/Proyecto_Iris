#ifndef LIGHT_TASK_H
#define LIGHT_TASK_H

// Tarea del detector de luz: mientras esta encendido mide el brillo de la camara y pita (light_meter.h).
// Apagado, solo duerme. (Antes esta tarea tambien corria los modelos en grises de vision y cercania;
// se retiraron: el modelo a color de escenas, Retina, describe, avisa en vivo y estima la distancia.)
bool startLightTask();

// Pausa el detector mientras la persona habla con Iris (el microfono y el parlante tienen prioridad).
void setLightPaused(bool paused);

#endif
