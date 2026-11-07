// Memoria diaria de Iris.
//
// Para no releer todo el dia en cada pregunta (caro), el agente ve:
//   - el resumen acumulado del dia (lo actualiza un modelo barato cada SUMMARY_EVERY mensajes nuevos)
//   - los ultimos RECENT_TURNS mensajes textuales
// y si necesita algo mas, usa herramientas: buscar_en_memoria (busqueda de texto en Postgres) o
// recordar_dia (lee el diario en markdown de ese dia, ~150 palabras, no la conversacion completa).
// El diario de cada dia se escribe cuando empieza el dia siguiente (o al pedirlo).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { chat, summaryDeployment } from "./azure.ts";
import { DIARY_PROMPT, SUMMARY_PROMPT } from "./prompts.ts";

export const RECENT_TURNS = 10;
export const SUMMARY_EVERY = 8;
const MAX_DIARY_SOURCE_CHARS = 24_000;

export type Day = { id: number; day: string; running_summary: string; summarized_until: number; diary_written: boolean };
type Message = { id: number; role: "user" | "assistant"; content: string; created_at: string };

export async function currentDay(db: SupabaseClient, userId: string): Promise<{ day: Day; isNew: boolean }> {
  const { data: today, error } = await db.rpc("conversation_day_for", { target: userId });
  if (error) throw error;
  const { data: inserted } = await db.from("conversation_days")
    .upsert({ user_id: userId, day: today }, { onConflict: "user_id,day", ignoreDuplicates: true })
    .select().maybeSingle();
  if (inserted) return { day: inserted as Day, isNew: true };
  const { data, error: selectError } = await db.from("conversation_days")
    .select().eq("user_id", userId).eq("day", today).single();
  if (selectError) throw selectError;
  return { day: data as Day, isNew: false };
}

export async function recentMessages(db: SupabaseClient, dayId: number, limit = RECENT_TURNS): Promise<Message[]> {
  const { data, error } = await db.from("messages").select("id, role, content, created_at")
    .eq("day_id", dayId).order("id", { ascending: false }).limit(limit);
  if (error) throw error;
  return (data as Message[]).reverse();
}

export async function saveMessage(db: SupabaseClient, userId: string, dayId: number, role: "user" | "assistant",
                                  content: string, hadImage = false): Promise<void> {
  const { error } = await db.from("messages").insert({ user_id: userId, day_id: dayId, role, content, had_image: hadImage });
  if (error) throw error;
}

function clock(iso: string, timezone: string): string {
  return new Intl.DateTimeFormat("es-CL", { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: timezone })
    .format(new Date(iso));
}

function transcript(messages: Message[], timezone: string): string {
  return messages.map((m) => `[${clock(m.created_at, timezone)}] ${m.role === "user" ? "Persona" : "Iris"}: ${m.content}`)
    .join("\n");
}

// Junta los mensajes nuevos al resumen del dia (con el modelo barato) cada SUMMARY_EVERY mensajes.
export async function maybeUpdateSummary(db: SupabaseClient, day: Day, timezone: string): Promise<boolean> {
  const { data, error } = await db.from("messages").select("id, role, content, created_at")
    .eq("day_id", day.id).gt("id", day.summarized_until).order("id");
  if (error) throw error;
  const fresh = data as Message[];
  if (fresh.length < SUMMARY_EVERY) return false;

  const result = await chat({
    model: summaryDeployment(),
    temperature: 0,
    max_tokens: 600,
    messages: [
      { role: "system", content: SUMMARY_PROMPT },
      { role: "user", content: `Resumen anterior:\n${day.running_summary || "(vacio)"}\n\nMensajes nuevos:\n${transcript(fresh, timezone)}` },
    ],
  });
  const summary = (result.content ?? "").trim();
  if (!summary) return false;
  await db.from("conversation_days")
    .update({ running_summary: summary, summarized_until: fresh[fresh.length - 1].id })
    .eq("id", day.id).eq("summarized_until", day.summarized_until);  // si otro proceso lo actualizo antes, no pisarlo
  return true;
}

export async function writeDiary(db: SupabaseClient, userId: string, day: Day, timezone: string): Promise<string | null> {
  const { data, error } = await db.from("messages").select("id, role, content, created_at")
    .eq("day_id", day.id).order("id");
  if (error) throw error;
  const messages = data as Message[];
  if (messages.length === 0 && !day.running_summary) {
    await db.from("conversation_days").update({ diary_written: true }).eq("id", day.id);
    return null;
  }
  // Lo nuevo desde el ultimo resumen va completo; si aun asi es muy largo, se queda con lo mas reciente.
  let conversation = transcript(messages.filter((m) => m.id > day.summarized_until), timezone);
  if (conversation.length > MAX_DIARY_SOURCE_CHARS) conversation = conversation.slice(-MAX_DIARY_SOURCE_CHARS);

  const result = await chat({
    model: summaryDeployment(),
    temperature: 0,
    max_tokens: 500,
    messages: [
      { role: "system", content: DIARY_PROMPT },
      { role: "user", content: `Fecha: ${day.day}\nResumen del dia:\n${day.running_summary || "(vacio)"}\n\nConversacion no resumida:\n${conversation || "(nada)"}` },
    ],
  });
  const diary = (result.content ?? "").trim();
  if (!diary) return null;
  await db.from("daily_diaries").upsert({ user_id: userId, day: day.day, summary_md: diary });
  await db.from("conversation_days").update({ diary_written: true }).eq("id", day.id);
  return diary;
}

// Escribe los diarios de los dias anteriores que quedaron sin cerrar.
export async function writePendingDiaries(db: SupabaseClient, userId: string, today: string, timezone: string): Promise<number> {
  const { data, error } = await db.from("conversation_days").select()
    .eq("user_id", userId).eq("diary_written", false).lt("day", today).order("day").limit(7);
  if (error) throw error;
  let written = 0;
  for (const day of data as Day[]) {
    if (await writeDiary(db, userId, day, timezone)) written++;
  }
  return written;
}

// ─── Herramientas del agente ─────────────────────────────────────────────────

export async function searchMemory(db: SupabaseClient, userId: string, query: string, daysBack: number,
                                   today: string, timezone: string): Promise<string> {
  const since = new Date(`${today}T12:00:00Z`);
  since.setUTCDate(since.getUTCDate() - Math.max(0, Math.min(daysBack, 60)));
  const { data, error } = await db.rpc("search_memory", {
    target: userId, query, since: since.toISOString().slice(0, 10), max_results: 8,
  });
  if (error) throw error;
  const rows = data as Array<{ day: string; role: string; content: string; created_at: string }>;
  if (!rows.length) return "No encontre nada sobre eso en la memoria.";
  return rows.map((r) => `[${r.day} ${clock(r.created_at, timezone)}] ${r.role === "user" ? "Persona" : "Iris"}: ${r.content}`)
    .join("\n");
}

// fecha: "ayer", "anteayer", "hoy" o AAAA-MM-DD.
export async function recallDay(db: SupabaseClient, userId: string, date: string, today: string,
                                timezone: string): Promise<string> {
  const offsets: Record<string, number> = { hoy: 0, ayer: 1, anteayer: 2 };
  let target = date.trim().toLowerCase();
  if (target in offsets) {
    const d = new Date(`${today}T12:00:00Z`);
    d.setUTCDate(d.getUTCDate() - offsets[target]);
    target = d.toISOString().slice(0, 10);
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(target)) return "Fecha no valida: usa AAAA-MM-DD, 'hoy', 'ayer' o 'anteayer'.";

  if (target === today) {
    const { data } = await db.from("conversation_days").select().eq("user_id", userId).eq("day", today).maybeSingle();
    const day = data as Day | null;
    if (!day) return "Hoy todavia no hemos conversado.";
    return `Resumen de hoy:\n${day.running_summary || "(todavia sin resumen)"}\n\nUltimos mensajes:\n${
      transcript(await recentMessages(db, day.id), timezone)}`;
  }

  const { data: diary } = await db.from("daily_diaries").select("summary_md").eq("user_id", userId).eq("day", target).maybeSingle();
  if (diary) return diary.summary_md as string;
  const { data: dayRow } = await db.from("conversation_days").select().eq("user_id", userId).eq("day", target).maybeSingle();
  if (!dayRow) return `No tengo registro de conversaciones del ${target}.`;
  return (await writeDiary(db, userId, dayRow as Day, timezone)) ?? `No hay nada guardado del ${target}.`;
}
