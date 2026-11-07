// Agente de Iris en el servidor: memoria diaria + herramientas + claves de IA fuera de la app.
//
// POST /functions/v1/agent  (con el token de la sesion de Supabase)
//   { "text": "¿que desayune hoy?", "image_base64"?: "...", "sensor_context"?: "...", "lat"?: -36.8, "lon"?: -73.0 }
// Respuestas:
//   { "reply": "Desayunaste pan con palta y te." }
//   { "need_image": true }   el modelo quiere mirar: la app saca la foto y repite el pedido con image_base64
import { createClient } from "npm:@supabase/supabase-js@2";
import { chat, type ChatMessage } from "../_shared/azure.ts";
import { currentDay, maybeUpdateSummary, recallDay, recentMessages, saveMessage, searchMemory,
         writePendingDiaries } from "../_shared/memory.ts";
import { SYSTEM_PROMPT, VISION_PROMPT } from "../_shared/prompts.ts";
import { medicalSearch, TOOLS, weatherAndLocation } from "../_shared/tools.ts";

const MAX_TOOL_ROUNDS = 3;
const MAX_TEXT = 2_000;
const MAX_IMAGE_BASE64 = 2_500_000;  // ~1,8 MB de JPEG

type AgentRequest = { text?: string; image_base64?: string; sensor_context?: string; lat?: number; lon?: number };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function speakable(text: string | null): string {
  // Se lee en voz alta: sin markdown.
  return (text ?? "").replace(/[*_#`]/g, "").replace(/\s+/g, " ").trim() || "No tengo una respuesta para eso.";
}

function localNow(timezone: string): string {
  return new Intl.DateTimeFormat("es-CL", {
    weekday: "long", day: "numeric", month: "long", year: "numeric", hour: "2-digit", minute: "2-digit",
    hour12: false, timeZone: timezone,
  }).format(new Date());
}

// En Supabase, EdgeRuntime.waitUntil deja terminar trabajo despues de responder (resumen, diarios).
function background(task: Promise<unknown>): void {
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  const safe = task.catch((e) => console.error("tarea en segundo plano:", e));
  if (runtime) runtime.waitUntil(safe);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "Usa POST" }, 405);

  const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: auth } = await db.auth.getUser(token);
  const user = auth?.user;
  if (!user) return json({ error: "Sesion no valida" }, 401);

  let body: AgentRequest;
  try {
    body = await request.json();
  } catch {
    return json({ error: "JSON invalido" }, 400);
  }
  const text = (body.text ?? "").trim().slice(0, MAX_TEXT);
  if (!text) return json({ error: "Falta el texto" }, 400);
  if (body.image_base64 && body.image_base64.length > MAX_IMAGE_BASE64) return json({ error: "Imagen muy grande" }, 413);

  const [{ data: profile }, { data: prefs }] = await Promise.all([
    db.from("profiles").select("timezone, display_name").eq("id", user.id).single(),
    db.from("preferences").select("memory_enabled").eq("user_id", user.id).maybeSingle(),
  ]);
  const timezone = (profile?.timezone as string) || "America/Santiago";
  const memoryOn = prefs?.memory_enabled !== false;

  try {
    const { day, isNew } = await currentDay(db, user.id);
    if (isNew) background(writePendingDiaries(db, user.id, day.day, timezone));

    const context: ChatMessage[] = [{
      role: "system",
      content: `Ahora: ${localNow(timezone)}.` + (profile?.display_name ? ` La persona se llama ${profile.display_name}.` : "") +
        (memoryOn ? `\nResumen de hoy hasta ahora:\n${day.running_summary || "(todavia nada)"}` : "\nLa memoria esta desactivada."),
    }];
    if (body.sensor_context) context.push({ role: "system", content: body.sensor_context.slice(0, 1000) });
    const history: ChatMessage[] = memoryOn
      ? (await recentMessages(db, day.id)).map((m) => ({ role: m.role, content: m.content }))
      : [];

    let reply: string;
    if (body.image_base64) {
      // Con foto: una sola llamada con las instrucciones de vision.
      const result = await chat({
        messages: [
          { role: "system", content: VISION_PROMPT }, ...context, ...history,
          { role: "user", content: [
            { type: "text", text },
            { type: "image_url", image_url: { url: `data:image/jpeg;base64,${body.image_base64}` } },
          ] },
        ],
      });
      reply = speakable(result.content);
    } else {
      const messages: ChatMessage[] = [{ role: "system", content: SYSTEM_PROMPT }, ...context, ...history,
                                       { role: "user", content: text }];
      reply = "";
      for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
        const last = round === MAX_TOOL_ROUNDS;
        const result = await chat({ messages, tools: last ? undefined : TOOLS });
        if (!result.tool_calls.length) {
          reply = speakable(result.content);
          break;
        }
        if (result.tool_calls.some((c) => c.function.name === "analyze_surroundings")) {
          return json({ need_image: true });  // la app saca la foto y vuelve a preguntar con ella
        }
        messages.push({ role: "assistant", content: result.content, tool_calls: result.tool_calls });
        for (const call of result.tool_calls) {
          let args: Record<string, unknown> = {};
          try {
            args = JSON.parse(call.function.arguments || "{}");
          } catch { /* argumentos invalidos: se usan los por defecto */ }
          let output: string;
          switch (call.function.name) {
            case "get_weather_and_location":
              output = await weatherAndLocation(body.lat, body.lon);
              break;
            case "search_medical_database":
              output = await medicalSearch(String(args.query ?? text));
              break;
            case "buscar_en_memoria":
              output = memoryOn
                ? await searchMemory(db, user.id, String(args.consulta ?? text), Number(args.dias_atras ?? 7), day.day, timezone)
                : "La memoria esta desactivada en las preferencias.";
              break;
            case "recordar_dia":
              output = memoryOn
                ? await recallDay(db, user.id, String(args.fecha ?? "ayer"), day.day, timezone)
                : "La memoria esta desactivada en las preferencias.";
              break;
            default:
              output = `Herramienta desconocida: ${call.function.name}`;
          }
          messages.push({ role: "tool", tool_call_id: call.id, name: call.function.name, content: output });
        }
      }
    }

    if (memoryOn) {
      await saveMessage(db, user.id, day.id, "user", text, Boolean(body.image_base64));
      await saveMessage(db, user.id, day.id, "assistant", reply);
      background(maybeUpdateSummary(db, day, timezone));
    }
    return json({ reply });
  } catch (e) {
    console.error("agente:", e);
    return json({ reply: "Hubo un problema con el servidor de Iris. Intentalo de nuevo." }, 502);
  }
});
