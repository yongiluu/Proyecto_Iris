// Pruebas del agente con memoria diaria, con una base de datos y un modelo de IA simulados.
//
//   cd Backend_Supabase/supabase/functions && npx deno test --allow-env tests/
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ai, type ChatMessage, type ToolCall } from "../_shared/azure.ts";
import { DIARY_PROMPT, SUMMARY_PROMPT, VISION_PROMPT } from "../_shared/prompts.ts";
import { handleAgent } from "../agent/handler.ts";
import { FakeDb } from "./fake_db.ts";

type ChatBody = Parameters<typeof ai.chat>[0];
type Reply = { content: string | null; tool_calls: ToolCall[] };

const ANA = "usuario-ana";
const TOKEN = "token-ana";

// Modelo simulado: decide la respuesta segun lo que recibe y guarda cada llamada para revisarla.
class FakeAI {
  calls: ChatBody[] = [];
  agent: (body: ChatBody, call: number) => Reply = () => ({ content: "Listo.", tool_calls: [] });
  private agentCalls = 0;

  chat = (body: ChatBody): Promise<Reply> => {
    this.calls.push(body);
    const system = String(body.messages[0].content);
    if (system === SUMMARY_PROMPT) return Promise.resolve({ content: "08:10 desayuno pan con palta", tool_calls: [] });
    if (system === DIARY_PROMPT) return Promise.resolve({ content: "# Sabado 7 de noviembre\n- Desayuno pan con palta", tool_calls: [] });
    return Promise.resolve(this.agent(body, this.agentCalls++));
  };

  agentBodies(): ChatBody[] {
    return this.calls.filter((c) => ![SUMMARY_PROMPT, DIARY_PROMPT].includes(String(c.messages[0].content)));
  }
}

function toolCall(name: string, args: Record<string, unknown> = {}): ToolCall {
  return { id: `call_${name}`, type: "function", function: { name, arguments: JSON.stringify(args) } };
}

function setup(memoryEnabled = true) {
  const db = new FakeDb();
  db.addUser(TOKEN, ANA, "Ana", memoryEnabled);
  const fake = new FakeAI();
  ai.chat = fake.chat;
  const pending: Promise<unknown>[] = [];
  const ask = async (body: Record<string, unknown>, token = TOKEN) => {
    const response = await handleAgent(
      new Request("http://iris/agent", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body) }),
      { db: db as unknown as SupabaseClient, background: (task) => pending.push(task) },
    );
    return { status: response.status, body: await response.json() };
  };
  const settle = async () => {
    while (pending.length) await pending.shift();
  };
  return { db, fake, ask, settle };
}

function allText(messages: ChatMessage[]): string {
  return messages.map((m) => typeof m.content === "string" ? m.content : JSON.stringify(m.content)).join("\n");
}

Deno.test("sin sesion responde 401 y no llama al modelo", async () => {
  const { ask, fake } = setup();
  const { status } = await ask({ text: "hola" }, "token-falso");
  assertEquals(status, 401);
  assertEquals(fake.calls.length, 0);
});

Deno.test("primera pregunta del dia: guarda pregunta y respuesta", async () => {
  const { ask, db } = setup();
  db.tables.messages = [];
  const { status, body } = await ask({ text: "Hoy desayuné pan con palta" });
  assertEquals(status, 200);
  assertEquals(body.reply, "Listo.");
  assertEquals(db.tables.conversation_days.length, 1);
  assertEquals(db.tables.messages.map((m) => m.role), ["user", "assistant"]);
  assertEquals(db.tables.messages[0].content, "Hoy desayuné pan con palta");
});

Deno.test("recuerda lo de hoy: la conversacion reciente va al modelo", async () => {
  const { ask, fake } = setup();
  await ask({ text: "Hoy desayuné pan con palta" });
  await ask({ text: "¿Qué desayuné hoy?" });
  const last = fake.agentBodies().at(-1)!;
  assertStringIncludes(allText(last.messages), "Hoy desayuné pan con palta");
  assertStringIncludes(allText(last.messages), "Ahora:");  // sabe la hora local
});

Deno.test("cada 8 mensajes resume el dia con el modelo barato y el resumen va en las siguientes preguntas", async () => {
  const { ask, db, fake, settle } = setup();
  for (let i = 0; i < 4; i++) {
    await ask({ text: `mensaje ${i}` });
    await settle();
  }
  const day = db.tables.conversation_days[0];
  assertEquals(day.running_summary, "08:10 desayuno pan con palta");
  assertEquals(day.summarized_until, 8);
  assertEquals(fake.calls.filter((c) => c.messages[0].content === SUMMARY_PROMPT).length, 1);

  await ask({ text: "¿Qué hice hoy?" });
  assertStringIncludes(allText(fake.agentBodies().at(-1)!.messages), "08:10 desayuno pan con palta");
});

Deno.test("la conversacion reciente se limita a los ultimos 10 mensajes (no relee todo el dia)", async () => {
  const { ask, fake } = setup();
  for (let i = 0; i < 12; i++) await ask({ text: `mensaje numero ${i}` });
  const sent = fake.agentBodies().at(-1)!.messages.filter((m) => m.role === "user" || m.role === "assistant");
  assertEquals(sent.length, 11);  // 10 recientes + la pregunta nueva
  assert(!allText(sent).includes("mensaje numero 0"));
});

Deno.test("buscar_en_memoria encuentra lo que se dijo y el modelo responde con eso", async () => {
  const { ask, fake } = setup();
  await ask({ text: "A las cinco tengo hora al médico" });
  fake.agent = (_body, call) => call === 1
    ? { content: null, tool_calls: [toolCall("buscar_en_memoria", { consulta: "medico hora" })] }
    : { content: "Tienes hora al médico a las cinco.", tool_calls: [] };
  const { body } = await ask({ text: "¿A qué hora era el médico?" });
  assertEquals(body.reply, "Tienes hora al médico a las cinco.");
  const toolMessage = fake.agentBodies().at(-1)!.messages.find((m) => m.role === "tool")!;
  assertStringIncludes(String(toolMessage.content), "hora al médico");
});

Deno.test("al empezar un dia nuevo se escribe el diario del dia anterior", async () => {
  const { ask, db, settle } = setup();
  await ask({ text: "Hoy desayuné pan con palta" });
  db.today = "2026-11-09";
  await ask({ text: "Buenos días Iris" });
  await settle();
  assertEquals(db.tables.daily_diaries.length, 1);
  assertEquals(db.tables.daily_diaries[0].day, "2026-11-08");
  assert(db.tables.conversation_days.find((d) => d.day === "2026-11-08")!.diary_written);
});

Deno.test("recordar_dia('ayer') lee solo el diario de ayer", async () => {
  const { ask, db, fake } = setup();
  db.tables.daily_diaries.push({ user_id: ANA, day: "2026-11-07", summary_md: "# Viernes\n- Fue a la feria" });
  fake.agent = (_body, call) => call === 0
    ? { content: null, tool_calls: [toolCall("recordar_dia", { fecha: "ayer" })] }
    : { content: "Ayer fuiste a la feria.", tool_calls: [] };
  const { body } = await ask({ text: "¿Qué pasó ayer?" });
  assertEquals(body.reply, "Ayer fuiste a la feria.");
  const toolMessage = fake.agentBodies().at(-1)!.messages.find((m) => m.role === "tool")!;
  assertEquals(toolMessage.content, "# Viernes\n- Fue a la feria");
});

Deno.test("si el modelo quiere mirar, pide la foto y no guarda nada todavia", async () => {
  const { ask, db, fake } = setup();
  fake.agent = () => ({ content: null, tool_calls: [toolCall("analyze_surroundings")] });
  const { body } = await ask({ text: "¿Qué hay adelante?" });
  assertEquals(body, { need_image: true });
  assertEquals(db.tables.messages.length, 0);
});

Deno.test("con foto usa las instrucciones de vision y marca que hubo imagen", async () => {
  const { ask, db, fake } = setup();
  fake.agent = () => ({ content: "Adelante hay una puerta café.", tool_calls: [] });
  const { body } = await ask({ text: "¿Qué hay adelante?", image_base64: "AAAA" });
  assertEquals(body.reply, "Adelante hay una puerta café.");
  const sent = fake.agentBodies().at(-1)!;
  assertEquals(sent.messages[0].content, VISION_PROMPT);
  assertStringIncludes(JSON.stringify(sent.messages.at(-1)), "data:image/jpeg;base64,AAAA");
  assertEquals(db.tables.messages[0].had_image, true);
});

Deno.test("con la memoria desactivada no guarda ni lee la conversacion", async () => {
  const { ask, db, fake } = setup(false);
  await ask({ text: "Hoy desayuné pan con palta" });
  fake.agent = (_body, call) => call === 1
    ? { content: null, tool_calls: [toolCall("buscar_en_memoria", { consulta: "desayuno" })] }
    : { content: "No lo recuerdo.", tool_calls: [] };
  await ask({ text: "¿Qué desayuné?" });
  assertEquals(db.tables.messages.length, 0);
  const toolMessage = fake.agentBodies().at(-1)!.messages.find((m) => m.role === "tool")!;
  assertStringIncludes(String(toolMessage.content), "desactivada");
});

Deno.test("las respuestas se limpian de markdown para leerlas en voz alta", async () => {
  const { ask, fake } = setup();
  fake.agent = () => ({ content: "**Hola**,  _Ana_ #1", tool_calls: [] });
  const { body } = await ask({ text: "hola" });
  assertEquals(body.reply, "Hola, Ana 1");
});
