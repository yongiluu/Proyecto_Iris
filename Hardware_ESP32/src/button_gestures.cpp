#include "button_gestures.h"

void ButtonGestures::beginFromWake(bool pressedNow, uint32_t nowMs) {
    holdFired_ = false;
    consumed_ = false;
    if (pressedNow) {
        // Sigue apretado: el tiempo de "mantener" se cuenta desde ahora (el arranque no cuenta).
        pressed_ = true;
        taps_ = 0;
        pressStartMs_ = nowMs;
    } else {
        // Ya se solto mientras la placa arrancaba: fue un toque corto.
        pressed_ = false;
        taps_ = 1;
        lastReleaseMs_ = nowMs;
    }
}

ButtonEvent ButtonGestures::update(bool pressed, uint32_t nowMs) {
    if (pressed && !pressed_) {  // se acaba de apretar
        pressed_ = true;
        holdFired_ = false;
        consumed_ = false;
        pressStartMs_ = nowMs;
        if (taps_ >= 2) {  // tercer toque: no hay que esperar mas
            taps_ = 0;
            consumed_ = true;
            return ButtonEvent::Tap3;
        }
        return ButtonEvent::None;
    }

    if (pressed && pressed_) {  // sigue apretado
        if (!holdFired_ && !consumed_ && nowMs - pressStartMs_ >= kHoldMs) {
            holdFired_ = true;
            const bool cloud = taps_ == 1;  // toque + mantener
            taps_ = 0;
            return cloud ? ButtonEvent::CloudTalkStart : ButtonEvent::TalkStart;
        }
        return ButtonEvent::None;
    }

    if (!pressed && pressed_) {  // se acaba de soltar
        pressed_ = false;
        if (holdFired_) return ButtonEvent::TalkStop;
        if (!consumed_) {
            taps_++;
            lastReleaseMs_ = nowMs;
        }
        return ButtonEvent::None;
    }

    // Suelto: los toques cortos se confirman cuando no llega otro.
    if (taps_ > 0 && nowMs - lastReleaseMs_ >= kTapGapMs) {
        const ButtonEvent event = taps_ == 1 ? ButtonEvent::Tap1 : ButtonEvent::Tap2;
        taps_ = 0;
        return event;
    }
    return ButtonEvent::None;
}
