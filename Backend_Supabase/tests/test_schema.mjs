// Prueba la migracion de la base de datos SIN Docker: Postgres 17 en memoria (PGlite) con lo minimo de
// Supabase simulado (auth.users, auth.uid(), roles, storage, cron). Verifica las reglas de seguridad
// (RLS) desde el punto de vista de cada persona.
//
//   cd Backend_Supabase/tests && npm install && npm test
import { readFileSync, readdirSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const MIGRATIONS_DIR = new URL("../supabase/migrations/", import.meta.url);

const SUPABASE_STUBS = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;
  create schema auth;
  create table auth.users (id uuid primary key, raw_user_meta_data jsonb not null default '{}');
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create schema storage;
  create table storage.buckets (id text primary key, name text, public boolean);
  create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
  alter table storage.objects enable row level security;
  create function storage.foldername(name text) returns text[] language sql immutable as
    $$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
  create schema cron;
  create function cron.schedule(job text, schedule text, command text) returns bigint language sql as $$ select 1::bigint $$;
  grant usage on schema public, auth, storage to anon, authenticated, service_role;
  grant select, insert, update, delete on storage.objects to authenticated, service_role;
  -- Como Supabase: los roles de la API reciben permisos por defecto; la migracion los restringe donde hace falta
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
`;

const ANA = "00000000-0000-0000-0000-00000000000a";
const BETO = "00000000-0000-0000-0000-00000000000b";
const CARLA = "00000000-0000-0000-0000-00000000000c";

let failures = 0;
let passed = 0;
function check(condition, message) {
  if (condition) {
    passed++;
    console.log(`  ✔ ${message}`);
  } else {
    failures++;
    console.log(`  ✗ ${message}`);
  }
}

const db = new PGlite();

// Ejecuta como una persona con sesion (rol authenticated + su id en el JWT simulado)
async function as(userId, sql, params = []) {
  await db.exec(`set role ${userId === "service" ? "service_role" : "authenticated"}`);
  await db.query("select set_config('request.jwt.claim.sub', $1, false)", [userId === "service" ? "" : userId]);
  try {
    return await db.query(sql, params);
  } finally {
    await db.exec("reset role");
  }
}

async function fails(userId, sql, params = []) {
  try {
    await as(userId, sql, params);
    return null;
  } catch (e) {
    return e.message;
  }
}

async function main() {
  await db.exec(SUPABASE_STUBS);
  for (const file of readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql")).sort()) {
    const sql = readFileSync(new URL(file, MIGRATIONS_DIR), "utf8")
      .replace(/create extension if not exists pg_cron;/g, "-- (pg_cron simulado)");
    await db.exec(sql);
    console.log(`Migracion aplicada: ${file}`);
  }

  console.log("\nRegistro");
  await db.query(`insert into auth.users (id, raw_user_meta_data) values
    ($1, '{"full_name": "Ana"}'), ($2, '{"name": "Beto"}'), ($3, '{"full_name": "Carla"}')`, [ANA, BETO, CARLA]);
  const profiles = await db.query("select p.display_name, pr.memory_enabled from profiles p join preferences pr on pr.user_id = p.id order by p.display_name");
  check(profiles.rows.length === 3 && profiles.rows[0].display_name === "Ana", "al registrarse se crean perfil y preferencias");

  console.log("\nMemoria (la escribe el agente con la clave de servicio)");
  const day = (await as("service", "select public.conversation_day_for($1) as d", [ANA])).rows[0].d;
  const dayId = (await as("service", "insert into conversation_days (user_id, day) values ($1, $2) returning id", [ANA, day])).rows[0].id;
  await as("service", `insert into messages (user_id, day_id, role, content) values
    ($1, $2, 'user', 'Hoy desayuné pan con palta y té'), ($1, $2, 'assistant', 'Qué rico, que tengas buen día'),
    ($1, $2, 'user', 'A las cinco tengo hora al médico')`, [ANA, dayId]);
  check((await as(ANA, "select count(*)::int n from messages")).rows[0].n === 3, "Ana ve sus 3 mensajes");
  check((await as(CARLA, "select count(*)::int n from messages")).rows[0].n === 0, "Carla (desconocida) no ve nada");
  check((await as(BETO, "select count(*)::int n from messages")).rows[0].n === 0, "Beto no ve las conversaciones (aunque sea acompañante)");
  check(await fails(ANA, "insert into messages (user_id, day_id, role, content) values ($1, $2, 'user', 'x')", [ANA, dayId]) !== null,
        "la app no puede escribir mensajes directo (solo el agente)");
  check(await fails(ANA, "select * from search_memory($1, 'desayuno', '2000-01-01')", [ANA]) !== null,
        "la app no puede llamar search_memory (podria leer memoria ajena)");
  const found = await as("service", "select content from search_memory($1, 'desayuno', '2000-01-01')", [ANA]);
  check(found.rows.length === 1 && found.rows[0].content.includes("palta"), "el agente encuentra 'desayuno' en 'desayuné' (español)");
  const medico = await as("service", "select content from search_memory($1, 'medico hora', '2000-01-01')", [ANA]);
  check(medico.rows.length === 1, "busca 'medico hora' sin tilde y encuentra 'hora al médico'");

  console.log("\nDia de conversacion (empieza a las 4:00 hora de Chile)");
  const at3am = (await db.query("select public.conversation_day_for($1, '2026-11-08 03:00-03') d", [ANA])).rows[0].d;
  const at5am = (await db.query("select public.conversation_day_for($1, '2026-11-08 05:00-03') d", [ANA])).rows[0].d;
  check(at3am.toISOString().startsWith("2026-11-07") && at5am.toISOString().startsWith("2026-11-08"),
        "las 3:00 cuentan como el dia anterior; las 5:00 ya son el dia nuevo");

  console.log("\nAcompañante con codigo");
  const code = (await as(ANA, "select public.create_companion_invite() c")).rows[0].c;
  check(/^\d{6}$/.test(code), `Ana genera un codigo de 6 digitos (${code})`);
  check((await fails(ANA, "select public.accept_companion_invite($1)", [code]))?.includes("propio"), "Ana no puede aceptarse a si misma");
  check((await fails(CARLA, "select public.accept_companion_invite('000000')")) !== null, "un codigo inventado no sirve");
  await as(BETO, "select public.accept_companion_invite($1)", [code]);
  check((await fails(CARLA, "select public.accept_companion_invite($1)", [code])) !== null, "el codigo es de un solo uso");
  check((await as(ANA, "select count(*)::int n from companion_links")).rows[0].n === 1, "Ana ve el vinculo");
  check((await as(BETO, "select display_name from profiles where id = $1", [ANA])).rows[0]?.display_name === "Ana",
        "Beto ve el nombre de Ana");
  check((await as(ANA, "select display_name from profiles where id = $1", [BETO])).rows[0]?.display_name === "Beto",
        "Ana ve el nombre de Beto");
  check((await as(CARLA, "select count(*)::int n from profiles where id = $1", [ANA])).rows[0].n === 0, "Carla no ve el perfil de Ana");

  console.log("\nAlertas y ubicacion");
  await as(ANA, "insert into alerts (user_id, kind, detail) values ($1, 'sirena', 'sirena cerca')", [ANA]);
  check((await as(BETO, "select count(*)::int n from alerts")).rows[0].n === 1, "Beto ve las alertas de Ana");
  check((await as(CARLA, "select count(*)::int n from alerts")).rows[0].n === 0, "Carla no ve alertas");
  check(await fails(BETO, "insert into alerts (user_id, kind) values ($1, 'falsa')", [ANA]) !== null,
        "Beto no puede crear alertas a nombre de Ana");
  await as(ANA, "insert into last_locations (user_id, lat, lon) values ($1, -36.83, -73.05)", [ANA]);
  check((await as(BETO, "select count(*)::int n from last_locations")).rows[0].n === 0,
        "Beto NO ve la ubicacion por defecto");
  await as(ANA, "update companion_links set can_see_location = true where user_id = $1", [ANA]);
  check((await as(BETO, "select count(*)::int n from last_locations")).rows[0].n === 0,
        "con permiso en el vinculo pero sin activar 'compartir ubicacion', sigue sin verla");
  await as(ANA, "update preferences set share_location_with_companions = true where user_id = $1", [ANA]);
  check((await as(BETO, "select count(*)::int n from last_locations")).rows[0].n === 1,
        "con ambos permisos, Beto ve la ubicacion de Ana");
  const betoEdit = await as(BETO, "update companion_links set can_see_alerts = false where user_id = $1 returning id", [ANA]);
  check(betoEdit.rows.length === 0, "Beto no puede cambiar sus propios permisos");
  check((await as(CARLA, "update preferences set memory_enabled = false where user_id = $1 returning user_id", [ANA])).rows.length === 0,
        "Carla no puede cambiar las preferencias de Ana");

  console.log("\nDatos de entrenamiento (con consentimiento)");
  check(await fails(ANA, "insert into training_uploads (user_id, kind, label, source, storage_path) values ($1, 'foto', 'puerta', 'celular', 'x')", [ANA]) !== null,
        "sin consentimiento no puede subir");
  check(await fails(ANA, "insert into storage.objects (bucket_id, name) values ('datos-entrenamiento', $1)", [`${ANA}/foto.jpg`]) !== null,
        "sin consentimiento tampoco puede subir archivos");
  await as(ANA, "update preferences set training_data_consent = true where user_id = $1", [ANA]);
  await as(ANA, "insert into training_uploads (user_id, kind, label, source, storage_path) values ($1, 'foto', 'puerta', 'celular', 'x')", [ANA]);
  await as(ANA, "insert into storage.objects (bucket_id, name) values ('datos-entrenamiento', $1)", [`${ANA}/foto.jpg`]);
  check(true, "con consentimiento sube registro y archivo en su carpeta");
  check(await fails(ANA, "insert into storage.objects (bucket_id, name) values ('datos-entrenamiento', $1)", [`${CARLA}/foto.jpg`]) !== null,
        "no puede subir archivos a la carpeta de otra persona");

  console.log("\nDerecho a olvidar y retencion");
  await as("service", `insert into daily_diaries (user_id, day, summary_md) values ($1, '2026-11-01', '# Sabado')`, [ANA]);
  check((await as(CARLA, "delete from daily_diaries returning day")).rows.length === 0, "Carla no puede borrar diarios ajenos");
  await as("service", "update messages set created_at = now() - interval '40 days' where content like '%médico%'");
  await db.exec("select public.purge_old_memory()");
  check((await as(ANA, "select count(*)::int n from messages")).rows[0].n === 2, "la purga borra mensajes de mas de 30 dias");
  check((await as(ANA, "delete from messages returning id")).rows.length === 2, "Ana puede borrar toda su memoria");

  console.log(`\n${passed} pruebas OK, ${failures} fallaron`);
  process.exit(failures ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
