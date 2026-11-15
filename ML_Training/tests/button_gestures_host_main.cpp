// Corre los gestos del boton con el MISMO codigo de la placa (button_gestures.cpp), para
// tests/test_button_gestures.py.
//   Entrada (stdin), una linea por instante: "<ms> <0|1>"  (1 = boton apretado)
//   Primera linea opcional: "wake <0|1> <ms>"  (la placa desperto con el boton; 1 = sigue apretado)
//   Salida: una linea por evento: "<ms> <evento>"
#include <stdio.h>
#include <string.h>

#include "button_gestures.h"

static const char* name(ButtonEvent event) {
    switch (event) {
        case ButtonEvent::TalkStart: return "TalkStart";
        case ButtonEvent::CloudTalkStart: return "CloudTalkStart";
        case ButtonEvent::TalkStop: return "TalkStop";
        case ButtonEvent::Tap1: return "Tap1";
        case ButtonEvent::Tap2: return "Tap2";
        case ButtonEvent::Tap3: return "Tap3";
        case ButtonEvent::None: break;
    }
    return "None";
}

int main() {
    ButtonGestures gestures;
    char line[64];
    while (fgets(line, sizeof(line), stdin)) {
        unsigned ms = 0;
        int pressed = 0;
        if (strncmp(line, "wake", 4) == 0) {
            if (sscanf(line + 4, "%d %u", &pressed, &ms) == 2) gestures.beginFromWake(pressed != 0, ms);
            continue;
        }
        if (sscanf(line, "%u %d", &ms, &pressed) != 2) continue;
        const ButtonEvent event = gestures.update(pressed != 0, ms);
        if (event != ButtonEvent::None) printf("%u %s\n", ms, name(event));
    }
    printf("busy %d\n", gestures.busy() ? 1 : 0);
    return 0;
}
