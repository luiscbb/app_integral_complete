const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

export type StaffCredentialVersion = 1 | 2;

export function parseStaffCredentialVersion(value: unknown): StaffCredentialVersion {
  if (value === undefined || value === 1) return 1;
  if (value === 2) return 2;
  throw new TypeError('La versión de la contraseña temporal no es válida.');
}

export function normalizeStaffRequestId(value: unknown): string {
  const requestId = typeof value === 'string' ? value.trim().toLowerCase() : '';
  if (!uuidV4.test(requestId)) {
    throw new TypeError('La solicitud de creación no tiene un identificador válido.');
  }
  return requestId;
}

export async function deriveStaffCreationCredential(
  secretHex: string,
  requestId: string,
  actorId: string,
  billarId: string,
  version: StaffCredentialVersion = 1,
): Promise<{ keyFingerprint: string; temporaryPassword: string }> {
  parseStaffCredentialVersion(version);
  if (!/^[0-9a-f]{64}$/i.test(secretHex)) {
    throw new Error('La clave del servidor para crear personal no está configurada correctamente.');
  }
  const bytes = new Uint8Array(32);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(secretHex.slice(i * 2, i * 2 + 2), 16);
  }
  const fingerprint = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  const key = await crypto.subtle.importKey(
    'raw', bytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const keyFingerprint = Array.from(fingerprint, (byte) =>
    byte.toString(16).padStart(2, '0')).join('');
  // Exactly 64 symbols: mapping six bits is unbiased and omits 0/O and 1/I/l.
  const alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%*?';
  for (let attempt = 0; ; attempt++) {
    const payload = JSON.stringify(version === 1
      ? ['staff-creation-v1', requestId, actorId, billarId]
      : ['staff-creation-v2', requestId, actorId, billarId, attempt]);
    const signature = new Uint8Array(
      await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload)),
    );
    if (version === 1) {
      const encoded = btoa(String.fromCharCode(...signature))
        .replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      return { keyFingerprint, temporaryPassword: `aA1!${encoded}` };
    }
    const password = Array.from(signature.subarray(0, 14), (byte) =>
      alphabet[byte & 63]).join('');
    if (/[a-z]/.test(password) && /[A-Z]/.test(password) &&
        /[2-9]/.test(password) && /[!@#$%*?]/.test(password)) {
      return { keyFingerprint, temporaryPassword: password };
    }
  }
}
