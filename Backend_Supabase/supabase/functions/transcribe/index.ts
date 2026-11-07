// Transcripcion de lo que dice la persona (audio del microfono de la placa): WAV -> texto.
// POST /functions/v1/transcribe  (cuerpo: audio/wav 16 kHz mono)  ->  { "text": "..." }
// Mismo orden que usaba la app: Groq (Whisper gratis), Azure Speech y Hugging Face, segun que llaves haya.
import { json, sessionUser } from "../_shared/auth.ts";

const MAX_AUDIO_BYTES = 4_000_000;  // ~2 minutos a 16 kHz
const TIMEOUT_MS = 30_000;

async function withTimeout(url: string, init: RequestInit): Promise<Response | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } catch (e) {
    console.error("transcribe", url, e);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function groq(audio: ArrayBuffer): Promise<string> {
  const key = Deno.env.get("GROQ_API_KEY");
  if (!key) return "";
  const form = new FormData();
  form.append("model", "whisper-large-v3-turbo");
  form.append("language", "es");
  form.append("response_format", "json");
  form.append("file", new Blob([audio], { type: "audio/wav" }), "pregunta.wav");
  const response = await withTimeout("https://api.groq.com/openai/v1/audio/transcriptions", {
    method: "POST", headers: { Authorization: `Bearer ${key}` }, body: form,
  });
  return response?.ok ? String((await response.json()).text ?? "").trim() : "";
}

async function azure(audio: ArrayBuffer): Promise<string> {
  const key = Deno.env.get("AZURE_SPEECH_KEY");
  const region = Deno.env.get("AZURE_SPEECH_REGION");
  if (!key || !region) return "";
  const response = await withTimeout(
    `https://${region}.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=es-CL&format=simple`,
    {
      method: "POST",
      headers: { "Ocp-Apim-Subscription-Key": key, "Content-Type": "audio/wav; codecs=audio/pcm; samplerate=16000",
                 Accept: "application/json" },
      body: audio,
    },
  );
  return response?.ok ? String((await response.json()).DisplayText ?? "").trim() : "";
}

async function huggingFace(audio: ArrayBuffer): Promise<string> {
  const key = Deno.env.get("HUGGINGFACE_API_KEY");
  if (!key) return "";
  const response = await withTimeout("https://router.huggingface.co/hf-inference/models/openai/whisper-large-v3-turbo", {
    method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "audio/wav" }, body: audio,
  });
  return response?.ok ? String((await response.json()).text ?? "").trim() : "";
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "Usa POST" }, 405);
  if (!(await sessionUser(request))) return json({ error: "Sesion no valida" }, 401);

  const audio = await request.arrayBuffer();
  if (audio.byteLength < 44) return json({ error: "Audio vacio" }, 400);
  if (audio.byteLength > MAX_AUDIO_BYTES) return json({ error: "Audio muy largo" }, 413);

  for (const engine of [groq, azure, huggingFace]) {
    const text = await engine(audio);
    if (text) return json({ text });
  }
  return json({ text: "" });
});
