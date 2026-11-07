import { createClient, type User } from "npm:@supabase/supabase-js@2";

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

// Usuario de la sesion (token de Supabase en Authorization: Bearer ...) o null.
export async function sessionUser(request: Request): Promise<User | null> {
  const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data } = await db.auth.getUser(token);
  return data?.user ?? null;
}
