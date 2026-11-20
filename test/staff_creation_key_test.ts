import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';

import {
  deriveStaffCreationCredential,
  normalizeStaffRequestId,
  parseStaffCredentialVersion,
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
  assert.equal(
    createHash('sha256').update(first.temporaryPassword).digest('hex'),
    'd195d739befc5b0183e3cf79bc8e907ffa13d083c33c36bbe177c6b1bd1eef55',
  );
  assert.equal(first.keyFingerprint.length, 64);
  await assert.rejects(deriveStaffCreationCredential('short', request, actor, 'A'));
});

test('new credentials are short, unambiguous and isolated without changing the server key fingerprint', async () => {
  const secret = 'ab'.repeat(32);
  const request = '12345678-1234-4abc-8def-123456789012';
  const actor = '12345678-1234-1234-1234-123456789012';
  const legacy = await deriveStaffCreationCredential(secret, request, actor, 'A', 1);
  const short = await deriveStaffCreationCredential(secret, request, actor, 'A', 2);
  assert.deepEqual(await deriveStaffCreationCredential(secret, request, actor, 'A', 2), short);
  assert.equal(short.keyFingerprint, legacy.keyFingerprint);
  const passwords = new Set<string>();
  for (let index = 0; index < 32; index++) {
    const derived = await deriveStaffCreationCredential(
      secret, request, actor, `business-${index}`, 2,
    );
    assert.equal(derived.temporaryPassword.length, 14);
    assert.doesNotMatch(derived.temporaryPassword, /[01IOl]/);
    assert.match(derived.temporaryPassword, /^[a-zA-Z2-9!@#$%*?]+$/);
    assert.match(derived.temporaryPassword, /[a-z]/);
    assert.match(derived.temporaryPassword, /[A-Z]/);
    assert.match(derived.temporaryPassword, /[2-9]/);
    assert.match(derived.temporaryPassword, /[!@#$%*?]/);
    passwords.add(derived.temporaryPassword);
  }
  assert.equal(passwords.size, 32);
  assert.notEqual((await deriveStaffCreationCredential(secret, request, 'other', 'A', 2)).temporaryPassword, short.temporaryPassword);
  assert.notEqual((await deriveStaffCreationCredential(secret, '22345678-1234-4abc-8def-123456789012', actor, 'A', 2)).temporaryPassword, short.temporaryPassword);
});

test('missing version recovers legacy credentials and unsupported metadata is rejected', () => {
  assert.equal(parseStaffCredentialVersion(undefined), 1);
  assert.equal(parseStaffCredentialVersion(1), 1);
  assert.equal(parseStaffCredentialVersion(2), 2);
  for (const invalid of [null, 0, 3, '2', false, {}]) {
    assert.throws(() => parseStaffCredentialVersion(invalid), TypeError);
  }
});

test('request IDs are normalized UUIDv4 identifiers', () => {
  assert.equal(
    normalizeStaffRequestId('  12345678-1234-4ABC-8DEF-123456789012  '),
    '12345678-1234-4abc-8def-123456789012',
  );
  assert.throws(() => normalizeStaffRequestId('12345678-1234-1abc-8def-123456789012'), TypeError);
  assert.throws(() => normalizeStaffRequestId('not-a-uuid'), TypeError);
});
