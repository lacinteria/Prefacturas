-- En Authentication > Users crea el usuario inicial de Pruebas.
-- Puedes asignarle la contraseña actual del administrador. El correo solo es
-- un identificador interno de Supabase; el inicio de sesión seguirá usando usuario.
-- Reemplaza los valores REEMPLAZAR_* antes de ejecutar este script.
insert into public.perfiles (
  id,
  usuario,
  nombre,
  rol,
  area,
  activo,
  presupuesto_mensual,
  email
)
select
  u.id,
  'REEMPLAZAR_USUARIO_ACTUAL',
  'REEMPLAZAR_NOMBRE_ACTUAL',
  'admin',
  'REEMPLAZAR_AREA_ACTUAL',
  true,
  0,
  u.email
from auth.users as u
where lower(u.email) = lower('REEMPLAZAR_CORREO_DE_AUTH')
on conflict (id) do update set
  usuario = excluded.usuario,
  nombre = excluded.nombre,
  rol = excluded.rol,
  area = excluded.area,
  activo = true,
  email = excluded.email;
