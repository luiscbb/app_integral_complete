import { parseStaffDraft } from './staff_identity.ts';

type Result = { data: unknown; error: unknown };

export interface PasswordChangeGateway {
  findPlayer(): Promise<Result>;
  findMembership(billarId: string | null): Promise<Result>;
  stopStaffRecovery(): Promise<Result>;
  updatePassword(password: string): Promise<{ error: unknown }>;
  completeStaff(billarId: string, revision: number): Promise<Result>;
  completePlayer(playerId: string | number): Promise<Result>;
  completeLegacyMembership(billarId: string): Promise<Result>;
}

export class PasswordChangeError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export async function finishTemporaryPasswordChange(
  accountType: unknown,
  requestedBillar: unknown,
  password: unknown,
  gateway: PasswordChangeGateway,
): Promise<void> {
  if (typeof password !== 'string' || password.length < 8) {
    throw new PasswordChangeError('La contraseña debe tener al menos 8 caracteres.', 400);
  }
  const staff = accountType === 'staff';
  const billar = typeof requestedBillar === 'string' && requestedBillar.trim()
    ? requestedBillar : null;
  if (staff && billar === null) {
    throw new PasswordChangeError('La cuenta de personal no está vinculada al billar.', 403);
  }

  let player: Record<string, unknown> | null = null;
  if (!staff) {
    const result = await gateway.findPlayer();
    if (result.error || (result.data !== null && !record(result.data))) {
      throw new PasswordChangeError('No se pudo verificar la cuenta del jugador.', 503);
    }
    player = result.data;
  }

  let membership: Record<string, unknown> | null = null;
  if (player === null) {
    const result = await gateway.findMembership(billar);
    if (result.error || (result.data !== null && !record(result.data))) {
      throw new PasswordChangeError('No se pudo verificar la membresía de la cuenta.', 503);
    }
    membership = result.data;
    if (!membership || membership.is_active !== true ||
        typeof membership.billar_id !== 'string' || !membership.billar_id.trim() ||
        (billar !== null && membership.billar_id !== billar) ||
        typeof membership.must_change_password !== 'boolean') {
      throw new PasswordChangeError('La cuenta no tiene una membresía activa válida.', 403);
    }
  } else if ((typeof player.id !== 'string' && typeof player.id !== 'number') ||
      typeof player.must_change_password !== 'boolean') {
    throw new PasswordChangeError('La cuenta del jugador no es válida.', 503);
  }

  if (staff) {
    if (!membership || membership.role !== 'manager' ||
        typeof membership.staff_revision !== 'number' ||
        !Number.isSafeInteger(membership.staff_revision) || membership.staff_revision < 0) {
      throw new PasswordChangeError('La cuenta de personal no es válida.', 403);
    }
    try {
      const parsed = parseStaffDraft({
        username: membership.username, full_name: membership.full_name,
        job_title: membership.job_title, modules: membership.allowed_modules,
      });
      if (parsed.username !== membership.username ||
          !Array.isArray(membership.allowed_modules) ||
          parsed.modules.length !== membership.allowed_modules.length) {
        throw new TypeError('Membresía de personal inválida.');
      }
    } catch (error) {
      if (!(error instanceof TypeError)) throw error;
      throw new PasswordChangeError('La cuenta de personal no es válida.', 403);
    }
  } else if (membership && (membership.username != null ||
      !['admin', 'manager'].includes(String(membership.role)))) {
    throw new PasswordChangeError('El tipo de cuenta no coincide con su membresía.', 403);
  }
  if ((player ?? membership)?.must_change_password !== true) {
    throw new PasswordChangeError('La cuenta no requiere cambio de contraseña.', 409);
  }
  if (staff) {
    const result = await gateway.stopStaffRecovery();
    if (result.error || result.data !== true) {
      throw new PasswordChangeError('No se pudo asegurar el cambio de contraseña. Inténtalo nuevamente.', 503);
    }
  }

  const changed = await gateway.updatePassword(password);
  if (changed.error) {
    throw new PasswordChangeError('No se pudo actualizar la contraseña. Revisa los datos e inténtalo nuevamente.', 503);
  }
  let completed: Result;
  if (player !== null) {
    completed = await gateway.completePlayer(player.id as string | number);
  } else if (staff) {
    completed = await gateway.completeStaff(
      membership!.billar_id as string, membership!.staff_revision as number,
    );
  } else {
    completed = await gateway.completeLegacyMembership(membership!.billar_id as string);
  }
  if (completed.error || (staff ? completed.data !== true : !record(completed.data))) {
    throw new PasswordChangeError(
      'La contraseña pudo cambiar, pero no se pudo confirmar el acceso. Vuelve a verificar la cuenta.',
      503,
    );
  }
}
