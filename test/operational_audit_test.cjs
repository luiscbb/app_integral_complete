// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('operational audit is transactional, scoped and excludes secret values', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated nologin;
      create role anon nologin;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      grant usage on schema public, auth to authenticated, anon;
      create table public.business_memberships (
        user_id uuid not null, billar_id text not null, role text not null,
        is_active boolean not null, must_change_password boolean not null
      );
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, false),
        ('00000000-0000-0000-0000-000000000002', 'B', 'admin', true, false),
        ('00000000-0000-0000-0000-000000000003', 'A', 'manager', true, false),
        ('00000000-0000-0000-0000-000000000004', 'A', 'admin', true, true);
      create table public.sales_history (
        id bigint primary key, billar_id text not null, total double precision,
        cancelled boolean, updated_at timestamptz, customer_key text
      );
      create table public.purchases (
        id bigint primary key, billar_id text not null, total double precision, cancelled boolean
      );
      create table public.products (
        id bigint primary key, billar_id text not null, name text, stock double precision
      );
      create table public.inventory_movements (
        id bigint primary key, billar_id text not null, product_id bigint, quantity double precision
      );
      create table public.cash_outflows (
        id bigint primary key, billar_id text not null, amount double precision, description text
      );
      create table public.billar_settings (
        id uuid primary key, billar_id text not null, hourly_rate double precision, admin_pin text
      );
      grant select, insert, update, delete on public.sales_history, public.purchases,
        public.products, public.inventory_movements, public.cash_outflows,
        public.billar_settings to authenticated;
    `);
    const migration = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'operational_audit_partial.sql'), 'utf8',
    );
    await db.exec(migration);
    await db.exec(migration);
    const asUser = async id => db.query(
      "select set_config('request.jwt.claim.sub', $1, false)",
      [`00000000-0000-0000-0000-${id.toString().padStart(12, '0')}`],
    );
    await db.exec('set role authenticated');
    await asUser(1);
    await db.query("insert into public.sales_history values (1, 'A', 10, false, now(), 'private customer')");
    await db.query("update public.sales_history set cancelled = true where id = 1");
    await db.query("update public.sales_history set updated_at = clock_timestamp() where id = 1");
    await db.query("insert into public.billar_settings values ('10000000-0000-0000-0000-000000000001', 'A', 25, 'secret pin')");
    await db.query("update public.billar_settings set admin_pin = 'new secret' where billar_id = 'A'");
    const rows = (await db.query('select * from public.operational_audit order by id')).rows;
    assert.equal(rows.length, 4);
    assert.equal(rows[0].actor_id, '00000000-0000-0000-0000-000000000001');
    assert.equal(rows[1].old_values.cancelled, false);
    assert.equal(rows[1].new_values.cancelled, true);
    assert.deepEqual(rows[1].changed_fields, ['cancelled']);
    assert.deepEqual(rows[3].changed_fields, ['admin_pin']);
    assert.equal(JSON.stringify(rows).includes('secret'), false);
    assert.equal(JSON.stringify(rows).includes('private customer'), false);
    await assert.rejects(db.query("insert into public.operational_audit (billar_id) values ('A')"), /permission denied/i);
    await assert.rejects(db.query('delete from public.operational_audit'), /permission denied/i);

    await db.exec('begin');
    await db.query("insert into public.products values (2, 'A', 'P', 4)");
    await db.exec('rollback');
    assert.equal((await db.query('select count(*)::int as n from public.operational_audit')).rows[0].n, 4);
    await db.query("update public.sales_history set billar_id = 'B' where id = 1");
    assert.equal((await db.query('select count(*)::int as n from public.operational_audit')).rows[0].n, 5);
    await asUser(2);
    const other = (await db.query('select operation, old_values, new_values from public.operational_audit')).rows;
    assert.equal(other.length, 1);
    assert.equal(other[0].operation, 'INSERT');
    assert.equal(other[0].old_values, null);
    await asUser(3);
    assert.equal((await db.query('select count(*)::int as n from public.operational_audit')).rows[0].n, 0);
    await asUser(4);
    assert.equal((await db.query('select count(*)::int as n from public.operational_audit')).rows[0].n, 0);
    await asUser(1);
    await db.query("insert into public.products values (3, 'A', 'Producto', 4)");
    await db.query("insert into public.inventory_movements values (4, 'A', 3, 1)");
    await db.query("delete from public.inventory_movements where id = 4");
    await db.query("insert into public.cash_outflows values (5, 'A', 12, 'private note')");
    const categories = (await db.query(
      "select entity_type, operation from public.operational_audit where entity_id in ('3', '4', '5') order by id",
    )).rows;
    assert.deepEqual(categories.map(row => [row.entity_type, row.operation]), [
      ['products', 'INSERT'], ['inventory_movements', 'INSERT'],
      ['inventory_movements', 'DELETE'], ['cash_outflows', 'INSERT'],
    ]);
    assert.equal(JSON.stringify((await db.query('select * from public.operational_audit')).rows).includes('private note'), false);
    await db.exec('reset role');
    await db.query("select set_config('request.jwt.claim.sub', '', false)");
    await db.query("insert into public.purchases values (9, 'A', 20, false)");
    assert.equal((await db.query("select actor_id from public.operational_audit where entity_type = 'purchases'")).rows[0].actor_id, null);
    await db.exec('set role anon');
    await assert.rejects(db.query('select * from public.operational_audit'), /permission denied/i);
  } finally {
    await db.close();
  }
});
