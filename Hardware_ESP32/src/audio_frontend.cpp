#include "audio_frontend.h"

#include <math.h>
#include <string.h>

namespace {
constexpr int kNumFftBins = kAfFftSize / 2 + 1;
constexpr double kPi = 3.14159265358979323846;

// Tablas de la FFT, calculadas una sola vez.
float twiddleCos[kAfFftSize / 2];
float twiddleSin[kAfFftSize / 2];
uint16_t bitReversed[kAfFftSize];
bool tablesReady = false;

void initFftTables() {
    if (tablesReady) return;
    int bits = 0;
    while ((1 << bits) < kAfFftSize) bits++;

    for (int i = 0; i < kAfFftSize / 2; i++) {
        double angle = -2.0 * kPi * i / kAfFftSize;
        twiddleCos[i] = (float)cos(angle);
        twiddleSin[i] = (float)sin(angle);
    }
    for (int i = 0; i < kAfFftSize; i++) {
        int reversed = 0;
        for (int b = 0; b < bits; b++) {
            if (i & (1 << b)) reversed |= 1 << (bits - 1 - b);
        }
        bitReversed[i] = (uint16_t)reversed;
    }
    tablesReady = true;
}

// FFT compleja radix-2 iterativa, in-place.
void fft(float* re, float* im) {
    for (int i = 0; i < kAfFftSize; i++) {
        int j = bitReversed[i];
        if (j > i) {
            float t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (int size = 2; size <= kAfFftSize; size <<= 1) {
        int half = size / 2;
        int step = kAfFftSize / size;
        for (int start = 0; start < kAfFftSize; start += size) {
            for (int k = 0; k < half; k++) {
                float wr = twiddleCos[k * step];
                float wi = twiddleSin[k * step];
                int a = start + k;
                int b = a + half;
                float tr = re[b] * wr - im[b] * wi;
                float ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
    }
}
}  // namespace

AudioFrontend::AudioFrontend() : filled_(0) {
    initFftTables();
}

void AudioFrontend::reset() {
    filled_ = 0;
}

void AudioFrontend::process(const int16_t* samples, size_t count, FrameCallback callback, void* context) {
    for (size_t i = 0; i < count; i++) {
        window_[filled_++] = samples[i] / 32768.0f;
        if (filled_ < (size_t)kAfWindowSamples) continue;

        computeFrame(mel_);
        if (callback) callback(mel_, context);

        // Desliza la ventana un hop: se conservan las ultimas (ventana - hop) muestras.
        memmove(window_, window_ + kAfHopSamples, (kAfWindowSamples - kAfHopSamples) * sizeof(float));
        filled_ = kAfWindowSamples - kAfHopSamples;
    }
}

void AudioFrontend::computeFrame(float* melOut) {
    for (int i = 0; i < kAfWindowSamples; i++) {
        fftRe_[i] = window_[i] * kAfWindow[i];
        fftIm_[i] = 0.0f;
    }
    for (int i = kAfWindowSamples; i < kAfFftSize; i++) {
        fftRe_[i] = 0.0f;
        fftIm_[i] = 0.0f;
    }

    fft(fftRe_, fftIm_);

    // Potencia en fftRe_ (se reutiliza el buffer).
    for (int k = 0; k < kNumFftBins; k++) {
        fftRe_[k] = fftRe_[k] * fftRe_[k] + fftIm_[k] * fftIm_[k];
    }

    for (int m = 0; m < kAfNumMel; m++) {
        const float* weights = kAfMelWeights + kAfMelOffset[m];
        const float* power = fftRe_ + kAfMelStart[m];
        float sum = 0.0f;
        for (int j = 0; j < kAfMelCount[m]; j++) sum += weights[j] * power[j];
        melOut[m] = logf(sum + kAfLogEps);
    }
}
