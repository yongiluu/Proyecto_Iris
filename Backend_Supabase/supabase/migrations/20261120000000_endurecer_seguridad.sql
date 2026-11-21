-- Endurecimiento tras la auditoria de 2026-11 (no cambia datos; solo reglas y funciones).

-- ─── 1. Un vinculo no se puede "mover" a otra persona ────────────────────────
-- La regla de UPDATE solo revisaba que el vinculo fuera mio: se podia cambiar companion_id al UUID de
-- cualquiera y, con eso, leer su perfil. Ahora solo se cambian los permisos.
create function public.lock_companion_link_parties() returns trigger language plpgsql as $$
begin
  if new.user_id <> old.user_id or new.companion_id <> old.companion_id then
    raise exception 'No se puede cambiar a quien une un vinculo (solo sus permisos)';
  end if;
  return new;
end $$;
create trigger companion_links_lock_parties before update on public.companion_links
  for each row execute function public.lock_companion_link_parties();

-- ─── 2. Las coordenadas de las alertas solo con permiso de ubicacion ─────────
-- Un acompañante con permiso de alertas (activo por defecto) veia lat/lon aunque la persona no compartiera
-- su ubicacion. Las columnas lat/lon ya no se leen directo: se piden con alert_location(), que aplica las
-- mismas reglas que last_locations.
revoke select on public.alerts from anon, authenticated;
grant select (id, user_id, kind, detail, created_at) on public.alerts to authenticated;

create function public.alert_location(alert_id bigint) returns table (lat double precision, lon double precision)
language sql stable security definer set search_path = public as $$
  select a.lat, a.lon from public.alerts a
  where a.id = alert_id
    and (a.user_id = auth.uid()
         or (public.is_companion_of(a.user_id, 'location') and public.shares_location(a.user_id)));
$$;
revoke execute on function public.alert_location(bigint) from public, anon;
grant execute on function public.alert_location(bigint) to authenticated;

-- ─── 3. Funciones security definer que respondian por cualquier persona ──────
-- Se llaman desde las reglas (RLS), asi que deben seguir ejecutables; pero ahora solo dicen la verdad
-- sobre uno mismo o sobre alguien a quien acompaño con ese permiso. Para el resto responden false.
create or replace function public.shares_location(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when target = auth.uid() or public.is_companion_of(target, 'location')
      then coalesce((select share_location_with_companions from public.preferences where user_id = target), false)
    else false
  end;
$$;

create or replace function public.has_training_consent(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when target = auth.uid()
      then coalesce((select training_data_consent from public.preferences where user_id = target), false)
    else false
  end;
$$;

-- conversation_day_for solo la usa el agente (clave de servicio): fuera de la API publica.
revoke execute on function public.conversation_day_for(uuid, timestamptz) from public, anon, authenticated;

-- ─── 4. Codigos de acompañante: azar criptografico y tope de intentos ────────
-- Antes: random() (predecible) y sin limite de intentos: se podia probar codigos hasta acertar y ver
-- las alertas de otra persona. Ahora los codigos salen de gen_random_uuid() (azar del sistema) y cada
-- cuenta tiene 5 intentos fallidos cada 15 minutos.
create or replace function public.create_companion_invite() returns text
language plpgsql security definer set search_path = public as $$
declare
  new_code text;
begin
  if auth.uid() is null then
    raise exception 'Hay que iniciar sesion';
  end if;
  delete from public.companion_invites where user_id = auth.uid() and used_by is null;
  loop
    new_code := lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint)
                      % 1000000)::text, 6, '0');
    begin
      insert into public.companion_invites (code, user_id) values (new_code, auth.uid());
      return new_code;
    exception when unique_violation then
      -- codigo repetido: probar otro
    end;
  end loop;
end $$;

create table public.companion_invite_attempts (
  user_id uuid not null references public.profiles (id) on delete cascade,
  at timestamptz not null default now()
);
create index companion_invite_attempts_idx on public.companion_invite_attempts (user_id, at);
alter table public.companion_invite_attempts enable row level security;  -- sin reglas: nadie lo lee por la API

-- Un codigo equivocado ya no lanza error (el error desharia el registro del intento): devuelve null.
-- La app trata null como "codigo invalido o vencido".
create or replace function public.accept_companion_invite(invite_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  invite public.companion_invites;
begin
  if auth.uid() is null then
    raise exception 'Hay que iniciar sesion';
  end if;
  if (select count(*) from public.companion_invite_attempts
      where user_id = auth.uid() and at > now() - interval '15 minutes') >= 5 then
    raise exception 'Demasiados intentos: espera 15 minutos';
  end if;
  select * into invite from public.companion_invites
  where code = invite_code and used_by is null and expires_at > now()
  for update;
  if not found then
    insert into public.companion_invite_attempts (user_id) values (auth.uid());
    return null;
  end if;
  if invite.user_id = auth.uid() then
    raise exception 'No puedes ser tu propio acompañante';
  end if;
  insert into public.companion_links (user_id, companion_id) values (invite.user_id, auth.uid())
  on conflict (user_id, companion_id) do nothing;
  update public.companion_invites set used_by = auth.uid() where code = invite_code;
  return invite.user_id;
end $$;
