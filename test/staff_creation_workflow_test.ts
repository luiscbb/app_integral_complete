import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  createStaffWithRetry,
  StaffCreationError,
  type StaffCreationGateway,
} from '../supabase/functions/player-admin/staff_creation_workflow.ts';
import {
  deriveStaffCreationCredential,
  parseStaffCredentialVersion,
} from '../supabase/functions/player-admin/staff_creation_key.ts';

const recoverPassword = async () => 'secret';

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
  await assert.rejects(createStaffWithRetry(f.gateway, recoverPassword), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 503 && !error.message.includes('secret'));
  const result = await createStaffWithRetry(f.gateway, recoverPassword);
  assert.deepEqual(result, {
    staff: { user_id: 'user-1' },
    password_available: true,
    temporary_password: 'secret',
  });
  assert.deepEqual(f.counts(), { creations: 1, audits: 1 });
  f.revokePassword();
  assert.deepEqual(await createStaffWithRetry(f.gateway, recoverPassword), {
    staff: { user_id: 'user-1' },
    password_available: false,
  });
});

test('concurrent retries converge on one authentication account and audit', async () => {
  const f = fixture();
  const results = await Promise.all([
    createStaffWithRetry(f.gateway, recoverPassword),
    createStaffWithRetry(f.gateway, recoverPassword),
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
  await assert.rejects(createStaffWithRetry(f.gateway, recoverPassword), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 503);
  assert.equal((await createStaffWithRetry(f.gateway, recoverPassword)).password_available, true);
  assert.deepEqual(f.counts(), { creations: 1, audits: 1 });
});

test('never recreates a completed missing account or takes a conflicting account', async () => {
  const f = fixture();
  await createStaffWithRetry(f.gateway, recoverPassword);
  f.deleteAuth();
  await assert.rejects(createStaffWithRetry(f.gateway, recoverPassword), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 409);
  assert.deepEqual(f.counts(), { creations: 1, audits: 1 });
  const other = fixture();
  other.failLookup('23505');
  await assert.rejects(createStaffWithRetry(other.gateway, recoverPassword), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 409);
  assert.deepEqual(other.counts(), { creations: 0, audits: 0 });
});

test('fails closed on revoked authorization or malformed service responses', async () => {
  const f = fixture();
  f.failLookup('42501');
  await assert.rejects(createStaffWithRetry(f.gateway, recoverPassword), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 403);
  const invalid = fixture();
  invalid.gateway.reserve = async () => ({ data: null, error: null });
  await assert.rejects(createStaffWithRetry(invalid.gateway, recoverPassword), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 503);
  assert.deepEqual(invalid.counts(), { creations: 0, audits: 0 });
});

test('credential lookup failures keep the finalized account recoverable without leaking passwords', async () => {
  const f = fixture();
  await assert.rejects(createStaffWithRetry(f.gateway, async () => {
    throw new Error('secret');
  }), (error: unknown) =>
    error instanceof StaffCreationError && error.status === 503 && !error.message.includes('secret'));
  let lookups = 0;
  const recover = async (id: string) => {
    assert.equal(id, 'user-1');
    lookups++;
    return 'recovered-credential';
  };
  assert.equal((await createStaffWithRetry(f.gateway, recover)).temporary_password, 'recovered-credential');
  assert.deepEqual(f.counts(), { creations: 1, audits: 1 });
  f.revokePassword();
  assert.deepEqual(await createStaffWithRetry(f.gateway, recover), {
    staff: { user_id: 'user-1' },
    password_available: false,
  });
  assert.equal(lookups, 1);
});

test('retries recover the persisted account version after lost responses, including legacy accounts', async () => {
  for (const storedVersion of [undefined, 2]) {
    const f = fixture();
    const credential = await deriveStaffCreationCredential(
      'ab'.repeat(32), 'request', 'actor', 'business',
      parseStaffCredentialVersion(storedVersion),
    );
    const recover = async (id: string) => {
      assert.equal(id, 'user-1');
      return (await deriveStaffCreationCredential(
        'ab'.repeat(32), 'request', 'actor', 'business',
        parseStaffCredentialVersion(storedVersion),
      )).temporaryPassword;
    };
    f.loseAuth();
    f.loseFinal();
    await assert.rejects(createStaffWithRetry(f.gateway, recover), (error: unknown) =>
      error instanceof StaffCreationError && error.status === 503);
    const result = await createStaffWithRetry(f.gateway, recover);
    assert.equal(result.temporary_password, credential.temporaryPassword);
    assert.equal(credential.temporaryPassword.length, storedVersion === 2 ? 14 : 47);
    assert.deepEqual(await createStaffWithRetry(f.gateway, recover), result);
    assert.deepEqual(f.counts(), { creations: 1, audits: 1 });
  }
});
