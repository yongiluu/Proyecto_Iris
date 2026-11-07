// Voz de Iris para la placa: texto -> Azure TTS en PCM 16 kHz 16-bit mono (lo que reproduce el ESP32).
// POST /functions/v1/voice  { "text": "...", "lang"?: "es-CL" | "en-US" }  ->  bytes PCM 16 kHz 16-bit mono
import { json, sessionUser } from "../_shared/auth.ts";

const VOICES: Record<string, string> = { "es-CL": "es-CL-CatalinaNeural", "en-US": "en-US-AriaNeural" };
const MAX_TEXT = 1_500;

function escapeXml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "Usa POST" }, 405);
  if (!(await sessionUser(request))) return json({ error: "Sesion no valida" }, 401);

  const { text, lang } = await request.json().catch(() => ({}));
  const clean = String(text ?? "").trim().slice(0, MAX_TEXT);
  if (!clean) return json({ error: "Falta el texto" }, 400);
  const language = lang === "en-US" ? "en-US" : "es-CL";

  const key = Deno.env.get("AZURE_SPEECH_KEY");
  const region = Deno.env.get("AZURE_SPEECH_REGION");
  if (!key || !region) return json({ error: "Voz no configurada en el servidor" }, 503);

  const response = await fetch(`https://${region}.tts.speech.microsoft.com/cognitiveservices/v1`, {
    method: "POST",
    headers: {
      "Ocp-Apim-Subscription-Key": key,
      "Content-Type": "application/ssml+xml",
      "X-Microsoft-OutputFormat": "raw-16khz-16bit-mono-pcm",
    },
    body: `<speak version="1.0" xml:lang="${language}"><voice xml:lang="${language}" name="${VOICES[language]}">` +
      `${escapeXml(clean)}</voice></speak>`,
  });
  if (!response.ok) {
    console.error("Azure TTS", response.status, await response.text());
    return json({ error: "Fallo la voz" }, 502);
  }
  // octet-stream: el cliente de Supabase en la app lo entrega como bytes (PCM 16 kHz 16-bit mono).
  return new Response(response.body, { headers: { "Content-Type": "application/octet-stream" } });
});
