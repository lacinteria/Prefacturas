-- Almacenamiento privado de imágenes de referencia para cotizaciones.
-- Ejecutar en el proyecto Supabase de Pruebas desde SQL Editor.

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'cotizaciones-referencias',
  'cotizaciones-referencias',
  false,
  5242880,
  array['image/jpeg']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "cotizaciones_referencias_insert" on storage.objects;
create policy "cotizaciones_referencias_insert"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'cotizaciones-referencias'
  and (select public.mi_rol()) in ('admin', 'asesor')
  and split_part(name, '/', 2) = (select auth.uid())::text
);

drop policy if exists "cotizaciones_referencias_select_autorizadas" on storage.objects;
create policy "cotizaciones_referencias_select_autorizadas"
on storage.objects for select to authenticated
using (
  bucket_id = 'cotizaciones-referencias'
  and exists (
    select 1
    from public.remisiones r
    where r.id_documento = split_part(name, '/', 1)
      and r.tipo_doc = 'Cotización'
      and (
        (select public.mi_rol()) = 'admin'
        or ((select public.mi_rol()) = 'asesor' and r.asesor = (select public.mi_nombre()))
        or ((select public.mi_rol()) = 'caja' and r.area = (select public.mi_area()))
      )
  )
);

drop policy if exists "cotizaciones_referencias_delete_propias_o_admin" on storage.objects;
create policy "cotizaciones_referencias_delete_propias_o_admin"
on storage.objects for delete to authenticated
using (
  bucket_id = 'cotizaciones-referencias'
  and (
    (select public.mi_rol()) = 'admin'
    or split_part(name, '/', 2) = (select auth.uid())::text
  )
);
