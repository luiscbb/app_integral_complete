import assert from 'node:assert/strict';
import { test } from 'node:test';

import { canManagePlayers, resolveBusinessRole } from '../supabase/functions/player-admin/permissions.ts';

test('access requires an active membership and a matching owner for admins', () => {
  const admin = { role: 'admin', is_active: true, must_change_password: false };
  assert.equal(resolveBusinessRole({ ...admin, is_active: false }, true), null);
  assert.equal(resolveBusinessRole({ ...admin, must_change_password: true }, true), null);
  assert.equal(resolveBusinessRole({ ...admin, role: 'manager' }, true), 'manager');
  assert.equal(resolveBusinessRole(admin, true), 'admin');
  assert.equal(resolveBusinessRole(admin, false), null);
  assert.equal(resolveBusinessRole(null, true), null);
  assert.equal(resolveBusinessRole(null, false), null);
});

test('administrators and legacy managers can manage players', () => {
  assert.equal(canManagePlayers('admin', undefined, undefined, false), true);
  assert.equal(canManagePlayers('admin', undefined, undefined, true), false);
  assert.equal(canManagePlayers('admin', undefined, undefined, undefined), false);
  assert.equal(canManagePlayers('manager', null, [], false), true);
});

test('staff managers require the players module', () => {
  assert.equal(canManagePlayers('manager', 'cajero', ['players'], false), true);
  assert.equal(canManagePlayers('manager', 'cajero', ['quick_sale'], false), false);
  assert.equal(canManagePlayers('manager', 'cajero', null, false), false);
  assert.equal(canManagePlayers('manager', undefined, ['players'], false), false);
  assert.equal(canManagePlayers('manager', '', ['players'], false), false);
  assert.equal(canManagePlayers('manager', 'cajero', ['players'], true), false);
  assert.equal(canManagePlayers('manager', 'cajero', ['players'], undefined), false);
  assert.equal(canManagePlayers('manager', null, [], true), false);
});

test('other roles cannot manage players', () => {
  assert.equal(canManagePlayers(null, 'cajero', ['players'], false), false);
  assert.equal(canManagePlayers('player', 'cajero', ['players'], false), false);
});
