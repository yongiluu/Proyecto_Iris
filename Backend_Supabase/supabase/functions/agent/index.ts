// Agente de Iris en el servidor: memoria diaria + herramientas + claves de IA fuera de la app.
//
// POST /functions/v1/agent  (con el token de la sesion de Supabase)
//   { "text": "¿que desayune hoy?", "image_base64"?: "...", "sensor_context"?: "...", "lat"?: -36.8, "lon"?: -73.0 }
// Respuestas:
//   { "reply": "Desayunaste pan con palta y te." }
//   { "need_image": true }   el modelo quiere mirar: la app saca la foto y repite el pedido con image_base64
import { createClient } from "npm:@supabase/supabase-js@2";
import { handleAgent } from "./handler.ts";

Deno.serve((request) =>
  handleAgent(request, {
    db: createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false },
    }),
  })
);
