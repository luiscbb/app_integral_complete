export function resolveBusinessRole(
  membership: { role: string; is_active: boolean; must_change_password: boolean } | null,
  isOwner: boolean,
): string | null {
  if (!membership || membership.is_active !== true ||
      membership.must_change_password !== false) return null;
  if (membership.role === 'admin') return isOwner ? 'admin' : null;
  return membership.role === 'manager' ? 'manager' : null;
}

export function canManagePlayers(
  role: string | null,
  username: unknown,
  allowedModules: unknown,
  mustChangePassword: unknown,
): boolean {
  if (role === 'admin') return mustChangePassword === false;
  if (role !== 'manager') return false;
  if (mustChangePassword !== false) return false;
  // Legacy email-based managers have no username.
  if (username === null) return true;
  return typeof username === 'string' &&
    username.length > 0 &&
    Array.isArray(allowedModules) &&
    allowedModules.includes('players');
}
