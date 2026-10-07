#include "audio_processing.h"
#include <arduinoFFT.h>
#include "tflite_inference.h"

double vReal[FFT_SAMPLES];
double vImag[FFT_SAMPLES];

int16_t audioBuffer[FFT_SAMPLES];
int bufferIndex = 0;

ArduinoFFT<double> FFT = ArduinoFFT<double>(vReal, vImag, FFT_SAMPLES, SAMPLING_FREQUENCY);

void initAudioProcessing() {
    Serial.println("Audio Processing (FFT) Initialized.");
}

void processAudioFrame(const int16_t* audioData, size_t length) {
    int numSamples = length / sizeof(int16_t);
    
    for (int i = 0; i < numSamples; i++) {
        audioBuffer[bufferIndex++] = audioData[i];
        if (bufferIndex >= FFT_SAMPLES) {
            // Buffer lleno, procesar FFT
            for (int j = 0; j < FFT_SAMPLES; j++) {
                vReal[j] = (double)audioBuffer[j];
                vImag[j] = 0.0; 
            }

            FFT.windowing(FFTWindow::Hamming, FFTDirection::Forward);
            FFT.compute(FFTDirection::Forward);
            FFT.complexToMagnitude();

            double dominantFreq = FFT.majorPeak();
            
            double maxMagnitude = 0;
            for(int j = 0; j < FFT_SAMPLES/2; j++) {
                if(vReal[j] > maxMagnitude) maxMagnitude = vReal[j];
            }

            // Sensibilidad ajustada para detectar ruidos
            if (maxMagnitude > 800000) { 
                Serial.printf("[Edge AI] Sonido fuerte detectado -> Frecuencia dominante: %.2f Hz\n", dominantFreq);
                
                // === EJECUTAR MODELO TENSORFLOW LITE ===
                // Le pasamos las 128 frecuencias útiles de la FFT a la red neuronal
                runInference(vReal, FFT_SAMPLES/2);
            }
            
            bufferIndex = 0; // Reiniciar buffer
        }
    }
}