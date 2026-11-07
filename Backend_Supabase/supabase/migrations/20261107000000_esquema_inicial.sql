-- ============================================================================
-- Iris: esquema inicial
-- Personas usuarias, preferencias, acompañantes, memoria diaria, alertas, placas y datos de
-- entrenamiento. Toda tabla tiene Row Level Security: cada persona ve solo lo suyo, y un acompañante
-- solo lo que la persona le permitio (alertas y/o ubicacion).
-- Lo que escribe el agente (mensajes, resumenes, diarios) lo escriben las Edge Functions con la clave
-- de servicio, que se salta RLS; la app solo puede leer y borrar su propia memoria.
-- ============================================================================

-- ─── Perfiles ────────────────────────────────────────────────────────────────
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  role text not null default 'usuario' check (role in ('usuario', 'acompanante')),
  timezone text not null default 'America/Santiago',
  created_at timestamptz not null default now()
);

create table public.preferences (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  voice_rate real not null default 0.5 check (voice_rate between 0.1 and 1.0),
  board_volume int not null default 60 check (board_volume between 5 and 100),
  hardware_mode text not null default 'celular' check (hardware_mode in ('celular', 'placa')),
  answers_on_phone boolean not null default true,
  -- Memoria del agente
  memory_enabled boolean not null default true,
  message_retention_days int not null default 30 check (message_retention_days between 1 and 365),
  diary_retention_days int not null default 365 check (diary_retention_days between 7 and 3650),
  -- Privacidad
  share_location_with_companions boolean not null default false,
  training_data_consent boolean not null default false,
  extra jsonb not null default '{}'::jsonb,  -- ajustes de la app que aun no tienen columna propia
  updated_at timestamptz not null default now()
);

-- Al registrarse alguien (ej. con Google) se crean su perfil y sus preferencias.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'));
  insert into public.preferences (user_id) values (new.id);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger preferences_updated_at
  before update on public.preferences for each row execute function public.touch_updated_at();

-- ─── Acompañantes (familiar, profesional) ────────────────────────────────────
create table public.companion_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,       -- persona asistida
  companion_id uuid not null references public.profiles (id) on delete cascade,  -- acompañante
  can_see_alerts boolean not null default true,
  can_see_location boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, companion_id),
  check (user_id <> companion_id)
);

-- Codigo de 6 digitos que la persona le dicta al acompañante (valido 24 h, un solo uso).
create table public.companion_invites (
  code text primary key check (code ~ '^[0-9]{6}$'),
  user_id uuid not null references public.profiles (id) on delete cascade,
  expires_at timestamptz not null default now() + interval '24 hours',
  used_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

-- ¿auth.uid() es acompañante activo de target con ese permiso? (security definer: evita recursion de RLS)
create function public.is_companion_of(target uuid, permission text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.companion_links l
    where l.user_id = target and l.companion_id = auth.uid()
      and case permission
            when 'alerts' then l.can_see_alerts
            when 'location' then l.can_see_location
            else true
          end
  );
$$;

create function public.create_companion_invite() returns text
language plpgsql security definer set search_path = public as $$
declare
  new_code text;
begin
  if auth.uid() is null then
    raise exception 'Hay que iniciar sesion';
  end if;
  delete from public.companion_invites where user_id = auth.uid() and used_by is null;
  loop
    new_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    begin
      insert into public.companion_invites (code, user_id) values (new_code, auth.uid());
      return new_code;
    exception when unique_violation then
      -- codigo repetido: probar otro
    end;
  end loop;
end $$;

create function public.accept_companion_invite(invite_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  invite public.companion_invites;
begin
  if auth.uid() is null then
    raise exception 'Hay que iniciar sesion';
  end if;
  select * into invite from public.companion_invites
  where code = invite_code and used_by is null and expires_at > now()
  for update;
  if not found then
    raise exception 'Codigo invalido o vencido';
  end if;
  if invite.user_id = auth.uid() then
    raise exception 'No puedes ser tu propio acompañante';
  end if;
  insert into public.companion_links (user_id, companion_id) values (invite.user_id, auth.uid())
  on conflict (user_id, companion_id) do nothing;
  update public.companion_invites set used_by = auth.uid() where code = invite_code;
  return invite.user_id;
end $$;

-- ─── Memoria diaria del agente ───────────────────────────────────────────────
-- Un "dia" de conversacion empieza a las 4:00 hora local: lo que pase de madrugada cuenta como el dia anterior.
create function public.conversation_day_for(target uuid, at_time timestamptz default now()) returns date
language sql stable security definer set search_path = public as $$
  select ((at_time at time zone coalesce((select timezone from public.profiles where id = target), 'America/Santiago'))
          - interval '4 hours')::date;
$$;

create table public.conversation_days (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  day date not null,
  running_summary text not null default '',      -- resumen acumulado del dia (lo actualiza el agente)
  summarized_until bigint not null default 0,    -- id del ultimo mensaje incluido en el resumen
  diary_written boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, day)
);

create table public.messages (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  day_id bigint not null references public.conversation_days (id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null,
  had_image boolean not null default false,
  created_at timestamptz not null default now(),
  search tsvector generated always as (to_tsvector('spanish', content)) stored
);
create index messages_search_idx on public.messages using gin (search);
create index messages_user_time_idx on public.messages (user_id, created_at);
create index messages_day_idx on public.messages (day_id, id);

-- Diario: resumen en markdown de cada dia cerrado ("¿que paso ayer?" lee solo esto).
create table public.daily_diaries (
  user_id uuid not null references public.profiles (id) on delete cascade,
  day date not null,
  summary_md text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);

-- Busqueda en la memoria (la usa la herramienta buscar_en_memoria del agente, con la clave de servicio).
create function public.search_memory(target uuid, query text, since date, max_results int default 8)
returns table (id bigint, day date, role text, content text, created_at timestamptz, rank real)
language sql stable security definer set search_path = public as $$
  select m.id, d.day, m.role, m.content, m.created_at,
         ts_rank(m.search, websearch_to_tsquery('spanish', query)) as rank
  from public.messages m join public.conversation_days d on d.id = m.day_id
  where m.user_id = target and d.day >= since
    and m.search @@ websearch_to_tsquery('spanish', query)
  order by rank desc, m.created_at desc
  limit max_results;
$$;
revoke execute on function public.search_memory(uuid, text, date, int) from public, anon, authenticated;

-- ─── Alertas, ubicacion y placas ─────────────────────────────────────────────
create table public.alerts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null,          -- ej. 'sirena', 'vehiculo', 'emergencia'
  detail text,
  lat double precision,
  lon double precision,
  created_at timestamptz not null default now()
);
create index alerts_user_time_idx on public.alerts (user_id, created_at desc);

-- ¿La persona activo "compartir ubicacion"? (security definer: el acompañante no puede leer sus preferencias)
create function public.shares_location(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select share_location_with_companions from public.preferences where user_id = target), false);
$$;

create table public.last_locations (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  lat double precision not null,
  lon double precision not null,
  accuracy_m real,
  updated_at timestamptz not null default now()
);

create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  ble_name text not null,
  nickname text,
  firmware text,
  last_seen timestamptz not null default now(),
  unique (user_id, ble_name)
);

-- ─── Datos para entrenar los modelos de la placa (solo con consentimiento) ───
create table public.training_uploads (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('audio', 'foto')),
  label text not null,
  environment text,
  source text not null check (source in ('celular', 'placa')),
  storage_path text not null,
  created_at timestamptz not null default now()
);

create function public.has_training_consent(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select training_data_consent from public.preferences where user_id = target), false);
$$;

insert into storage.buckets (id, name, public) values ('datos-entrenamiento', 'datos-entrenamiento', false)
on conflict (id) do nothing;

-- ─── Row Level Security ──────────────────────────────────────────────────────
alter table public.profiles enable row level security;
alter table public.preferences enable row level security;
alter table public.companion_links enable row level security;
alter table public.companion_invites enable row level security;
alter table public.conversation_days enable row level security;
alter table public.messages enable row level security;
alter table public.daily_diaries enable row level security;
alter table public.alerts enable row level security;
alter table public.last_locations enable row level security;
alter table public.devices enable row level security;
alter table public.training_uploads enable row level security;

-- Perfil: el propio, y el nombre de la persona a quien acompaño
create policy "perfil propio" on public.profiles
  for select using (id = auth.uid() or public.is_companion_of(id, 'any')
                    or exists (select 1 from public.companion_links l where l.user_id = auth.uid() and l.companion_id = profiles.id));
create policy "editar perfil propio" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

create policy "preferencias propias" on public.preferences
  for select using (user_id = auth.uid());
create policy "editar preferencias propias" on public.preferences
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Vinculos: los ven ambas partes; la persona asistida cambia permisos o corta el vinculo; el acompañante puede salirse
create policy "ver vinculos" on public.companion_links
  for select using (user_id = auth.uid() or companion_id = auth.uid());
create policy "permisos del vinculo" on public.companion_links
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "cortar vinculo" on public.companion_links
  for delete using (user_id = auth.uid() or companion_id = auth.uid());

create policy "ver mis invitaciones" on public.companion_invites
  for select using (user_id = auth.uid());

-- Memoria: leer y borrar la propia (derecho a olvidar); escribe solo el agente (clave de servicio)
create policy "leer mis dias" on public.conversation_days for select using (user_id = auth.uid());
create policy "borrar mis dias" on public.conversation_days for delete using (user_id = auth.uid());
create policy "leer mis mensajes" on public.messages for select using (user_id = auth.uid());
create policy "borrar mis mensajes" on public.messages for delete using (user_id = auth.uid());
create policy "leer mis diarios" on public.daily_diaries for select using (user_id = auth.uid());
create policy "borrar mis diarios" on public.daily_diaries for delete using (user_id = auth.uid());

-- Alertas: las crea la persona; las ve ella y sus acompañantes con permiso
create policy "crear alerta propia" on public.alerts
  for insert with check (user_id = auth.uid());
create policy "ver alertas" on public.alerts
  for select using (user_id = auth.uid() or public.is_companion_of(user_id, 'alerts'));
create policy "borrar alertas propias" on public.alerts
  for delete using (user_id = auth.uid());

-- Ubicacion: solo si la persona activo compartirla
create policy "guardar ubicacion propia" on public.last_locations
  for insert with check (user_id = auth.uid());
create policy "actualizar ubicacion propia" on public.last_locations
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "ver ubicacion" on public.last_locations
  for select using (
    user_id = auth.uid()
    or (public.is_companion_of(user_id, 'location') and public.shares_location(user_id))
  );
create policy "borrar ubicacion propia" on public.last_locations
  for delete using (user_id = auth.uid());

create policy "mis placas" on public.devices
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "subir datos con consentimiento" on public.training_uploads
  for insert with check (user_id = auth.uid() and public.has_training_consent(auth.uid()));
create policy "ver mis datos subidos" on public.training_uploads
  for select using (user_id = auth.uid());
create policy "borrar mis datos subidos" on public.training_uploads
  for delete using (user_id = auth.uid());

-- Archivos de entrenamiento: carpeta <user_id>/..., solo con consentimiento
create policy "subir archivos de entrenamiento" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'datos-entrenamiento'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.has_training_consent(auth.uid())
  );
create policy "ver mis archivos de entrenamiento" on storage.objects
  for select to authenticated using (
    bucket_id = 'datos-entrenamiento' and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "borrar mis archivos de entrenamiento" on storage.objects
  for delete to authenticated using (
    bucket_id = 'datos-entrenamiento' and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ─── Retencion automatica (privacidad y costo) ───────────────────────────────
create extension if not exists pg_cron;

create function public.purge_old_memory() returns void
language sql security definer set search_path = public as $$
  delete from public.messages m using public.preferences p
  where m.user_id = p.user_id and m.created_at < now() - make_interval(days => p.message_retention_days);

  delete from public.daily_diaries d using public.preferences p
  where d.user_id = p.user_id and d.day < (now() - make_interval(days => p.diary_retention_days))::date;

  delete from public.conversation_days c
  where c.diary_written and c.day < current_date - 2
    and not exists (select 1 from public.messages m where m.day_id = c.id);

  delete from public.companion_invites where expires_at < now() - interval '7 days';
$$;
revoke execute on function public.purge_old_memory() from public, anon, authenticated;

select cron.schedule('iris-purga-memoria', '15 4 * * *', 'select public.purge_old_memory()');
