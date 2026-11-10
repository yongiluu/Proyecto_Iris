#ifndef SCENE_TASK_H
#define SCENE_TASK_H

// Descripcion de la escena EN LA PLACA, sin celular ni internet: frame a color 160x120 -> modelo alumno
// (ML_Training/scene) -> frase en español (scene_describe.cpp). La app la pide con CMD_DESCRIBE y la
// placa responde CMD_SCENE:<frase> (vacia si no pudo). En MODO EN VIVO (CMD_LIVE_ON) mira sola cada ~1,5 s
// y manda CMD_SCENE_LIVE:<frase> solo cuando la escena cambia (scene_live.h). El modelo vive en la particion "modelos" con el
// nombre "escena" (model_store.h); sin el, la tarea no arranca y la placa no anuncia "escena".

// Recibe la frase (UTF-8, puede estar vacia) desde la tarea de escenas.
typedef void (*SceneResultCallback)(const char* sentence);

bool startSceneTask(SceneResultCallback onResult, SceneResultCallback onLive);

// Pide describir lo que hay frente a la camara. No bloquea (se puede llamar desde el hilo BLE).
void requestDescribeScene();

// Prende o apaga el modo en vivo. false si la tarea no arranco (sin modelo).
bool setSceneLive(bool on);
bool sceneLiveActive();

#endif
