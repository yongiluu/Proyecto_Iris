// Cliente minimo de chat completions de Azure AI Foundry (API compatible con OpenAI).
// Las claves viven solo en el servidor (secrets de Supabase), nunca en la app.

export type ChatMessage = {
  role: "system" | "user" | "assistant" | "tool";
  content: string | Array<Record<string, unknown>> | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  name?: string;
};

export type ToolCall = {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
};

export type Tool = {
  type: "function";
  function: { name: string; description: string; parameters: Record<string, unknown> };
};

const TIMEOUT_MS = 30_000;

function chatUrl(): string {
  let base = (Deno.env.get("AZURE_FOUNDRY_ENDPOINT") ?? "").trim().replace(/\/+$/, "");
  if (!base) throw new Error("Falta AZURE_FOUNDRY_ENDPOINT en los secrets");
  if (base.endsWith("/chat/completions")) return base;
  if (!base.endsWith("/openai/v1")) base += "/openai/v1";
  return `${base}/chat/completions`;
}

export function mainDeployment(): string {
  return Deno.env.get("AZURE_FOUNDRY_DEPLOYMENT") || "gpt-4.1-mini";
}

// Modelo barato para resumir la memoria (si no se define, se usa el principal).
export function summaryDeployment(): string {
  return Deno.env.get("AZURE_SUMMARY_DEPLOYMENT") || mainDeployment();
}

export async function chat(body: {
  model?: string;
  messages: ChatMessage[];
  tools?: Tool[];
  max_tokens?: number;
  temperature?: number;
}): Promise<{ content: string | null; tool_calls: ToolCall[] }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(chatUrl(), {
      method: "POST",
      headers: { "Content-Type": "application/json", "api-key": Deno.env.get("AZURE_FOUNDRY_KEY") ?? "" },
      body: JSON.stringify({
        model: body.model ?? mainDeployment(),
        messages: body.messages,
        ...(body.tools ? { tools: body.tools, tool_choice: "auto" } : {}),
        max_tokens: body.max_tokens ?? 300,
        ...(body.temperature !== undefined ? { temperature: body.temperature } : {}),
      }),
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(`Azure ${response.status}: ${(await response.text()).slice(0, 300)}`);
    }
    const message = (await response.json()).choices?.[0]?.message ?? {};
    return { content: message.content ?? null, tool_calls: message.tool_calls ?? [] };
  } finally {
    clearTimeout(timer);
  }
}

// Las pruebas reemplazan ai.chat por un modelo simulado (supabase/functions/tests/).
export const ai = { chat };
