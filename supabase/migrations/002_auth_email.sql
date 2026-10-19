-- Supabase Auth administra contraseñas. El perfil solo guarda datos de la app.
alter table public.perfiles add column if not exists email text;
create unique index if not exists perfiles_email_idx on public.perfiles (lower(email)) where email is not null;

-- El correo se deriva de auth.users para que no haya que duplicarlo al crear perfiles.
create or replace function public.mi_email()
returns text language sql stable security definer set search_path = '' as $$
  select u.email from auth.users u where u.id = (select auth.uid())
$$;

revoke all on function public.mi_email() from public;
grant execute on function public.mi_email() to authenticated;

-- La rutina base se refuerza para rechazar sesiones autenticadas sin perfil activo.
create or replace function public.reservar_consecutivo(p_tipo_doc text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_siguiente bigint;
begin
  if coalesce(public.mi_rol(),'') not in ('admin','asesor') then
    raise exception 'No autorizado para reservar consecutivos';
  end if;
  insert into public.consecutivos as c (tipo_doc,siguiente)
  values (p_tipo_doc,2)
  on conflict (tipo_doc) do update set siguiente=c.siguiente+1
  returning siguiente-1 into v_siguiente;
  return v_siguiente;
end;
$$;

-- Caja conserva el permiso de marcar pagos; solo el RPC de abonos puede modificar otros campos.
create or replace function public.proteger_cambios_caja()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.mi_rol() = 'caja'
     and coalesce(pg_catalog.current_setting('app.registrar_abono',true),'') <> 'on'
     and ((to_jsonb(new) - 'estado' - 'updated_at' - 'datos') ||
          jsonb_build_object('datos',coalesce(new.datos,'{}'::jsonb) - 'estado')) is distinct from
         ((to_jsonb(old) - 'estado' - 'updated_at' - 'datos') ||
          jsonb_build_object('datos',coalesce(old.datos,'{}'::jsonb) - 'estado')) then
    raise exception 'Caja solo puede actualizar el estado del documento';
  end if;
  return new;
end;
$$;
