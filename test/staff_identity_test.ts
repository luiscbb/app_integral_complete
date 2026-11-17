import assert from 'node:assert/strict';
import { test } from 'node:test';

import { parseStaffDraft, parseStaffUpdate } from '../supabase/functions/player-admin/staff_identity.ts';

test('staff identity is normalized, valid and consistent with Flutter login', () => {
  const draft = parseStaffDraft({
    username: '  CAJERO..01 ',
    full_name: ' Ana Pérez ',
    job_title: ' Caja ',
    modules: ['quick_sale', 'quick_sale', 'purchases'],
  });

  assert.equal(draft.username, 'cajero..01');
  assert.equal(draft.authEmail, '63616a65726f2e2e3031@staff.baumar.invalid');
  assert.deepEqual(draft.modules, ['quick_sale', 'purchases']);
  assert.equal(draft.fullName, 'Ana Pérez');
});

test('pilot rejects unsupported modules for both creation and update', () => {
  for (const module of ['billiard_tables', 'dine_in', 'personal_account', 'reports', 'players', 'settings']) {
    const details = { full_name: 'Ana', job_title: 'Caja', modules: ['quick_sale', module] };
    assert.throws(() => parseStaffDraft({ ...details, username: 'pilot' }), /piloto/i);
    assert.throws(() => parseStaffUpdate({
      ...details, user_id: '12345678-1234-1234-1234-123456789012',
      is_active: true, staff_revision: 0,
    }), /piloto/i);
  }
  assert.deepEqual(parseStaffDraft({
    username: 'pilot', full_name: 'Ana', job_title: 'Caja',
    modules: ['quick_sale', 'inventory', 'purchases'],
  }).modules, ['quick_sale', 'inventory', 'purchases']);
});

test('staff updates require a valid identity, state and revision', () => {
  const valid = {
    user_id: '12345678-1234-1234-1234-123456789012',
    is_active: true,
    staff_revision: 3,
    full_name: ' Ana ',
    job_title: ' Caja ',
    modules: ['quick_sale', 'quick_sale'],
  };
  assert.deepEqual(parseStaffUpdate(valid), {
    userId: valid.user_id,
    isActive: true,
    expectedRevision: 3,
    fullName: 'Ana',
    jobTitle: 'Caja',
    modules: ['quick_sale'],
  });
  for (const invalid of [
    { ...valid, user_id: 'bad' },
    { ...valid, is_active: 'true' },
    { ...valid, staff_revision: -1 },
    { ...valid, staff_revision: 1.5 },
    { ...valid, staff_revision: Number.MAX_SAFE_INTEGER + 1 },
    { ...valid, modules: ['admin'] },
  ]) {
    assert.throws(() => parseStaffUpdate(invalid), TypeError);
  }
});

test('rejects invalid usernames, identity fields and modules', () => {
  const valid = { username: 'abc', full_name: 'Ana', job_title: 'Caja', modules: ['quick_sale'] };
  for (const invalid of [
    { ...valid, username: 'ab' },
    { ...valid, username: 'bad@host' },
    { ...valid, full_name: ' ' },
    { ...valid, job_title: ' ' },
    { ...valid, modules: [] },
    { ...valid, modules: ['admin'] },
    { ...valid, modules: ['players', null] },
  ]) {
    assert.throws(() => parseStaffDraft(invalid), TypeError);
  }
});
