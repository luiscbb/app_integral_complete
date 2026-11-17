const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

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
): Promise<{ keyFingerprint: string; temporaryPassword: string }> {
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
  const payload = JSON.stringify(['staff-creation-v1', requestId, actorId, billarId]);
  const signature = new Uint8Array(
    await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload)),
  );
  const encoded = btoa(String.fromCharCode(...signature))
    .replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  return {
    keyFingerprint: Array.from(fingerprint, (byte) => byte.toString(16).padStart(2, '0')).join(''),
    temporaryPassword: `aA1!${encoded}`,
  };
}
