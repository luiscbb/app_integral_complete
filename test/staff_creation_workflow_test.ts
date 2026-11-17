import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  createStaffWithRetry,
  StaffCreationError,
  type StaffCreationGateway,
} from '../supabase/functions/player-admin/staff_creation_workflow.ts';

function fixture() {
  let userId: string | null = null;
  let completed = false;
  let deliver = true;
  let loseAuthResponse = false;
  let loseFinalResponse = false;
  let lookupError: string | null = null;
  let creations = 0;
  let audits = 0;
  const gateway: StaffCreationGateway = {
    reserve: async () => ({ data: { completed }, error: null }),
    findAuthUser: async () => ({
      data: userId,
      error: lookupError ? { code: lookupError } : null,
    }),
    createAuthUser: async () => {
      creations++;
      if (userId) return { data: null, error: { code: 'duplicate' } };
      userId = 'user-1';
      if (loseAuthResponse) {
        loseAuthResponse = false;
        throw new Error('network response lost');
      }
      return { data: userId, error: null };
    },
    finalize: async (id) => {
      assert.equal(id, userId);
      if (!completed) {
        completed = true;
        audits++;
      }
      if (loseFinalResponse) {
        loseFinalResponse = false;
        throw new Error('network response lost');
      }
      return { data: { user_id: id, can_deliver_password: deliver }, error: null };
    },
  };
  return {
    gateway,
    loseAuth: () => { loseAuthResponse = true; },
    loseFinal: () => { loseFinalResponse = true; },
    revokePassword: () => { deliver = false; },
    deleteAuth: () => { userId = null; },
    failLookup: (code: string) => { lookupError = code; },
    counts: () => ({ creations, audits }),
  };
}

test('recovers lost authentication and finalization responses without duplicates', async () => {
  const f = fixture();
  f.loseAuth();
  f.loseFinal();
  await assert.rejects(createStaffWithRetry(f.gateway, 'secret'), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 503 && !error.message.includes('secret'));
  const result = await createStaffWithRetry(f.gateway, 'secret');
  assert.deepEqual(result, {
    staff: { user_id: 'user-1' },
    password_available: true,
    temporary_password: 'secret',
  });
  assert.deepEqual(f.counts(), { creations: 1, audits: 1 });
  f.revokePassword();
  assert.deepEqual(await createStaffWithRetry(f.gateway, 'secret'), {
    staff: { user_id: 'user-1' },
    password_available: false,
  });
});

test('concurrent retries converge on one authentication account and audit', async () => {
  const f = fixture();
  const results = await Promise.all([
    createStaffWithRetry(f.gateway, 'secret'),
    createStaffWithRetry(f.gateway, 'secret'),
  ]);
  assert.deepEqual(results[0], results[1]);
  assert.equal(f.counts().audits, 1);
});

test('preserves the account when recovery lookup is temporarily unavailable', async () => {
  const f = fixture();
  const find = f.gateway.findAuthUser;
  const create = f.gateway.createAuthUser;
  let lookups = 0;
  f.gateway.findAuthUser = async () => {
    lookups++;
    if (lookups === 2) throw new Error('network unavailable');
    return await find();
  };
  f.gateway.createAuthUser = async () => {
    await create();
    throw new Error('response lost');
  };
  await assert.rejects(createStaffWithRetry(f.gateway, 'secret'), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 503);
  assert.equal((await createStaffWithRetry(f.gateway, 'secret')).password_available, true);
  assert.deepEqual(f.counts(), { creations: 1, audits: 1 });
});

test('never recreates a completed missing account or takes a conflicting account', async () => {
  const f = fixture();
  await createStaffWithRetry(f.gateway, 'secret');
  f.deleteAuth();
  await assert.rejects(createStaffWithRetry(f.gateway, 'secret'), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 409);
  assert.deepEqual(f.counts(), { creations: 1, audits: 1 });
  const other = fixture();
  other.failLookup('23505');
  await assert.rejects(createStaffWithRetry(other.gateway, 'secret'), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 409);
  assert.deepEqual(other.counts(), { creations: 0, audits: 0 });
});

test('fails closed on revoked authorization or malformed service responses', async () => {
  const f = fixture();
  f.failLookup('42501');
  await assert.rejects(createStaffWithRetry(f.gateway, 'secret'), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 403);
  const invalid = fixture();
  invalid.gateway.reserve = async () => ({ data: null, error: null });
  await assert.rejects(createStaffWithRetry(invalid.gateway, 'secret'), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 503);
  assert.deepEqual(invalid.counts(), { creations: 0, audits: 0 });
});
