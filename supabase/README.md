# Migración de pruebas a Supabase

La página `Remisionario-Pruebas.html` se conecta al proyecto Supabase `Pruebas_Remisionario`. `index.html` permanece en Firebase. En el navegador solo se usa la clave pública `publishable`; nunca debe añadirse una clave `secret` o `service_role`.

## Estado

- `migrations/001_initial_schema.sql`: esquema y políticas base. Ya fue ejecutado en el proyecto de pruebas.
- `migrations/002_auth_email.sql`: aplicada en Pruebas; añade correo al perfil y refuerza permisos de usuarios y Caja.
- `migrations/003_registrar_abono.sql`: aplicada en Pruebas; registra abonos y actualiza el saldo en una transacción; activa eventos en tiempo real para Caja.
- `migrations/004_imagenes_cotizaciones.sql`: crea el bucket privado y las políticas para cargar y consultar imágenes de referencia de cotizaciones. Debe ejecutarse en SQL Editor del proyecto de Pruebas antes de guardar cotizaciones con imágenes.
- La app ahora inicia sesión con Supabase Auth y luego consulta `perfiles` para conocer el rol y área.
- `functions/admin-users/index.ts`: contiene las acciones de autenticación, administración e importación en lote. La versión publicada debe incluir las acciones `login`, `request-password-reset` y `migrate-firebase-users`.

## Migración de usuarios actuales

La pantalla Gestión Usuarios de `Remisionario-Pruebas.html` incluye **Importar usuarios actuales**. Un administrador activo de Supabase puede copiar desde la colección `usuarios` de Firebase los nombres de usuario, contraseñas actuales, nombres, roles, áreas y presupuestos. La importación no escribe ni elimina nada en Firebase. Las contraseñas viajan por HTTPS a la función privada y se guardan únicamente en Supabase Auth, nunca en `perfiles` ni en el navegador. El inicio de sesión admite el usuario o el correo asociado al perfil.

Antes de usarla:

El administrador inicial ya está vinculado y activo en Supabase con el usuario `trabajosdhr`. No es necesario volver a crear esa cuenta ni ejecutar `setup_first_admin.sql`.

1. Abrir `Remisionario-Pruebas.html` e iniciar sesión con la cuenta administrativa inicial `trabajosdhr`. Si no se conoce su contraseña, usar **Olvidé mi contraseña**; el proyecto Supabase debe tener la URL pública de Pruebas como **Site URL** o como URL permitida de redirección.
2. Abrir **Gestión Usuarios** y pulsar **Importar usuarios actuales** una sola vez.
3. La importación crea las cuentas que faltan y sincroniza las ya existentes (incluida la contraseña de Firebase), para que todos puedan seguir ingresando con las credenciales actuales. Las filas inválidas se muestran para revisión. No volver a importar después de cambios manuales de contraseña porque se restauraría la contraseña que figura en Firebase.

Si el usuario legado no tenía correo, la función le asigna un correo interno `@remisionario.app`, que solo sirve como identificador de Supabase; las personas siguen entrando con su nombre de usuario y contraseña de siempre.

La carpeta `supabase/` contiene la implementación para Pruebas. `index.html` sigue usando Firebase y no se modifica en esta etapa. Cuando Pruebas esté migrado y validado por los usuarios, el cambio de autenticación se podrá trasladar a `index.html` como una etapa independiente.

## Imágenes de referencia de cotizaciones

El formulario admite hasta cuatro imágenes. Las reduce a un máximo de 1600 px y las guarda como JPEG en el bucket privado `cotizaciones-referencias`; la cotización guarda solo sus rutas y nombres. Las imágenes se muestran en el detalle y en la impresión. Ejecuta `migrations/004_imagenes_cotizaciones.sql` en SQL Editor de Pruebas una sola vez para crear el bucket y sus políticas privadas. Admin y asesores pueden cargar; admin, Caja y el asesor asignado pueden ver según los permisos de la cotización.

## Conversión de datos

Las tablas guardan campos consultables en columnas e incluyen `datos` (`jsonb`) para conservar el documento original. Antes de importar, normalizar `fecha` como `YYYY-MM-DD`, valores monetarios como número y mapear `area`, `asesor`, `estado`, `tipoDoc` y `formaPago` a las columnas correspondientes. Preservar los IDs de documentos. Precargar el máximo `consecutivo` por tipo en `consecutivos.siguiente`.
