#ifndef OCR_TASK_H
#define OCR_TASK_H

// Lector de texto EN LA PLACA (sin celular ni internet): foto 640x480 en grises -> detector de donde
// hay texto -> lector de cada linea -> texto. Lo pide la app con CMD_READ_TEXT y la placa responde
// CMD_TEXT:<texto> (vacio si no encontro texto). Modelos entrenados en ML_Training/ocr.

// Recibe el texto leido (UTF-8, puede estar vacio) desde la tarea del lector.
typedef void (*OcrResultCallback)(const char* text);

bool startOcrTask(OcrResultCallback onResult);

// Pide leer lo que hay frente a la camara. No bloquea (se puede llamar desde el hilo BLE).
void requestReadText();

#endif
