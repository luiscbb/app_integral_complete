import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  deriveStaffCreationCredential,
  normalizeStaffRequestId,
} from '../supabase/functions/player-admin/staff_creation_key.ts';

test('creation retries derive the same credential, isolated by request and actor', async () => {
  const secret = 'ab'.repeat(32);
  const request = '12345678-1234-4abc-8def-123456789012';
  const actor = '12345678-1234-1234-1234-123456789012';
  const first = await deriveStaffCreationCredential(secret, request, actor, 'A');
  assert.deepEqual(await deriveStaffCreationCredential(secret, request, actor, 'A'), first);
  assert.notEqual((await deriveStaffCreationCredential(secret, request, actor, 'B')).temporaryPassword, first.temporaryPassword);
  assert.notEqual((await deriveStaffCreationCredential(secret, request, 'other', 'A')).temporaryPassword, first.temporaryPassword);
  assert.notEqual((await deriveStaffCreationCredential('cd'.repeat(32), request, actor, 'A')).keyFingerprint, first.keyFingerprint);
  assert.match(first.temporaryPassword, /^aA1![A-Za-z0-9_-]{43}$/);
  assert.equal(first.keyFingerprint.length, 64);
  await assert.rejects(deriveStaffCreationCredential('short', request, actor, 'A'));
});

test('request IDs are normalized UUIDv4 identifiers', () => {
  assert.equal(
    normalizeStaffRequestId('  12345678-1234-4ABC-8DEF-123456789012  '),
    '12345678-1234-4abc-8def-123456789012',
  );
  assert.throws(() => normalizeStaffRequestId('12345678-1234-1abc-8def-123456789012'), TypeError);
  assert.throws(() => normalizeStaffRequestId('not-a-uuid'), TypeError);
});
