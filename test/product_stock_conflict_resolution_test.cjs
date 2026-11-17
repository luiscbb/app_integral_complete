// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('only the correct administrator can reconcile and audit a current revision', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated nologin;
      create role anon nologin;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      grant usage on schema public, auth to authenticated;
      create table public.business_memberships (
        user_id uuid not null, billar_id text not null, role text not null,
        is_active boolean not null, must_change_password boolean not null default false
      );
      create function public.has_billar_role(b text, r text[]) returns boolean
      language sql stable security definer set search_path = public, pg_temp as $$
        select exists (select 1 from public.business_memberships m
          where m.user_id = auth.uid() and m.billar_id = b and m.is_active
            and m.role = any(r))
      $$;
      create table public.products (
        id bigint primary key, billar_id text not null, stock double precision not null
      );
      insert into public.products values (1, 'A', 10), (2, 'B', 8);
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, false),
        ('00000000-0000-0000-0000-000000000002', 'A', 'manager', true, false),
        ('00000000-0000-0000-0000-000000000003', 'B', 'admin', true, false),
        ('00000000-0000-0000-0000-000000000004', 'A', 'admin', false, false),
        ('00000000-0000-0000-0000-000000000005', 'A', 'admin', true, true);
    `);
    for (const file of [
      'product_stock_conflict_guard_partial.sql',
      'product_stock_conflict_resolution_partial.sql',
    ]) {
      const sql = fs.readFileSync(path.join(__dirname, '..', 'supabase', file), 'utf8');
      await db.exec(sql);
      await db.exec(sql);
    }
    await db.exec('set role authenticated');
    const asUser = (id) => db.query(
      "select set_config('request.jwt.claim.sub', $1, false)",
      [`00000000-0000-0000-0000-${id.toString().padStart(12, '0')}`],
    );
    const reconcile = (billar, product, revision, stock) => db.query(
      'select public.resolve_product_stock_conflict($1, $2, $3, $4) as revision',
      [billar, product, revision, stock],
    );

    for (const user of [2, 3, 4, 5]) {
      await asUser(user);
      await assert.rejects(reconcile('A', 1, 0, 7), /administrador/i);
    }
    await asUser(1);
    await assert.rejects(reconcile('A', 2, 0, 7), /no pertenece/i);
    await assert.rejects(reconcile('A', 1, 2, 7), /cambió/i);
    await assert.rejects(reconcile('A', 1, 0, 'Infinity'), /inválidos/i);
    await assert.rejects(reconcile('A', 1, 0, 'NaN'), /inválidos/i);
    assert.equal((await db.query('select * from public.product_stock_reconciliation_audit')).rows.length, 0);
    assert.equal(Number((await reconcile('A', 1, 0, 7)).rows[0].revision), 1);
    const audit = (await db.query('select * from public.product_stock_reconciliation_audit')).rows;
    assert.equal(audit.length, 1);
    assert.equal(audit[0].actor_id, '00000000-0000-0000-0000-000000000001');
    assert.equal(audit[0].previous_stock, 10);
    assert.equal(audit[0].resolved_stock, 7);
    await assert.rejects(reconcile('A', 1, 0, 6), /cambió/i);
    await asUser(3);
    assert.equal((await db.query('select * from public.product_stock_reconciliation_audit')).rows.length, 0);
    await assert.rejects(
      db.query("insert into public.product_stock_reconciliation_audit (billar_id, product_id, actor_id, previous_stock, resolved_stock, previous_revision) values ('B', 2, auth.uid(), 8, 9, 0)"),
      /permission denied/i,
    );
  } finally {
    await db.close();
  }
});
