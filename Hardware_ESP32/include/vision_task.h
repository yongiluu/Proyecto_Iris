#ifndef VISION_TASK_H
#define VISION_TASK_H

// Corre la deteccion de personas (Edge AI) cada VISION_INTERVAL_MS en su propia tarea,
// para que la inferencia (cientos de ms) no corte el audio del loop principal.
bool startVisionTask();

// Pausa la vision mientras se transmite audio (push-to-talk).
void setVisionPaused(bool paused);

#endif
