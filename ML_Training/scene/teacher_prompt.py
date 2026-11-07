"""Instrucciones para el modelo profesor (un modelo de vision-lenguaje grande, ej. Qwen2.5-VL en Lambda)."""
from vocab import (COLOR_IDS, DISTANCES, HAZARD_IDS, HAZARD_TEXT, OBJECT_IDS, OBJECT_INFO, PEOPLE_BINS,
                   PLACES, POSITIONS, QUALITY)

PROMPT_VERSION = "v1"


def build_prompt() -> str:
    objects = ", ".join(OBJECT_IDS)
    colored = ", ".join(o for o in OBJECT_IDS if OBJECT_INFO[o]["has_color"])
    hazards = "\n".join(f"  - {h}: {HAZARD_TEXT[h]['sure']}" for h in HAZARD_IDS)
    return f"""Eres los ojos de una persona ciega. La foto viene de una cámara pequeña que la persona lleva en el pecho mientras camina, mirando hacia adelante. Llena el formulario JSON describiendo SOLO lo que se ve con claridad. No inventes: si dudas de que algo esté, no lo pongas.

Campos:
- calidad: {", ".join(QUALITY)}. "oscura" si casi no se distingue nada por falta de luz; "borrosa" si está muy movida o desenfocada; "tapada" si la lente está cubierta (dedo, ropa).
- interior: true si es un espacio cerrado (casa, oficina, tienda, bus), false si es al aire libre.
- lugar: uno de {", ".join(PLACES)}. Usa "otro" si no calza ninguno.
- personas: cuántas personas se ven: {", ".join(PEOPLE_BINS)}.
- objetos: los objetos relevantes que se ven, SOLO de esta lista: {objects}.
  Para cada uno, describe el ejemplar más cercano o más grande (uno por tipo de objeto):
  - posicion: {", ".join(POSITIONS)} (tercio izquierdo, central o derecho de la foto).
  - distancia: {", ".join(DISTANCES)} (cerca = a menos de 1,5 m; medio = entre 1,5 y 4 m; lejos = más de 4 m).
  - color: el color principal, uno de {", ".join(COLOR_IDS)}; usa "cafe" para café/marrón/madera. Solo para estos objetos: {colored}. Para los demás, o si no se distingue, null.
  Ordena la lista desde lo más importante para quien camina (lo que está adelante y cerca primero). Máximo 12.
- peligros: riesgos reales para alguien que camina hacia adelante sin ver, de esta lista (lista vacía si no hay ninguno):
{hazards}
  Marca un peligro solo si está en el camino o muy cerca, no si está lejos o a un costado sin riesgo.
- detalle: una frase corta en español con el detalle más útil que el formulario no captura (ej. "un cuadro colgado en la puerta", "la puerta está abierta", "hay un letrero que dice SALIDA"). Cadena vacía si no hay nada que agregar.

Responde únicamente con el JSON."""
