import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  finishTemporaryPasswordChange,
  PasswordChangeError,
  type PasswordChangeGateway,
} from '../supabase/functions/player-admin/password_change_workflow.ts';

function fixture() {
  const calls: string[] = [];
  let membership: Record<string, unknown> | null = {
    billar_id: 'A', role: 'manager', username: 'caja', full_name: 'Caja',
    job_title: 'Ventas', allowed_modules: ['quick_sale'],
    staff_revision: 3, is_active: true, must_change_password: true,
  };
  const gateway: PasswordChangeGateway = {
    findPlayer: async () => {
      calls.push('player');
      return { data: null, error: null };
    },
    findMembership: async (billar) => {
      calls.push(`membership:${billar}`);
      return { data: membership, error: null };
    },
    stopStaffRecovery: async () => {
      calls.push('stop');
      return { data: true, error: null };
    },
    updatePassword: async (password) => {
      assert.equal(password, '  new-password  ');
      calls.push('password');
      return { error: null };
    },
    completeStaff: async (billar, revision) => {
      calls.push(`staff:${billar}:${revision}`);
      return { data: true, error: null };
    },
    completePlayer: async (id) => {
      calls.push(`complete-player:${id}`);
      return { data: { id }, error: null };
    },
    completeLegacyMembership: async (billar) => {
      calls.push(`legacy:${billar}`);
      return { data: { user_id: 'manager' }, error: null };
    },
  };
  return {
    gateway, calls,
    setMembership: (value: Record<string, unknown> | null) => { membership = value; },
    membership: () => ({ ...membership }),
  };
}

const rejected = (status: number) => (error: unknown) =>
  error instanceof PasswordChangeError && error.status === status &&
  !error.message.includes('new-password');

test('staff changes the exact password only after disabling temporary recovery', async () => {
  const f = fixture();
  await finishTemporaryPasswordChange('staff', 'A', '  new-password  ', f.gateway);
  assert.deepEqual(f.calls, ['membership:A', 'stop', 'password', 'staff:A:3']);
});

test('staff cannot use player rows or invalid, foreign or revoked memberships', async () => {
  for (const change of [
    { is_active: false }, { billar_id: 'B' }, { role: 'admin' },
    { staff_revision: -1 }, { username: 'CAJA' }, { allowed_modules: ['unknown'] },
    { allowed_modules: ['quick_sale', 'quick_sale'] },
  ]) {
    const f = fixture();
    f.setMembership({ ...f.membership(), ...change });
    await assert.rejects(
      finishTemporaryPasswordChange('staff', 'A', '  new-password  ', f.gateway),
      rejected(403),
    );
    assert.deepEqual(f.calls, ['membership:A']);
  }
  const f = fixture();
  await assert.rejects(
    finishTemporaryPasswordChange('staff', '', '  new-password  ', f.gateway),
    rejected(403),
  );
  assert.deepEqual(f.calls, []);
});

test('lookup errors and recovery failures never update authentication', async () => {
  const f = fixture();
  f.gateway.findMembership = async () => ({ data: f.membership(), error: { code: 'offline' } });
  await assert.rejects(
    finishTemporaryPasswordChange('staff', 'A', '  new-password  ', f.gateway), rejected(503),
  );
  assert.deepEqual(f.calls, []);
  const g = fixture();
  g.gateway.stopStaffRecovery = async () => ({ data: false, error: null });
  await assert.rejects(
    finishTemporaryPasswordChange('staff', 'A', '  new-password  ', g.gateway), rejected(503),
  );
  assert.deepEqual(g.calls, ['membership:A']);
});

test('auth errors and concurrent membership changes cannot report completion', async () => {
  const f = fixture();
  f.gateway.updatePassword = async () => ({ error: { message: 'do not expose new-password' } });
  await assert.rejects(
    finishTemporaryPasswordChange('staff', 'A', '  new-password  ', f.gateway), rejected(503),
  );
  assert.deepEqual(f.calls, ['membership:A', 'stop']);
  for (const result of [{ data: false, error: null }, { data: null, error: { code: '40001' } }]) {
    const g = fixture();
    g.gateway.completeStaff = async () => result;
    await assert.rejects(
      finishTemporaryPasswordChange('staff', 'A', '  new-password  ', g.gateway), rejected(503),
    );
    assert.deepEqual(g.calls, ['membership:A', 'stop', 'password']);
  }
});

test('legacy players and managers retain their paths with explicit completion', async () => {
  const f = fixture();
  f.gateway.findPlayer = async () => ({
    data: { id: 'player-1', must_change_password: true }, error: null,
  });
  await finishTemporaryPasswordChange('player', 'A', '  new-password  ', f.gateway);
  assert.deepEqual(f.calls, ['password', 'complete-player:player-1']);
  const g = fixture();
  g.setMembership({
    billar_id: 'A', role: 'manager', username: null,
    is_active: true, must_change_password: true,
  });
  await finishTemporaryPasswordChange('manager', 'A', '  new-password  ', g.gateway);
  assert.deepEqual(g.calls, ['player', 'membership:A', 'password', 'legacy:A']);
  g.gateway.completeLegacyMembership = async () => ({ data: null, error: null });
  await assert.rejects(
    finishTemporaryPasswordChange('manager', 'A', '  new-password  ', g.gateway), rejected(503),
  );
});

test('invalid input, player lookup errors and completed flags fail closed', async () => {
  const f = fixture();
  await assert.rejects(finishTemporaryPasswordChange('staff', 'A', 'short', f.gateway), rejected(400));
  assert.deepEqual(f.calls, []);
  f.setMembership({ ...f.membership(), must_change_password: false });
  await assert.rejects(
    finishTemporaryPasswordChange('staff', 'A', '  new-password  ', f.gateway), rejected(409),
  );
  const g = fixture();
  g.gateway.findPlayer = async () => ({ data: null, error: { code: 'offline' } });
  await assert.rejects(
    finishTemporaryPasswordChange('manager', 'A', '  new-password  ', g.gateway), rejected(503),
  );
  assert.deepEqual(g.calls, []);
});
