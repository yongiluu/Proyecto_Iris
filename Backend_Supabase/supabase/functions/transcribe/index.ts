// Transcripcion de lo que dice la persona (audio del microfono de la placa): WAV -> texto con Whisper.
// POST /functions/v1/transcribe  (cuerpo: audio/wav)  ->  { "text": "..." }
import { json, sessionUser } from "../_shared/auth.ts";

const MAX_AUDIO_BYTES = 4_000_000;  // ~2 minutos a 16 kHz
const WHISPER_URL = "https://router.huggingface.co/hf-inference/models/openai/whisper-large-v3-turbo";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "Usa POST" }, 405);
  if (!(await sessionUser(request))) return json({ error: "Sesion no valida" }, 401);

  const audio = new Uint8Array(await request.arrayBuffer());
  if (audio.length < 44) return json({ error: "Audio vacio" }, 400);
  if (audio.length > MAX_AUDIO_BYTES) return json({ error: "Audio muy largo" }, 413);

  const key = Deno.env.get("HUGGINGFACE_API_KEY");
  if (!key) return json({ error: "Transcripcion no configurada en el servidor" }, 503);

  const response = await fetch(WHISPER_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "audio/wav" },
    body: audio,
  });
  if (!response.ok) {
    console.error("Whisper", response.status, await response.text());
    return json({ error: "Fallo la transcripcion" }, 502);
  }
  const result = await response.json();
  return json({ text: String(result.text ?? "").trim() });
});
