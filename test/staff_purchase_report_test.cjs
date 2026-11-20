const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');
const { functionDefinition } = require('../supabase/build_staff_rollout.cjs');

test('purchase report enforces membership, range, isolation, full totals and keyset pagination', async () => {
  const db = new PGlite();
  const read = file => fs.readFileSync(path.join(__dirname, '..', 'supabase', file), 'utf8');
  try {
    await db.exec(`
      create role anon nologin;
      create role authenticated nologin;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      grant usage on schema auth, public to anon, authenticated;
      alter default privileges in schema public grant execute on functions to anon, authenticated;
      create table public.business_memberships (
        user_id uuid, billar_id text, role text, username text,
        is_active boolean, must_change_password boolean, allowed_modules text[]
      );
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'manager', 'consulta', true, false, '{reports_purchases}');
      create table public.providers (id bigint primary key, billar_id text, name text, private_notes text);
      insert into public.providers values (1, 'A', 'Proveedor A', 'secret'),
        (2, 'B', 'Proveedor B', 'secret');
      create table public.purchases (
        id bigint primary key, billar_id text, provider_id bigint, date text, reference text,
        total numeric, payment_condition text, payment_method text,
        paid_amount numeric, balance_due numeric, cancelled boolean, private_notes text
      );
      insert into public.purchases
      select id, 'A', 1, '2026-01-15T12:00:00Z', 'REF', 10, 'contado', 'Efectivo', 10, 0, false, 'secret'
      from generate_series(1, 52) id;
      update public.purchases set payment_condition = 'credito', paid_amount = null, balance_due = null where id = 1;
      -- A bad provider reference must never reveal another business's name.
      update public.purchases set provider_id = 2 where id = 52;
      insert into public.purchases values
        (53, 'B', 2, '2026-01-15', '', 900, 'contado', 'Efectivo', 900, 0, false, 'secret'),
        (54, 'A', 1, '2026-01-15', '', 900, 'contado', 'Efectivo', 900, 0, true, 'secret'),
        (55, 'A', 1, '2026-02-01T00:00:00Z', '', 900, 'contado', 'Efectivo', 900, 0, false, 'secret');
      alter table public.purchases enable row level security;
      alter table public.providers enable row level security;
    `);
    await db.exec(functionDefinition(read('staff_module_guards_partial.sql'), 'has_staff_module_access'));
    const sql = read('staff_purchase_report.sql');
    await db.exec(sql);
    await db.exec(sql);
    assert.equal((await db.query(
      "select has_function_privilege('anon', 'public.staff_purchase_report(text,timestamptz,timestamptz,bigint)', 'EXECUTE') as allowed",
    )).rows[0].allowed, false);
    await db.exec(`set role authenticated;
      select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false)`);
    const load = (business = 'A', start = '2026-01-01', end = '2026-02-01', cursor = null) =>
      db.query('select public.staff_purchase_report($1,$2,$3,$4) as report', [business, start, end, cursor])
        .then(result => result.rows[0].report);
    const first = await load();
    assert.deepEqual(
      [first.count, first.total, first.paid, first.balance, first.has_more, first.items.length],
      [52, 520, 510, 10, true, 50],
    );
    assert.equal(first.items[0].provider_name, null);
    assert.equal(first.items[1].provider_name, 'Proveedor A');
    assert.deepEqual(first.items.map(item => item.id), Array.from({ length: 50 }, (_, i) => 52 - i));
    assert.ok(first.items.every(item => item.billar_id === 'A' &&
      !Object.hasOwn(item, 'private_notes') && !Object.hasOwn(item, 'created_by')));
    const second = await load('A', '2026-01-01', '2026-02-01', 3);
    assert.deepEqual(second.items.map(item => item.id), [2, 1]);
    assert.deepEqual([second.total, second.paid, second.balance, second.has_more], [520, 510, 10, false]);
    assert.equal((await load('A', '2027-01-01', '2027-02-01')).count, 0);
    await assert.rejects(load('B'), /permiso/i);
    await assert.rejects(load('A', '2026-02-01', '2026-01-01'), /inválidos/i);
    await assert.rejects(load('A', '2025-01-01', '2026-02-01'), /inválidos/i);
    await assert.rejects(load('A', '2026-01-01', 'infinity'), /inválidos/i);
    await assert.rejects(load('A', '2026-01-01', '2026-02-01', 0), /inválidos/i);
    await assert.rejects(db.query('select * from public.purchases'), /permission denied/i);
    await assert.rejects(db.query('select * from public.providers'), /permission denied/i);
    await assert.rejects(db.exec('delete from public.purchases'), /permission denied/i);
    for (const change of [
      'is_active = false',
      'is_active = true, must_change_password = true',
      "must_change_password = false, allowed_modules = '{purchases}'",
      "allowed_modules = '{reports}'",
      "allowed_modules = '{reports_purchases}', role = 'player'",
    ]) {
      await db.exec(`reset role; update public.business_memberships set ${change}; set role authenticated`);
      await assert.rejects(load(), /permiso/i);
    }
    await db.exec('reset role; set role anon');
    await assert.rejects(load(), /permission denied/i);
  } finally {
    await db.close();
  }
});
