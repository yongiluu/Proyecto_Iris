#ifndef BUTTON_GESTURES_H
#define BUTTON_GESTURES_H

// Gestos del unico boton de Iris. C++ puro (sin Arduino): ML_Training/tests/test_button_gestures.py
// lo compila en el PC y prueba cada gesto.
//
//   mantener, hablar y soltar            -> TalkStart ... TalkStop   (pregunta; responde lo local primero)
//   un toque corto                       -> Tap1                     (describir con el modelo de la placa)
//   toque + mantener, hablar y soltar    -> CloudTalkStart ... TalkStop  (la pregunta va a la nube)
//   dos toques cortos                    -> Tap2                     (descripcion detallada de la nube)
//   tres toques                          -> Tap3                     (leer el texto de adelante)
//
// "Mantener" es tener el boton apretado kHoldMs o mas. Un toque corto se confirma cuando pasan
// kTapGapMs sin otro toque (por eso Tap1 y Tap2 llegan con ese pequeno retraso). El tercer toque se
// avisa apenas se aprieta: no hay gesto de cuatro.

#include <stdint.h>

enum class ButtonEvent : uint8_t { None, TalkStart, CloudTalkStart, TalkStop, Tap1, Tap2, Tap3 };

class ButtonGestures {
public:
    static constexpr uint32_t kHoldMs = 600;   // antes 350: toques normales (sobre todo cuidadosos) se tomaban como "mantener"
    static constexpr uint32_t kTapGapMs = 450;

    // Llamar seguido (cada ~5-10 ms) con el estado ya sin rebotes. Devuelve a lo mas un evento por llamada.
    ButtonEvent update(bool pressed, uint32_t nowMs);

    // La placa desperto de dormir porque se apreto el boton: ese apreton cuenta como el primero aunque
    // ya se haya soltado mientras arrancaba. [pressedNow]: si el boton sigue apretado.
    void beginFromWake(bool pressedNow, uint32_t nowMs);

    // true mientras hay un gesto a medias (boton apretado o toques esperando confirmacion).
    bool busy() const { return pressed_ || taps_ > 0; }

private:
    bool pressed_ = false;
    bool holdFired_ = false;   // este apreton ya se aviso como "mantener"
    bool consumed_ = false;    // este apreton ya produjo su evento (tercer toque)
    uint8_t taps_ = 0;         // toques cortos ya soltados, esperando confirmacion
    uint32_t pressStartMs_ = 0;
    uint32_t lastReleaseMs_ = 0;
};

#endif
