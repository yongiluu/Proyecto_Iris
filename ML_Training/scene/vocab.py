"""Vocabulario de la descripcion de escenas: lo UNICO que el modelo de la placa sabe nombrar.

El modelo grande (profesor) llena un formulario con estos valores y el modelo chico (alumno) aprende
a predecirlo; describe.py lo convierte en una frase en español. El orden de cada lista define los
indices de salida del modelo: si lo cambias (o agregas cosas), hay que reentrenar.

Cada objeto: (id, singular, plural, genero, ¿se describe su color?, clases de Open Images que lo marcan).
"""

OBJECTS = [
    # Personas, animales y vehiculos
    ("persona", "persona", "personas", "f", False, ["Person", "Man", "Woman", "Boy", "Girl"]),
    ("perro", "perro", "perros", "m", True, ["Dog"]),
    ("gato", "gato", "gatos", "m", True, ["Cat"]),
    ("auto", "auto", "autos", "m", True, ["Car", "Taxi", "Limousine"]),
    ("bus", "bus", "buses", "m", True, ["Bus"]),
    ("camion", "camión", "camiones", "m", True, ["Truck", "Van", "Ambulance"]),
    ("moto", "moto", "motos", "f", True, ["Motorcycle"]),
    ("bicicleta", "bicicleta", "bicicletas", "f", True, ["Bicycle"]),
    # Calle
    ("semaforo", "semáforo", "semáforos", "m", False, ["Traffic light"]),
    ("senal", "señal de tránsito", "señales de tránsito", "f", False, ["Traffic sign", "Stop sign"]),
    ("cono", "cono", "conos", "m", False, ["Traffic cone"]),
    ("grifo", "grifo", "grifos", "m", True, ["Fire hydrant"]),
    ("poste", "poste de luz", "postes de luz", "m", False, ["Street light"]),
    ("banca", "banca", "bancas", "f", True, ["Bench"]),
    ("basurero", "basurero", "basureros", "m", True, ["Waste container"]),
    ("arbol", "árbol", "árboles", "m", False, ["Tree"]),
    ("edificio", "edificio", "edificios", "m", True, ["Building", "House", "Skyscraper", "Office building", "Tower"]),
    # Estructura
    ("puerta", "puerta", "puertas", "f", True, ["Door"]),
    ("ventana", "ventana", "ventanas", "f", False, ["Window"]),
    ("escalera", "escalera", "escaleras", "f", True, ["Stairs"]),
    ("columna", "columna", "columnas", "f", True, ["Column"]),
    # Muebles y cosas de la casa
    ("silla", "silla", "sillas", "f", True, ["Chair"]),
    ("mesa", "mesa", "mesas", "f", True, ["Table", "Coffee table", "Kitchen & dining room table", "Desk"]),
    ("sofa", "sofá", "sofás", "m", True, ["Couch", "Sofa bed", "Studio couch"]),
    ("cama", "cama", "camas", "f", True, ["Bed"]),
    ("estante", "estante", "estantes", "m", True, ["Shelf", "Bookcase", "Cabinetry", "Cupboard", "Chest of drawers"]),
    ("cuadro", "cuadro", "cuadros", "m", False, ["Picture frame", "Poster"]),
    ("espejo", "espejo", "espejos", "m", False, ["Mirror"]),
    ("lampara", "lámpara", "lámparas", "f", True, ["Lamp", "Ceiling fan", "Chandelier"]),
    ("planta", "planta", "plantas", "f", False, ["Houseplant", "Flowerpot", "Plant"]),
    ("cortina", "cortina", "cortinas", "f", True, ["Curtain"]),
    ("televisor", "televisor", "televisores", "m", False, ["Television"]),
    ("computador", "computador", "computadores", "m", False, ["Laptop", "Computer monitor", "Computer keyboard"]),
    ("refrigerador", "refrigerador", "refrigeradores", "m", True, ["Refrigerator"]),
    ("cocina", "cocina", "cocinas", "f", False, ["Gas stove", "Oven", "Microwave oven"]),
    ("lavamanos", "lavamanos", "lavamanos", "m", False, ["Sink", "Bathtub"]),
    ("inodoro", "inodoro", "inodoros", "m", False, ["Toilet"]),
    ("reloj", "reloj", "relojes", "m", False, ["Clock", "Wall clock"]),
    # Objetos que se buscan con la mano
    ("botella", "botella", "botellas", "f", True, ["Bottle"]),
    ("taza", "taza", "tazas", "f", True, ["Mug", "Coffee cup"]),
    ("celular", "celular", "celulares", "m", False, ["Mobile phone"]),
    ("mochila", "mochila", "mochilas", "f", True, ["Backpack", "Handbag", "Suitcase"]),
    ("paraguas", "paraguas", "paraguas", "m", True, ["Umbrella"]),
]
OBJECT_IDS = [o[0] for o in OBJECTS]
OBJECT_INFO = {o[0]: {"singular": o[1], "plural": o[2], "gender": o[3], "has_color": o[4], "openimages": o[5]}
               for o in OBJECTS}

# Colores (id, masculino, femenino, plural m, plural f). Español de Chile: "café", "naranjo".
COLORS = [
    ("negro", "negro", "negra", "negros", "negras"),
    ("blanco", "blanco", "blanca", "blancos", "blancas"),
    ("gris", "gris", "gris", "grises", "grises"),
    ("rojo", "rojo", "roja", "rojos", "rojas"),
    ("naranjo", "naranjo", "naranja", "naranjos", "naranjas"),
    ("amarillo", "amarillo", "amarilla", "amarillos", "amarillas"),
    ("verde", "verde", "verde", "verdes", "verdes"),
    ("azul", "azul", "azul", "azules", "azules"),
    ("morado", "morado", "morada", "morados", "moradas"),
    ("rosado", "rosado", "rosada", "rosados", "rosadas"),
    ("cafe", "café", "café", "café", "café"),
]
COLOR_IDS = [c[0] for c in COLORS]
COLOR_FORMS = {c[0]: {"m": c[1], "f": c[2], "mp": c[3], "fp": c[4]} for c in COLORS}

# Donde esta el objeto principal de esa clase (el mas grande o el mas cercano).
POSITIONS = ["izquierda", "centro", "derecha"]
DISTANCES = ["cerca", "medio", "lejos"]   # cerca: a menos de ~1,5 m; medio: ~1,5-4 m; lejos: mas

# Tipo de lugar.
PLACES = ["pasillo", "habitacion", "living", "cocina", "bano", "oficina", "sala_clases", "tienda",
          "escalera", "calle", "vereda", "cruce", "estacionamiento", "parque", "transporte", "otro"]
PLACE_NAMES = {
    "pasillo": "un pasillo", "habitacion": "un dormitorio", "living": "un living", "cocina": "una cocina",
    "bano": "un baño", "oficina": "una oficina", "sala_clases": "una sala de clases", "tienda": "una tienda",
    "escalera": "una escalera", "calle": "la calle", "vereda": "la vereda", "cruce": "un cruce de calle",
    "estacionamiento": "un estacionamiento", "parque": "un parque", "transporte": "un vehículo de transporte",
    "otro": None,
}

# Peligros para una persona ciega que camina hacia adelante. (id, frase de aviso, frase dudosa)
HAZARDS = [
    ("escalera_baja", "escalera hacia abajo adelante", "podría haber una escalera hacia abajo"),
    ("escalera_sube", "escalera hacia arriba adelante", "podría haber una escalera hacia arriba"),
    ("escalon", "un escalón o desnivel adelante", "podría haber un escalón o desnivel"),
    ("obstaculo_suelo", "un obstáculo en el camino", "podría haber un obstáculo en el camino"),
    ("obstaculo_alto", "algo a la altura de la cabeza", "podría haber algo a la altura de la cabeza"),
    ("vehiculo_cerca", "un vehículo cerca", "podría haber un vehículo cerca"),
    ("borde_calle", "el borde de la vereda o la calle", "podría estar el borde de la vereda"),
    ("puerta_vidrio", "una puerta o pared de vidrio", "podría haber vidrio adelante"),
    ("hoyo", "un hoyo o zanja", "podría haber un hoyo"),
]
HAZARD_IDS = [h[0] for h in HAZARDS]
HAZARD_TEXT = {h[0]: {"sure": h[1], "maybe": h[2]} for h in HAZARDS}

# Cuantas personas hay (la ultima cuenta "3 o mas").
PEOPLE_BINS = ["0", "1", "2", "3+"]

# Calidad de la imagen: si es mala, la frase lo dice en vez de describir con falsa seguridad.
QUALITY = ["buena", "oscura", "borrosa", "tapada"]
