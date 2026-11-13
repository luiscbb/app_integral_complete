import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

class HttpError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

function createTemporaryPassword(): string {
  const alphabet =
    'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%';
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}

function validEmail(value: unknown): value is string {
  return typeof value === 'string' &&
    /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim());
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (request.method !== 'POST') {
    return json({ error: 'Método no permitido.' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const authorization = request.headers.get('Authorization');
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !authorization) {
    return json({ error: 'Configuración de autenticación incompleta.' }, 500);
  }

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const { data: callerData, error: callerError } =
      await callerClient.auth.getUser();
    const caller = callerData.user;
    if (callerError || !caller) {
      return json({ error: 'La sesión no es válida.' }, 401);
    }

    const body = await request.json();
    const action = body.action as string | undefined;

    if (action === 'finish_password_change') {
      const password = body.password;
      if (typeof password !== 'string' || password.length < 8) {
        return json({ error: 'La contraseña debe tener al menos 8 caracteres.' }, 400);
      }

      const { data: player } = await serviceClient
        .from('players')
        .select('id, must_change_password')
        .eq('auth_user_id', caller.id)
        .maybeSingle();
      const { data: membership } = await serviceClient
        .from('business_memberships')
        .select('billar_id, must_change_password, is_active')
        .eq('user_id', caller.id)
        .eq('is_active', true)
        .maybeSingle();

      if (!player && !membership) {
        return json({ error: 'La cuenta no pertenece a un jugador o encargado activo.' }, 403);
      }
      const needsChange = player?.must_change_password ??
        membership?.must_change_password ?? false;
      if (!needsChange) {
        return json({ error: 'La cuenta no requiere cambio de contraseña.' }, 409);
      }

      const { error: updateError } = await serviceClient.auth.admin
        .updateUserById(caller.id, { password });
      if (updateError) throw updateError;

      const result = player
        ? await serviceClient.from('players')
          .update({ must_change_password: false })
          .eq('id', player.id)
        : await serviceClient.from('business_memberships')
          .update({ must_change_password: false })
          .eq('user_id', caller.id)
          .eq('billar_id', membership!.billar_id);
      if (result.error) throw result.error;
      return json({ ok: true });
    }

    if (action === 'expire_player_account') {
      const { data: player, error: lookupError } = await serviceClient
        .from('players')
        .select('id, expires_at, is_active')
        .eq('auth_user_id', caller.id)
        .maybeSingle();
      if (lookupError) throw lookupError;
      if (player?.is_active &&
          player.expires_at &&
          new Date(player.expires_at) <= new Date()) {
        const { error: updateError } = await serviceClient
          .from('players')
          .update({ is_active: false })
          .eq('id', player.id);
        if (updateError) throw updateError;
      }
      return json({ ok: true });
    }

    const billarId = body.billar_id;
    if (typeof billarId !== 'string' || !billarId.trim()) {
      return json({ error: 'Falta el identificador del billar.' }, 400);
    }

    const [{ data: membership }, { data: settings }] = await Promise.all([
      serviceClient
        .from('business_memberships')
        .select('role, is_active')
        .eq('user_id', caller.id)
        .eq('billar_id', billarId)
        .maybeSingle(),
      serviceClient
        .from('billar_settings')
        .select('user_id')
        .eq('user_id', caller.id)
        .eq('billar_id', billarId)
        .maybeSingle(),
    ]);
    const isOwner = settings != null;
    const callerRole = isOwner
      ? 'admin'
      : membership?.is_active
      ? membership.role
      : null;
    if (!callerRole) {
      return json({ error: 'No tienes acceso a este billar.' }, 403);
    }

    const requireStaff = () => {
      if (!['admin', 'manager'].includes(callerRole)) {
        throw new HttpError(
          'Solo el administrador o encargado puede gestionar jugadores.',
          403,
        );
      }
    };
    const requireAdmin = () => {
      if (callerRole !== 'admin') {
        throw new HttpError('Solo el administrador puede gestionar encargados.', 403);
      }
    };

    if (action === 'expire_players') {
      requireStaff();
      const { error: expireError } = await serviceClient
        .from('players')
        .update({ is_active: false })
        .eq('billar_id', billarId)
        .eq('is_active', true)
        .is('archived_at', null)
        .lte('expires_at', new Date().toISOString());
      if (expireError) throw expireError;
      return json({ ok: true });
    }

    if (action === 'create_player') {
      requireStaff();
      if (!validEmail(body.email)) {
        return json({ error: 'Ingresa un correo válido para el jugador.' }, 400);
      }
      const name = typeof body.name === 'string' ? body.name.trim() : '';
      const nickname = typeof body.nickname === 'string'
        ? body.nickname.trim()
        : '';
      const phone = typeof body.phone === 'string'
        ? body.phone.replace(/\D/g, '')
        : '';
      const handicap = Number(body.handicap);
      if (!name || name.length > 120 || nickname.length > 60) {
        return json({ error: 'Revisa el nombre y nickname del jugador.' }, 400);
      }
      if (phone.length !== 10) {
        return json({ error: 'Ingresa un teléfono de 10 dígitos.' }, 400);
      }
      if (!Number.isInteger(handicap) || handicap < 1 || handicap > 6) {
        return json({ error: 'El handicap debe estar entre 1 y 6.' }, 400);
      }

      const email = body.email.trim().toLowerCase();
      const temporaryPassword = createTemporaryPassword();
      const { data: authData, error: authError } =
        await serviceClient.auth.admin.createUser({
          email,
          password: temporaryPassword,
          email_confirm: true,
          user_metadata: { full_name: name },
          app_metadata: {
            account_type: 'player',
            billar_id: billarId,
          },
        });
      if (authError || !authData.user) {
        return json({ error: authError?.message ?? 'No se pudo crear la cuenta.' }, 400);
      }

      const { data: player, error: insertError } = await serviceClient
        .from('players')
        .insert({
          billar_id: billarId,
          auth_user_id: authData.user.id,
          email,
          phone: `${phone.slice(0, 3)}-${phone.slice(3, 6)}-${phone.slice(6)}`,
          name,
          nickname,
          avatar: typeof body.avatar_url === 'string' ? body.avatar_url : '',
          avatar_url: typeof body.avatar_url === 'string' ? body.avatar_url : '',
          handicap,
          is_active: true,
          must_change_password: true,
          registered_at: new Date().toISOString(),
          expires_at: new Date(
            new Date().setUTCFullYear(new Date().getUTCFullYear() + 1),
          ).toISOString(),
        })
        .select('*')
        .single();

      if (insertError || !player) {
        await serviceClient.auth.admin.deleteUser(authData.user.id);
        return json({ error: insertError?.message ?? 'No se pudo guardar el jugador.' }, 400);
      }
      return json({ player, temporary_password: temporaryPassword });
    }

    if (action === 'update_player') {
      requireStaff();
      const playerId = body.player_id;
      if (typeof playerId !== 'string' || !validEmail(body.email)) {
        return json({ error: 'Los datos del jugador están incompletos.' }, 400);
      }
      const name = typeof body.name === 'string' ? body.name.trim() : '';
      const nickname = typeof body.nickname === 'string'
        ? body.nickname.trim()
        : '';
      const phone = typeof body.phone === 'string'
        ? body.phone.replace(/\D/g, '')
        : '';
      const handicap = Number(body.handicap);
      if (!name || name.length > 120 || nickname.length > 60 ||
          !Number.isInteger(handicap) || handicap < 1 || handicap > 6) {
        return json({ error: 'Revisa los datos del jugador.' }, 400);
      }
      if (phone.length !== 10) {
        return json({ error: 'Ingresa un teléfono de 10 dígitos.' }, 400);
      }

      const { data: player, error: lookupError } = await serviceClient
        .from('players')
        .select('id, auth_user_id, email')
        .eq('id', playerId)
        .eq('billar_id', billarId)
        .maybeSingle();
      if (lookupError) throw lookupError;
      if (!player) return json({ error: 'No se encontró el jugador.' }, 404);
      const email = body.email.trim().toLowerCase();
      let temporaryPassword: string | null = null;
      let authUserId = player.auth_user_id;
      let newlyCreatedUserId: string | null = null;
      if (!authUserId) {
        temporaryPassword = createTemporaryPassword();
        const { data: authData, error: createError } =
          await serviceClient.auth.admin.createUser({
            email,
            password: temporaryPassword,
            email_confirm: true,
            user_metadata: { full_name: name },
            app_metadata: { account_type: 'player', billar_id: billarId },
          });
        if (createError || !authData.user) {
          return json({ error: createError?.message ?? 'No se pudo crear la cuenta.' }, 400);
        }
        authUserId = authData.user.id;
        newlyCreatedUserId = authData.user.id;
      } else if (email !== player.email?.toLowerCase()) {
        const { error: emailError } = await serviceClient.auth.admin
          .updateUserById(authUserId, {
            email,
            email_confirm: true,
            user_metadata: { full_name: name },
          });
        if (emailError) return json({ error: emailError.message }, 400);
      }

      const { data: updated, error: updateError } = await serviceClient
        .from('players')
        .update({
          email,
          phone: `${phone.slice(0, 3)}-${phone.slice(3, 6)}-${phone.slice(6)}`,
          auth_user_id: authUserId,
          name,
          nickname,
          avatar: typeof body.avatar_url === 'string' ? body.avatar_url : '',
          avatar_url: typeof body.avatar_url === 'string' ? body.avatar_url : '',
          handicap,
          must_change_password: temporaryPassword != null
            ? true
            : undefined,
        })
        .eq('id', playerId)
        .eq('billar_id', billarId)
        .select('*')
        .single();
      if (updateError) {
        if (newlyCreatedUserId) {
          await serviceClient.auth.admin.deleteUser(newlyCreatedUserId);
        }
        throw updateError;
      }
      return json({
        player: updated,
        ...(temporaryPassword ? { temporary_password: temporaryPassword } : {}),
      });
    }

    if (action === 'reset_player_password') {
      requireStaff();
      const playerId = body.player_id;
      const { data: player, error } = await serviceClient
        .from('players')
        .select('id, auth_user_id')
        .eq('id', playerId)
        .eq('billar_id', billarId)
        .maybeSingle();
      if (error) throw error;
      if (!player?.auth_user_id) {
        return json({ error: 'El jugador no tiene cuenta de acceso.' }, 404);
      }
      const temporaryPassword = createTemporaryPassword();
      const { error: resetError } = await serviceClient.auth.admin
        .updateUserById(player.auth_user_id, { password: temporaryPassword });
      if (resetError) throw resetError;
      const { error: flagError } = await serviceClient
        .from('players')
        .update({ must_change_password: true })
        .eq('id', playerId);
      if (flagError) throw flagError;
      return json({ temporary_password: temporaryPassword });
    }

    if (action === 'renew_player') {
      requireStaff();
      const playerId = body.player_id;
      const { data: player, error: lookupError } = await serviceClient
        .from('players')
        .select('id, expires_at')
        .eq('id', playerId)
        .eq('billar_id', billarId)
        .maybeSingle();
      if (lookupError) throw lookupError;
      if (!player) return json({ error: 'No se encontró el jugador.' }, 404);
      const now = new Date();
      const previousExpiry = player.expires_at
        ? new Date(player.expires_at)
        : now;
      const renewalBase = previousExpiry > now ? previousExpiry : now;
      renewalBase.setUTCFullYear(renewalBase.getUTCFullYear() + 1);
      const { data: updated, error: updateError } = await serviceClient
        .from('players')
        .update({
          expires_at: renewalBase.toISOString(),
          is_active: true,
          archived_at: null,
        })
        .eq('id', playerId)
        .eq('billar_id', billarId)
        .select('*')
        .single();
      if (updateError) throw updateError;
      return json({ player: updated });
    }

    if (action === 'archive_player') {
      requireStaff();
      const playerId = body.player_id;
      const { data: updated, error } = await serviceClient
        .from('players')
        .update({ is_active: false, archived_at: new Date().toISOString() })
        .eq('id', playerId)
        .eq('billar_id', billarId)
        .select('*')
        .maybeSingle();
      if (error) throw error;
      if (!updated) return json({ error: 'No se encontró el jugador.' }, 404);
      return json({ player: updated });
    }

    if (action === 'create_manager') {
      requireAdmin();
      if (!validEmail(body.email)) {
        return json({ error: 'Ingresa un correo válido para el encargado.' }, 400);
      }
      const email = body.email.trim().toLowerCase();
      const displayName = typeof body.name === 'string' ? body.name.trim() : '';
      if (!displayName || displayName.length > 120) {
        return json({ error: 'Ingresa el nombre del encargado.' }, 400);
      }
      const temporaryPassword = createTemporaryPassword();
      const { data: authData, error: authError } =
        await serviceClient.auth.admin.createUser({
          email,
          password: temporaryPassword,
          email_confirm: true,
          user_metadata: { full_name: displayName },
          app_metadata: { account_type: 'manager', billar_id: billarId },
        });
      if (authError || !authData.user) {
        return json({ error: authError?.message ?? 'No se pudo crear la cuenta.' }, 400);
      }
      const { error: metadataError } = await serviceClient.auth.admin
        .updateUserById(authData.user.id, {
          app_metadata: {
            account_type: 'manager',
            billar_id: billarId,
            must_change_password: true,
          },
        });
      if (metadataError) {
        await serviceClient.auth.admin.deleteUser(authData.user.id);
        throw metadataError;
      }

      const { data: manager, error: insertError } = await serviceClient
        .from('business_memberships')
        .insert({
          user_id: authData.user.id,
          billar_id: billarId,
          email,
          role: 'manager',
          is_active: true,
          must_change_password: true,
          created_by: caller.id,
        })
        .select('user_id, billar_id, email, role, is_active')
        .single();
      if (insertError || !manager) {
        await serviceClient.auth.admin.deleteUser(authData.user.id);
        return json({ error: insertError?.message ?? 'No se pudo guardar el encargado.' }, 400);
      }
      return json({ manager, temporary_password: temporaryPassword });
    }

    if (action === 'reset_manager_password') {
      requireAdmin();
      const managerId = body.user_id;
      const { data: manager, error } = await serviceClient
        .from('business_memberships')
        .select('user_id')
        .eq('user_id', managerId)
        .eq('billar_id', billarId)
        .eq('role', 'manager')
        .maybeSingle();
      if (error) throw error;
      if (!manager) return json({ error: 'No se encontró el encargado.' }, 404);
      const temporaryPassword = createTemporaryPassword();
      const { error: resetError } = await serviceClient.auth.admin
        .updateUserById(managerId, { password: temporaryPassword });
      if (resetError) throw resetError;
      const { error: flagError } = await serviceClient
        .from('business_memberships')
        .update({ must_change_password: true })
        .eq('user_id', managerId)
        .eq('billar_id', billarId);
      if (flagError) throw flagError;
      return json({ temporary_password: temporaryPassword });
    }

    if (action === 'set_manager_active') {
      requireAdmin();
      const managerId = body.user_id;
      if (managerId === caller.id) {
        return json({ error: 'No puedes desactivar tu propia cuenta.' }, 400);
      }
      const { data: updated, error } = await serviceClient
        .from('business_memberships')
        .update({ is_active: body.is_active === true })
        .eq('user_id', managerId)
        .eq('billar_id', billarId)
        .eq('role', 'manager')
        .select('user_id, billar_id, email, role, is_active')
        .maybeSingle();
      if (error) throw error;
      if (!updated) return json({ error: 'No se encontró el encargado.' }, 404);
      return json({ manager: updated });
    }

    return json({ error: 'Acción desconocida.' }, 400);
  } catch (error) {
    console.error('[player-admin] request failed:', error);
    return json({
      error: error instanceof Error ? error.message : 'Error interno al procesar la solicitud.',
    }, error instanceof HttpError ? error.status : 500);
  }
});
