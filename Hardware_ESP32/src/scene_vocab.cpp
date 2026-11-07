// GENERADO por ML_Training/scene/firmware_codegen.py desde vocab.py. No editar a mano.
#include "scene_vocab.h"

const char* const kSceneObjectSingular[kSceneNumObjects] = {
    "persona", "perro", "gato", "auto",
    "bus", "camión", "moto", "bicicleta",
    "semáforo", "señal de tránsito", "cono", "grifo",
    "poste de luz", "banca", "basurero", "árbol",
    "edificio", "puerta", "ventana", "escalera",
    "columna", "silla", "mesa", "sofá",
    "cama", "estante", "cuadro", "espejo",
    "lámpara", "planta", "cortina", "televisor",
    "computador", "refrigerador", "cocina", "lavamanos",
    "inodoro", "reloj", "botella", "taza",
    "celular", "mochila", "paraguas"
};
const bool kSceneObjectFeminine[kSceneNumObjects] = {
    true, false, false, false, false, false, true, true,
    false, true, false, false, false, true, false, false,
    false, true, true, true, true, true, true, false,
    true, false, false, false, true, true, true, false,
    false, false, true, false, false, false, true, true,
    false, true, false
};
const bool kSceneObjectHasColor[kSceneNumObjects] = {
    false, true, true, true, true, true, true, true,
    false, false, false, true, false, true, true, false,
    true, true, false, true, true, true, true, true,
    true, true, false, false, true, false, true, false,
    false, true, false, false, false, false, true, true,
    false, true, true
};
const char* const kSceneColorMasculine[kSceneNumColors] = {
    "negro", "blanco", "gris", "rojo",
    "naranjo", "amarillo", "verde", "azul",
    "morado", "rosado", "café"
};
const char* const kSceneColorFeminine[kSceneNumColors] = {
    "negra", "blanca", "gris", "roja",
    "naranja", "amarilla", "verde", "azul",
    "morada", "rosada", "café"
};
const char* const kScenePlaceName[kSceneNumPlaces] = {
    "un pasillo", "un dormitorio", "un living", "una cocina",
    "un baño", "una oficina", "una sala de clases", "una tienda",
    "una escalera", "la calle", "la vereda", "un cruce de calle",
    "un estacionamiento", "un parque", "un vehículo de transporte", nullptr
};
const char* const kSceneHazardSureText[kSceneNumHazards] = {
    "escalera hacia abajo adelante", "escalera hacia arriba adelante",
    "un escalón o desnivel adelante", "un obstáculo en el camino",
    "algo a la altura de la cabeza", "un vehículo cerca",
    "el borde de la vereda o la calle", "una puerta o pared de vidrio",
    "un hoyo o zanja"
};
const char* const kSceneHazardMaybeText[kSceneNumHazards] = {
    "podría haber una escalera hacia abajo", "podría haber una escalera hacia arriba",
    "podría haber un escalón o desnivel", "podría haber un obstáculo en el camino",
    "podría haber algo a la altura de la cabeza", "podría haber un vehículo cerca",
    "podría estar el borde de la vereda", "podría haber vidrio adelante",
    "podría haber un hoyo"
};
