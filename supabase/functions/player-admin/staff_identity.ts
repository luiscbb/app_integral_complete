const modules = new Set([
  'quick_sale',
  'inventory',
  'purchases',
]);

function parseStaffDetails(input: Record<string, unknown>) {
  const fullName = typeof input.full_name === 'string' ? input.full_name.trim() : '';
  const jobTitle = typeof input.job_title === 'string' ? input.job_title.trim() : '';
  if (!fullName || fullName.length > 120 || !jobTitle || jobTitle.length > 80) {
    throw new TypeError('Ingresa el nombre y puesto del usuario.');
  }
  if (!Array.isArray(input.modules) || input.modules.length === 0) {
    throw new TypeError('Selecciona módulos válidos.');
  }
  const selected: string[] = [];
  for (const item of input.modules) {
    if (typeof item !== 'string' || !modules.has(item)) {
      throw new TypeError('El piloto solo permite Venta rápida, Inventario y Compras.');
    }
    selected.push(item);
  }
  return { fullName, jobTitle, modules: [...new Set(selected)] };
}

export function parseStaffDraft(input: Record<string, unknown>) {
  const username = typeof input.username === 'string'
    ? input.username.trim().toLowerCase()
    : '';
  if (!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(username)) {
    throw new TypeError('El usuario no tiene un formato válido.');
  }
  const details = parseStaffDetails(input);
  const encoded = Array.from(username, (character) =>
    character.charCodeAt(0).toString(16).padStart(2, '0')
  ).join('');
  return {
    username,
    ...details,
    authEmail: `${encoded}@staff.baumar.invalid`,
  };
}

export function parseStaffUpdate(input: Record<string, unknown>) {
  if (typeof input.user_id !== 'string' ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input.user_id)) {
    throw new TypeError('La cuenta de personal no es válida.');
  }
  if (typeof input.is_active !== 'boolean' ||
      typeof input.staff_revision !== 'number' ||
      !Number.isSafeInteger(input.staff_revision) || input.staff_revision < 0) {
    throw new TypeError('El estado o la revisión de la cuenta no es válida.');
  }
  return {
    userId: input.user_id.toLowerCase(),
    isActive: input.is_active,
    expectedRevision: input.staff_revision,
    ...parseStaffDetails(input),
  };
}
