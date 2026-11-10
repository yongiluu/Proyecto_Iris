# App de Iris

App para personas ciegas o con baja visión. Todo se puede hacer **por voz**: "Oye Iris" en la placa
o doble toque en el botón de subir volumen del celular, y después la pregunta o el comando.

## Modos (carrusel: deslizar de lado)

| Modo | Botón grande | Por voz |
|---|---|---|
| Iris | Mantener para hablar | "¿Qué hay adelante?" (contesta la placa al instante, sin internet; "más detalle" pregunta a la nube), "describe en vivo" / "deja de describir", y cualquier pregunta: "¿qué tiempo hace?" |
| Leer | Tocar para leer | "¿Qué dice aquí?", "léeme esto" |
| Luz | Prender / apagar | "Busca la luz", "apaga el detector de luz" |
| Personas | ¿Quién está? | "¿Quién está aquí?", "recuerda a Raúl", "olvida a Raúl" |

Los ajustes poco usados (Celular o Módulo, cambiar placa, volumen de la placa, Mi cuenta) están en
el engranaje de arriba.

## Comandos que funcionan sin internet

Se resuelven en el celular, al instante, sin pasar por el modelo de lenguaje
(`lib/services/ai/voice_intents.dart`):

- **Leer texto**: con la placa conectada lee la placa (si su firmware tiene el lector); si no, la
  cámara del celular (ML Kit).
- **Buscar luz**: tono más agudo con más luz (placa o celular).
- **Personas conocidas**: reconoce caras guardadas con "recuerda a …" (5 fotos guiadas por voz). Solo
  se guarda una huella numérica de la cara, nunca fotos, y nada sale del celular. Pedirle permiso a la
  persona antes de guardarla.
- **Repite**, **¿qué puedes hacer?**, **¿qué hora es?**, **habla más lento / más rápido**,
  **cállate**.

## Desarrollo

```bash
flutter pub get
flutter analyze
flutter test
```

Las llaves van en `.env` (ver `.env.template`); nunca se suben al repositorio.
Avisos de licencias de terceros: `THIRD_PARTY_NOTICES.md`.
