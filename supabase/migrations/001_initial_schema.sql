-- Esquema inicial aislado para validar Remisionario con Supabase/Postgres.
-- No contiene llaves de servicio ni modifica Firebase.

create table if not exists public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  usuario text not null unique,
  nombre text not null,
  rol text not null check (rol in ('admin', 'asesor', 'caja')),
  area text not null default '',
  activo boolean not null default true,
  presupuesto_mensual numeric(14,2) not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.clientes (
  documento text primary key,
  nombre text not null default '',
  telefono text not null default '',
  total_compras numeric(14,2) not null default 0,
  total_invertido numeric(14,2) not null default 0,
  fecha_registro timestamptz,
  ultima_actualizacion timestamptz,
  datos jsonb not null default '{}'::jsonb
);

create table if not exists public.remisiones (
  id_documento text primary key,
  consecutivo bigint not null,
  tipo_doc text not null,
  fecha date not null,
  fecha_creacion timestamptz,
  asesor text not null default '',
  area text not null default '',
  estado text not null default '',
  forma_pago text not null default '',
  documento_cliente text not null default '',
  total numeric(14,2) not null default 0,
  datos jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.abonos_cotizaciones (
  id uuid primary key default gen_random_uuid(),
  id_documento text not null references public.remisiones(id_documento),
  fecha date not null,
  asesor text not null default '',
  area text not null default '',
  forma_pago text not null default '',
  valor numeric(14,2) not null check (valor > 0),
  datos jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.configuracion_empresa (
  id text primary key default 'empresa' check (id = 'empresa'),
  nombre text not null default 'Remisionario y Facturación',
  logo text not null default '',
  codigo_anulacion text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.consecutivos (
  tipo_doc text primary key,
  siguiente bigint not null check (siguiente > 0)
);

-- Índices alineados con las pantallas de reportes, Caja y cotizaciones activas.
create index if not exists remisiones_fecha_idx on public.remisiones (fecha desc);
create index if not exists remisiones_area_fecha_idx on public.remisiones (area, fecha desc);
create index if not exists remisiones_asesor_fecha_idx on public.remisiones (asesor, fecha desc);
create index if not exists remisiones_tipo_estado_idx on public.remisiones (tipo_doc, estado);
create index if not exists remisiones_tipo_consecutivo_idx on public.remisiones (tipo_doc, consecutivo desc);
create index if not exists remisiones_cliente_fecha_idx on public.remisiones (documento_cliente, fecha desc);
create index if not exists abonos_fecha_idx on public.abonos_cotizaciones (fecha desc);
create index if not exists abonos_area_fecha_idx on public.abonos_cotizaciones (area, fecha desc);
create index if not exists abonos_asesor_fecha_idx on public.abonos_cotizaciones (asesor, fecha desc);
create index if not exists abonos_documento_fecha_idx on public.abonos_cotizaciones (id_documento, fecha);

-- Funciones SECURITY DEFINER para consultar permisos sin abrir perfiles a todos.
create or replace function public.mi_rol()
returns text language sql stable security definer set search_path = '' as $$
  select p.rol from public.perfiles p where p.id = (select auth.uid()) and p.activo
$$;

create or replace function public.mi_area()
returns text language sql stable security definer set search_path = '' as $$
  select p.area from public.perfiles p where p.id = (select auth.uid()) and p.activo
$$;

create or replace function public.mi_nombre()
returns text language sql stable security definer set search_path = '' as $$
  select p.nombre from public.perfiles p where p.id = (select auth.uid()) and p.activo
$$;

revoke all on function public.mi_rol() from public;
revoke all on function public.mi_area() from public;
revoke all on function public.mi_nombre() from public;
grant execute on function public.mi_rol(), public.mi_area(), public.mi_nombre() to authenticated;

alter table public.perfiles enable row level security;
alter table public.clientes enable row level security;
alter table public.remisiones enable row level security;
alter table public.abonos_cotizaciones enable row level security;
alter table public.configuracion_empresa enable row level security;
alter table public.consecutivos enable row level security;

create policy perfiles_leer_propios_o_admin on public.perfiles for select to authenticated
  using (id = (select auth.uid()) or (select public.mi_rol()) = 'admin');
create policy perfiles_admin_escribir on public.perfiles for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

create policy clientes_leer on public.clientes for select to authenticated
  using ((select public.mi_rol()) in ('admin', 'asesor', 'caja'));
create policy clientes_insertar on public.clientes for insert to authenticated
  with check ((select public.mi_rol()) in ('admin', 'asesor'));
create policy clientes_actualizar on public.clientes for update to authenticated
  using ((select public.mi_rol()) in ('admin', 'asesor'))
  with check ((select public.mi_rol()) in ('admin', 'asesor'));

create policy remisiones_leer on public.remisiones for select to authenticated
  using (
    (select public.mi_rol()) = 'admin'
    or ((select public.mi_rol()) = 'asesor' and asesor = (select public.mi_nombre()))
    or ((select public.mi_rol()) = 'caja' and area = (select public.mi_area()))
  );
create policy remisiones_insertar on public.remisiones for insert to authenticated
  with check (
    (select public.mi_rol()) = 'admin'
    or ((select public.mi_rol()) = 'asesor' and asesor = (select public.mi_nombre()))
  );
create policy remisiones_actualizar on public.remisiones for update to authenticated
  using (
    (select public.mi_rol()) = 'admin'
    or ((select public.mi_rol()) = 'asesor' and asesor = (select public.mi_nombre()))
    or ((select public.mi_rol()) = 'caja' and area = (select public.mi_area()))
  )
  with check (
    (select public.mi_rol()) = 'admin'
    or ((select public.mi_rol()) = 'asesor' and asesor = (select public.mi_nombre()))
    or ((select public.mi_rol()) = 'caja' and area = (select public.mi_area()))
  );
create policy remisiones_admin_borrar on public.remisiones for delete to authenticated
  using ((select public.mi_rol()) = 'admin');

-- Caja solo puede cambiar el estado del documento; los demás campos quedan protegidos.
create or replace function public.proteger_cambios_caja()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select public.mi_rol()) = 'caja'
     and (to_jsonb(new) - 'estado' - 'updated_at') is distinct from
         (to_jsonb(old) - 'estado' - 'updated_at') then
    raise exception 'Caja solo puede actualizar el estado del documento';
  end if;
  return new;
end;
$$;

create trigger remisiones_proteger_caja
before update on public.remisiones
for each row execute function public.proteger_cambios_caja();

create policy abonos_leer on public.abonos_cotizaciones for select to authenticated
  using (
    (select public.mi_rol()) = 'admin'
    or ((select public.mi_rol()) = 'asesor' and asesor = (select public.mi_nombre()))
    or ((select public.mi_rol()) = 'caja' and area = (select public.mi_area()))
  );
create policy abonos_admin_asesor_escribir on public.abonos_cotizaciones for insert to authenticated
  with check (
    (select public.mi_rol()) = 'admin'
    or ((select public.mi_rol()) = 'asesor' and asesor = (select public.mi_nombre()))
  );

create policy config_leer_autenticados on public.configuracion_empresa for select to authenticated
  using ((select public.mi_rol()) in ('admin', 'asesor', 'caja'));
create policy config_admin_escribir on public.configuracion_empresa for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');

create policy consecutivos_leer on public.consecutivos for select to authenticated
  using ((select public.mi_rol()) in ('admin', 'asesor'));

-- Reserva atómica de consecutivos; evita leer la colección buscando el máximo.
create or replace function public.reservar_consecutivo(p_tipo_doc text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_siguiente bigint;
begin
  if (select public.mi_rol()) not in ('admin', 'asesor') then
    raise exception 'No autorizado para reservar consecutivos';
  end if;

  insert into public.consecutivos as c (tipo_doc, siguiente)
  values (p_tipo_doc, 2)
  on conflict (tipo_doc) do update set siguiente = c.siguiente + 1
  returning siguiente - 1 into v_siguiente;

  return v_siguiente;
end;
$$;

revoke all on function public.reservar_consecutivo(text) from public;
grant execute on function public.reservar_consecutivo(text) to authenticated;

grant select, insert, update on public.clientes to authenticated;
grant select, insert, update, delete on public.remisiones to authenticated;
grant select, insert on public.abonos_cotizaciones to authenticated;
grant select, insert, update, delete on public.perfiles, public.configuracion_empresa to authenticated;
grant select on public.consecutivos to authenticated;

