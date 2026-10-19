import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply({ error: "Método no permitido." }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !serviceKey || !anonKey) return reply({ error: "Falta configurar el acceso seguro del servicio." }, 500);

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return reply({ error: "La solicitud no contiene datos válidos." }, 400);
  }

  const action = String(body.action || "");

  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Recuperación para cuentas creadas en lote, que pueden usar un nombre de
  // usuario y no conocen el correo interno asociado en Auth.
  if (action === "request-password-reset") {
    const identifier = String(body.username || "").trim().toLowerCase();
    const redirectTo = String(body.redirectTo || "").trim();
    if (!identifier || !/^https?:\/\//i.test(redirectTo)) {
      return reply({ error: "Escribe tu usuario o correo y abre la aplicación desde su dirección web." }, 400);
    }

    let { data: profile } = await admin
      .from("perfiles")
      .select("email")
      .ilike("usuario", identifier)
      .maybeSingle();
    if (!profile && identifier.includes("@")) {
      const { data: profileByEmail } = await admin
        .from("perfiles")
        .select("email")
        .ilike("email", identifier)
        .maybeSingle();
      profile = profileByEmail;
    }
    if (!profile?.email) return reply({ ok: true });

    const authClient = createClient(url, anonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { error } = await authClient.auth.resetPasswordForEmail(profile.email, { redirectTo });
    if (error) {
      console.error("No se pudo generar la recuperación de contraseña:", error.message);
      return reply({ error: "Supabase rechazó la dirección de retorno. Revisa Authentication > URL Configuration y agrega la dirección pública de Pruebas." }, 400);
    }
    return reply({ ok: true });
  }

  // El acceso habitual se escribe con nombre de usuario. Resolvemos el correo
  // internamente y dejamos que Supabase Auth valide la contraseña.
  if (action === "login") {
    const username = String(body.username || "").trim().toLowerCase();
    const password = String(body.password || "");
    if (!username || !password) return reply({ error: "Usuario o contraseña incorrectos." }, 401);

    let { data: profile } = await admin
      .from("perfiles")
      .select("email, activo")
      .ilike("usuario", username)
      .maybeSingle();
    if (!profile && username.includes("@")) {
      const { data: profileByEmail } = await admin
        .from("perfiles")
        .select("email, activo")
        .ilike("email", username)
        .maybeSingle();
      profile = profileByEmail;
    }
    if (!profile?.email || profile.activo !== true) {
      return reply({ error: "Usuario o contraseña incorrectos." }, 401);
    }

    const authClient = createClient(url, anonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data, error } = await authClient.auth.signInWithPassword({
      email: profile.email,
      password,
    });
    if (error || !data.session) return reply({ error: "Usuario o contraseña incorrectos." }, 401);
    return reply({ session: data.session, user: data.user });
  }

  const authorization = request.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) return reply({ error: "Inicia sesión para continuar." }, 401);

  const { data: authData, error: authError } = await admin.auth.getUser(token);
  if (authError || !authData.user) return reply({ error: "La sesión no es válida. Vuelve a iniciar sesión." }, 401);

  const { data: caller, error: profileError } = await admin
    .from("perfiles")
    .select("rol, activo")
    .eq("id", authData.user.id)
    .maybeSingle();
  if (profileError || caller?.rol !== "admin" || caller.activo !== true) {
    return reply({ error: "Solo un administrador activo puede gestionar usuarios." }, 403);
  }

  if (action === "migrate-firebase-users") {
    const users = Array.isArray(body.users) ? body.users as Record<string, unknown>[] : [];
    if (!users.length || users.length > 250) {
      return reply({ error: "La lista debe incluir entre 1 y 250 usuarios." }, 400);
    }

    let created = 0;
    let updated = 0;
    let skipped = 0;
    const errors: { username: string; reason: string }[] = [];
    const slug = (value: string) => value.toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "usuario";

    for (const legacy of users) {
      const username = String(legacy.username || legacy.usuario || "").trim().toLowerCase();
      const nombre = String(legacy.nombre || legacy.name || username).trim();
      const oldId = String(legacy.id || "").trim();
      const password = String(legacy.pass ?? legacy.password ?? "");
      const roleValue = String(legacy.role || legacy.rol || "").trim().toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
      const role = roleValue === "admin" || roleValue === "administrador" ? "admin"
        : roleValue === "caja" ? "caja"
        : roleValue === "asesor" || roleValue === "vendedor" ? "asesor" : "";
      const area = String(legacy.area || "General").trim() || "General";
      const budget = Number(legacy.presupuestoMensual ?? legacy.presupuesto_mensual ?? 0);

      if (!username || !oldId || !nombre || !role || !Number.isFinite(budget) || budget < 0) {
        errors.push({ username: username || oldId || "(sin usuario)", reason: "Faltan datos válidos de usuario, nombre, rol o presupuesto." });
        continue;
      }
      if (password.length < 6) {
        errors.push({ username, reason: "La contraseña actual tiene menos de 6 caracteres y Supabase no permite conservarla." });
        continue;
      }

      const { data: existing, error: lookupError } = await admin.from("perfiles").select("id,email").eq("usuario", username).maybeSingle();
      if (lookupError) {
        errors.push({ username, reason: "No se pudo comprobar si la cuenta ya existe." });
        continue;
      }

      const email = String(legacy.email || existing?.email || "").trim().toLowerCase() || `legacy-${slug(username)}-${slug(oldId)}@remisionario.app`;
      if (existing) {
        const { error: authUpdateError } = await admin.auth.admin.updateUserById(existing.id, {
          email,
          email_confirm: true,
          password,
          user_metadata: { username, nombre, legacy_user_id: oldId },
        });
        if (authUpdateError) {
          errors.push({ username, reason: "No se pudo sincronizar la contraseña y el correo de la cuenta existente." });
          continue;
        }
        const { error: profileUpdateError } = await admin.from("perfiles").update({
          usuario: username,
          nombre,
          rol: role,
          area,
          activo: legacy.activo !== false,
          presupuesto_mensual: budget,
          email,
        }).eq("id", existing.id);
        if (profileUpdateError) {
          errors.push({ username, reason: "La contraseña se sincronizó, pero no se pudo actualizar el perfil." });
          continue;
        }
        updated++;
        continue;
      }

      const { data: authUser, error: createError } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { username, nombre, legacy_user_id: oldId },
      });
      if (createError || !authUser.user) {
        errors.push({ username, reason: "Supabase no pudo crear la cuenta. Puede existir un correo duplicado o la contraseña no cumplir los requisitos." });
        continue;
      }

      const { error: insertError } = await admin.from("perfiles").insert({
        id: authUser.user.id,
        usuario: username,
        nombre,
        rol: role,
        area,
        activo: legacy.activo !== false,
        presupuesto_mensual: budget,
        email,
      });
      if (insertError) {
        await admin.auth.admin.deleteUser(authUser.user.id);
        errors.push({ username, reason: "No se pudo guardar el perfil; la cuenta parcial fue retirada." });
        continue;
      }
      created++;
    }

    return reply({ created, updated, skipped, errors });
  }

  const role = String(body.role || "");
  const allowedRoles = new Set(["admin", "asesor", "caja"]);

  if (action === "delete") {
    const userId = String(body.id || "");
    if (!userId) return reply({ error: "Falta identificar el usuario." }, 400);
    if (userId === authData.user.id) return reply({ error: "No puedes eliminar tu propio acceso." }, 400);
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) return reply({ error: error.message }, 400);
    return reply({ ok: true });
  }

  const email = String(body.email || "").trim().toLowerCase();
  const username = String(body.username || "").trim().toLowerCase();
  const nombre = String(body.nombre || "").trim();
  const area = String(body.area || "").trim();
  const presupuesto = Number(body.presupuestoMensual || 0);
  const password = String(body.password || "");

  if (!email || !username || !nombre || !area || !allowedRoles.has(role)) {
    return reply({ error: "Completa nombre, usuario, correo, rol y área." }, 400);
  }
  if (!Number.isFinite(presupuesto) || presupuesto < 0) {
    return reply({ error: "El presupuesto mensual no es válido." }, 400);
  }

  if (action === "create") {
    if (password.length < 8) return reply({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);
    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { username, nombre },
    });
    if (error || !data.user) return reply({ error: error?.message || "No se pudo crear la cuenta." }, 400);

    const { error: insertError } = await admin.from("perfiles").insert({
      id: data.user.id,
      usuario: username,
      nombre,
      rol: role,
      area,
      activo: true,
      presupuesto_mensual: presupuesto,
      email,
    });
    if (insertError) {
      await admin.auth.admin.deleteUser(data.user.id);
      return reply({ error: insertError.message }, 400);
    }
    return reply({ ok: true, id: data.user.id });
  }

  if (action === "update") {
    const userId = String(body.id || "");
    if (!userId) return reply({ error: "Falta identificar el usuario." }, 400);
    const { data: duplicate, error: duplicateError } = await admin
      .from("perfiles")
      .select("id")
      .ilike("email", email)
      .neq("id", userId)
      .maybeSingle();
    if (duplicateError) return reply({ error: duplicateError.message }, 500);
    if (duplicate) return reply({ error: "Ese correo ya está asignado a otro usuario." }, 400);
    const authUpdates: { email: string; email_confirm: boolean; password?: string } = {
      email,
      email_confirm: true,
    };
    if (password) {
      if (password.length < 8) return reply({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);
      authUpdates.password = password;
    }
    const { error: updateAuthError } = await admin.auth.admin.updateUserById(userId, authUpdates);
    if (updateAuthError) return reply({ error: updateAuthError.message }, 400);

    const { error: updateProfileError } = await admin.from("perfiles").update({
      usuario: username,
      nombre,
      rol: role,
      area,
      presupuesto_mensual: presupuesto,
      email,
    }).eq("id", userId);
    if (updateProfileError) return reply({ error: updateProfileError.message }, 400);
    return reply({ ok: true, id: userId });
  }

  return reply({ error: "Acción de usuario no reconocida." }, 400);
});
