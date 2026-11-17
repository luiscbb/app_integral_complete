type RemoteError = { code?: string } | null;
type RemoteResult<T> = { data: T | null; error: RemoteError };

export interface StaffCreationGateway {
  reserve(): Promise<RemoteResult<unknown>>;
  findAuthUser(): Promise<RemoteResult<unknown>>;
  createAuthUser(): Promise<RemoteResult<string>>;
  finalize(userId: string): Promise<RemoteResult<unknown>>;
}

export class StaffCreationError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export async function createStaffWithRetry(
  gateway: StaffCreationGateway,
  temporaryPassword: string,
): Promise<Record<string, unknown>> {
  let reservation: RemoteResult<unknown>;
  try {
    reservation = await gateway.reserve();
  } catch {
    throw new StaffCreationError('No se pudo reservar el usuario. Reintenta la misma solicitud.', 503);
  }
  if (reservation.error) {
    if (reservation.error.code === '23505') {
      throw new StaffCreationError('El usuario ya está registrado.', 409);
    }
    if (reservation.error.code === '22023') {
      throw new StaffCreationError('La solicitud no coincide con la original. Solicita asistencia.', 409);
    }
    if (reservation.error.code === '42501') {
      throw new StaffCreationError('Ya no tienes permiso para crear personal.', 403);
    }
    throw new StaffCreationError('No se pudo reservar el usuario. Reintenta la misma solicitud.', 503);
  }
  if (!isRecord(reservation.data) || typeof reservation.data.completed !== 'boolean') {
    throw new StaffCreationError('La respuesta de reserva no es válida.', 503);
  }

  const findAuthUser = async (): Promise<string | null> => {
    let response: RemoteResult<unknown>;
    try {
      response = await gateway.findAuthUser();
    } catch {
      throw new StaffCreationError('No se pudo verificar la cuenta. Reintenta la misma solicitud.', 503);
    }
    if (response.error?.code === '23505') {
      throw new StaffCreationError('El usuario ya está registrado.', 409);
    }
    if (response.error?.code === '42501') {
      throw new StaffCreationError('Ya no tienes permiso para crear personal.', 403);
    }
    if (response.error || (response.data !== null && typeof response.data !== 'string')) {
      throw new StaffCreationError('No se pudo verificar la cuenta. Reintenta la misma solicitud.', 503);
    }
    return response.data;
  };

  let userId = await findAuthUser();
  if (userId === null) {
    if (reservation.data.completed) {
      throw new StaffCreationError('La cuenta creada ya no está disponible. Solicita asistencia.', 409);
    }
    let created: RemoteResult<string> | null = null;
    try {
      created = await gateway.createAuthUser();
    } catch {
      console.error('[player-admin] Staff authentication response was unavailable.');
    }
    if (!created?.error && typeof created?.data === 'string') {
      userId = created.data;
    } else {
      userId = await findAuthUser();
      if (userId === null) {
        throw new StaffCreationError('No se pudo confirmar la cuenta. Reintenta la misma solicitud.', 503);
      }
    }
  }

  let finalized: RemoteResult<unknown>;
  try {
    finalized = await gateway.finalize(userId);
  } catch {
    throw new StaffCreationError('No se pudo completar la cuenta. Reintenta la misma solicitud.', 503);
  }
  if (finalized.error?.code === '23505') {
    throw new StaffCreationError('El usuario ya está registrado.', 409);
  }
  if (finalized.error?.code === '42501') {
    throw new StaffCreationError('La cuenta o autorización cambió. Revisa la solicitud.', 403);
  }
  if (finalized.error || !isRecord(finalized.data) ||
      typeof finalized.data.can_deliver_password !== 'boolean') {
    throw new StaffCreationError('No se pudo completar la cuenta. Reintenta la misma solicitud.', 503);
  }
  const { can_deliver_password: canDeliverPassword, ...staffInfo } = finalized.data;
  return {
    staff: staffInfo,
    password_available: canDeliverPassword,
    ...(canDeliverPassword ? { temporary_password: temporaryPassword } : {}),
  };
}
