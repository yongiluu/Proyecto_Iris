// Herramientas externas del agente (las claves quedan en el servidor).
import type { Tool } from "./azure.ts";

const TOOL_TIMEOUT_MS = 15_000;

export const TOOLS: Tool[] = [
  {
    type: "function",
    function: {
      name: "analyze_surroundings",
      description: "Toma una foto con la camara de la persona y describe su entorno.",
      parameters: { type: "object", properties: {} },
    },
  },
  {
    type: "function",
    function: {
      name: "get_weather_and_location",
      description: "Ubicacion actual (calle y ciudad) y clima de la persona.",
      parameters: { type: "object", properties: {} },
    },
  },
  {
    type: "function",
    function: {
      name: "search_medical_database",
      description: "Busca en la base de datos medica (guias de la FDA) sobre medicamentos y salud.",
      parameters: {
        type: "object",
        properties: { query: { type: "string", description: "La consulta medica" } },
        required: ["query"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "buscar_en_memoria",
      description: "Busca en lo que la persona conto en conversaciones anteriores (hoy y dias pasados). " +
        "Usala cuando pregunte por algo que dijo antes y no aparece en el resumen de hoy.",
      parameters: {
        type: "object",
        properties: {
          consulta: { type: "string", description: "Palabras clave, ej. 'desayuno', 'medico hora'" },
          dias_atras: { type: "integer", description: "Cuantos dias hacia atras buscar (0 = solo hoy). Por defecto 7." },
        },
        required: ["consulta"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "recordar_dia",
      description: "Devuelve el resumen de lo que paso un dia (\"¿que paso ayer?\").",
      parameters: {
        type: "object",
        properties: { fecha: { type: "string", description: "'hoy', 'ayer', 'anteayer' o AAAA-MM-DD" } },
        required: ["fecha"],
      },
    },
  },
];

async function fetchJson(url: string, init?: RequestInit): Promise<Record<string, unknown> | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TOOL_TIMEOUT_MS);
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    return response.ok ? await response.json() : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export async function weatherAndLocation(lat?: number, lon?: number): Promise<string> {
  if (lat === undefined || lon === undefined) {
    return "No llego la ubicacion GPS del celular. Dile que active la ubicacion; no inventes una.";
  }
  let place = "ubicacion desconocida";
  let weather = "clima desconocido";
  const locationKey = Deno.env.get("LOCATIONIQ_KEY");
  if (locationKey) {
    const data = await fetchJson(`https://us1.locationiq.com/v1/reverse?key=${locationKey}&lat=${lat}&lon=${lon}&format=json`);
    const address = (data?.address ?? {}) as Record<string, string>;
    if (data) place = `${address.road ?? "una calle desconocida"}, ${address.city ?? address.town ?? address.village ?? ""}`;
  }
  const weatherKey = Deno.env.get("OPENWEATHER_KEY");
  if (weatherKey) {
    const data = await fetchJson(
      `https://api.openweathermap.org/data/2.5/weather?lat=${lat}&lon=${lon}&appid=${weatherKey}&units=metric&lang=es`);
    if (data) {
      const main = data.main as { temp: number };
      const description = (data.weather as Array<{ description: string }>)[0]?.description ?? "";
      weather = `${Math.round(main.temp)}°C y ${description}`;
    }
  }
  return `Ubicacion: ${place}. Clima: ${weather}.`;
}

export async function medicalSearch(query: string): Promise<string> {
  const endpoint = Deno.env.get("AZURE_SEARCH_ENDPOINT");
  const key = Deno.env.get("AZURE_SEARCH_KEY");
  if (!endpoint || !key) return "Base de datos medica no configurada.";
  const data = await fetchJson(`${endpoint}/indexes/insulina-fda-kb/docs/search?api-version=2023-11-01`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "api-key": key },
    body: JSON.stringify({ search: query, top: 3 }),
  });
  const values = (data?.value ?? []) as Array<{ content?: string }>;
  if (!values.length) return `No se encontraron resultados en la base de datos medica para: ${query}.`;
  return values.map((v) => v.content ?? "").join("\n");
}
