# Backend de Iris (Supabase)

Hace que Iris sea una app real:

- **Login con Google.** Un toque, sin escribir contraseñas.
- **Base de datos** con el perfil y las preferencias de cada persona.
- **Memoria diaria del agente.**
- **Acompañantes** (familiar o profesional) vinculados con un código.
- **Alertas y ubicación compartidas** (solo si la persona lo permite).
- **Registro de placas.**
- **Datos para entrenar** (solo con consentimiento).

Y lo más importante para la seguridad: **las claves de Azure, Hugging Face y del clima salen de la app**. Hoy viajan dentro del APK y cualquiera puede extraerlas. Con esto viven solo en el servidor.

## Estructura

```text
Backend_Supabase/
├── supabase/
│   ├── config.toml                      # configuracion (login con Google, etc.)
│   ├── migrations/                      # base de datos + reglas de seguridad (RLS)
│   └── functions/
│       ├── agent/      # el agente: memoria diaria + herramientas + Azure
│       ├── voice/      # texto -> voz PCM 16 kHz para la placa (Azure TTS)
│       ├── transcribe/ # audio WAV -> texto (Whisper)
│       └── _shared/    # cliente de Azure, prompts, memoria, herramientas
└── tests/test_schema.mjs # prueba la base de datos y sus reglas sin Docker (PGlite)
```

## La memoria diaria (cómo no gastar de más)

Iris recuerda lo que la persona le cuenta durante el día ("¿qué desayuné hoy?") sin releer todo en cada pregunta:

1. **El día es una conversación.** Empieza a las 4:00 hora local: lo de madrugada cuenta como el día anterior.
2. **En cada pregunta el agente ve:**
   - un **resumen acumulado del día** (líneas cortas con la hora), que un modelo barato actualiza cada 8 mensajes,
   - los **últimos 10 mensajes** textuales.
3. **Si no está ahí, el agente usa herramientas:**
   - `buscar_en_memoria`: búsqueda de texto en español en la base de datos ("desayuno" encuentra "desayuné").
   - `recordar_dia`: lee el **diario** de ese día.
4. **Diario:** cuando empieza un día nuevo, el servidor escribe el diario en markdown de los días anteriores (unas 150 palabras). "¿Qué pasó ayer?" lee solo eso.
5. **Retención:** los mensajes se borran a los 30 días y los diarios al año. Las dos cosas se configuran por persona, y la persona puede borrar toda su memoria cuando quiera.

El costo por pregunta queda casi fijo, se converse poco o mucho durante el día.

## Seguridad (Row Level Security)

| Quién | Qué ve |
|---|---|
| La persona | Todo lo suyo. Puede borrar su memoria, sus alertas y sus datos. |
| Su acompañante | Su nombre y sus **alertas**. La **ubicación** solo si la persona activó "compartir ubicación" **y** dio ese permiso al vínculo. **Nunca** las conversaciones. |
| Cualquier otra persona | Nada |
| La app | No puede escribir mensajes ni buscar en la memoria: eso lo hace solo el agente en el servidor |

`tests/test_schema.mjs` verifica estas reglas, y 32 de 32 pruebas pasan. Encontró y corrigió un error real: el acompañante no podía ver la ubicación aunque tuviera permiso.

```bash
cd Backend_Supabase/tests && npm install && npm test
```

## Poner en marcha (lo que tienes que hacer tú)

1. **Crear el proyecto.** Entra a [supabase.com](https://supabase.com), crea una cuenta (gratis) y un proyecto nuevo. Región: **South America (São Paulo)**, la más cercana a Chile. Guarda la contraseña de la base de datos en un lugar seguro.
2. **Subir la base de datos y las funciones.** Desde `Backend_Supabase/`:
   ```bash
   npx supabase login
   npx supabase link --project-ref <id-del-proyecto>
   npx supabase db push
   npx supabase functions deploy agent voice transcribe
   ```
3. **Pasar las claves al servidor** (las mismas de `App_Flutter/.env`):
   ```bash
   npx supabase secrets set AZURE_FOUNDRY_ENDPOINT=... AZURE_FOUNDRY_KEY=... AZURE_FOUNDRY_DEPLOYMENT=gpt-4.1-mini
   npx supabase secrets set AZURE_SPEECH_KEY=... AZURE_SPEECH_REGION=... HUGGINGFACE_API_KEY=...
   npx supabase secrets set LOCATIONIQ_KEY=... OPENWEATHER_KEY=... AZURE_SEARCH_ENDPOINT=... AZURE_SEARCH_KEY=...
   ```
   Opcional: `AZURE_SUMMARY_DEPLOYMENT=gpt-4.1-nano` (más barato para los resúmenes).

   **Importante:** esas claves ya viajaron en APKs que se instalaron en celulares. Cuando la app nueva use el servidor, **regenéralas** en Azure y Hugging Face y sube las nuevas solo aquí.
4. **Login con Google.** En [Google Cloud Console](https://console.cloud.google.com):
   1. Crea un proyecto y configura la "Pantalla de consentimiento de OAuth".
   2. Crea un **ID de cliente OAuth tipo "Web"**. Su ID y su secreto van en Supabase, en *Authentication → Providers → Google*.
   3. Crea un **ID de cliente OAuth tipo "Android"** con el paquete `com.iris.visual.iris_app` y la huella SHA-1 de la llave con que se firma la app. Para la llave de firma, ver `App_Flutter/README` cuando la configuremos.
   4. En Supabase, agrega el ID Android junto al Web en "Client IDs" (separados por coma).
5. **Pasarme estos dos valores** (son públicos y van en la app): la **URL del proyecto** y la **anon key**, que están en *Project Settings → API*.

## Probar todo localmente (opcional)

`npx supabase start` levanta todo en tu PC con Docker. En este PC, Docker Desktop no logra arrancar su motor de Linux (error `DockerDesktop/Wsl/ExecError`). Normalmente se arregla así:

1. En PowerShell **como administrador**, corre `wsl --update`.
2. Reinicia Docker Desktop.
3. Si sigue fallando: *Docker Desktop → Troubleshoot → Reset to factory defaults*.
