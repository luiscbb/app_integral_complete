// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('provider archival is authorized, atomic and idempotent', async () => {
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
        is_active boolean not null, must_change_password boolean not null,
        primary key (user_id, billar_id)
      );
      create table public.billar_settings (user_id uuid not null, billar_id text not null);
      create table public.providers (id bigint primary key, billar_id text not null);
      create table public.provider_products (
        provider_id bigint not null references public.providers(id) on delete cascade
      );
      create table public.purchases (
        provider_id bigint references public.providers(id)
      );
      insert into public.billar_settings values
        ('00000000-0000-0000-0000-000000000001', 'A'),
        ('00000000-0000-0000-0000-000000000002', 'B'),
        ('00000000-0000-0000-0000-000000000007', 'C');
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, false),
        ('00000000-0000-0000-0000-000000000002', 'B', 'admin', true, false),
        ('00000000-0000-0000-0000-000000000003', 'A', 'manager', true, false),
        ('00000000-0000-0000-0000-000000000004', 'A', 'admin', false, false),
        ('00000000-0000-0000-0000-000000000005', 'A', 'admin', true, true),
        ('00000000-0000-0000-0000-000000000006', 'A', 'admin', true, false);
      insert into public.providers values (1, 'A'), (2, 'B'), (3, 'C'), (4, 'A');
      insert into public.provider_products values (1), (2);
      insert into public.purchases values (1), (2);
    `);
    const sql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'provider_delete_idempotent_partial.sql'),
      'utf8',
    );
    await db.exec(sql);
    await db.exec(sql);
    await db.exec('set role authenticated');
    const asUser = async id => db.query(
      "select set_config('request.jwt.claim.sub', $1, false)",
      [`00000000-0000-0000-0000-${id.toString().padStart(12, '0')}`],
    );
    const request = (id, business, provider) => db.query(
      'select public.archive_provider_idempotent($1::uuid, $2, $3::bigint) as result',
      [id, business, provider],
    );
    const first = '10000000-0000-4000-8000-000000000001';
    const second = '10000000-0000-4000-8000-000000000002';

    await asUser(3);
    await assert.rejects(request(first, 'A', 1), /administrador activo/i);
    await asUser(4);
    await assert.rejects(request(first, 'A', 1), /administrador activo/i);
    await asUser(5);
    await assert.rejects(request(first, 'A', 1), /administrador activo/i);
    await asUser(1);
    await assert.rejects(request(first, 'A', 2), /no está disponible/i);
    await assert.rejects(request(first, 'A', 999), /no está disponible/i);
    await assert.rejects(db.query('select * from public.provider_archive_requests'), /permission denied/i);
    const result = (await request(first, 'A', 1)).rows[0].result;
    assert.deepEqual(result, { request_id: first, billar_id: 'A', provider_id: 1, archived: true });
    assert.deepEqual((await request(first, 'A', 1)).rows[0].result, result);
    await assert.rejects(request(first, 'A', 4), /ya fue utilizado/i);
    await asUser(6);
    await assert.rejects(request(first, 'A', 1), /administrador activo/i);
    await asUser(7);
    await assert.rejects(request(second, 'C', 3), /administrador activo/i);
    await db.exec(`reset role;
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000007', 'C', 'admin', true, false);
      set role authenticated`);
    assert.equal((await request(second, 'C', 3)).rows[0].result.archived, true);

    await db.exec('reset role');
    assert.deepEqual((await db.query('select id, is_active from public.providers order by id')).rows.map(r => [Number(r.id), r.is_active]), [[1, false], [2, true], [3, false], [4, true]]);
    assert.deepEqual((await db.query('select provider_id from public.provider_products order by provider_id')).rows.map(r => Number(r.provider_id)), [1, 2]);
    assert.deepEqual((await db.query('select provider_id from public.purchases order by provider_id')).rows.map(r => Number(r.provider_id)), [1, 2]);
    assert.equal((await db.query('select count(*)::int as n from public.provider_archive_requests')).rows[0].n, 2);

    await db.exec(`
      create function public.fail_provider_archive() returns trigger language plpgsql as $$
      begin raise exception 'fallo simulado'; end $$;
      create trigger fail_provider_archive before update on public.providers
      for each row when (old.id = 4) execute function public.fail_provider_archive();
      set role authenticated;
    `);
    await asUser(1);
    const third = '10000000-0000-4000-8000-000000000003';
    await assert.rejects(request(third, 'A', 4), /fallo simulado/i);
    await db.exec('reset role');
    assert.equal((await db.query('select count(*)::int as n from public.provider_archive_requests where request_id = $1', [third])).rows[0].n, 0);
    assert.equal((await db.query('select is_active from public.providers where id = 4')).rows[0].is_active, true);
    await db.exec('set role anon');
    await assert.rejects(request(third, 'A', 4), /permission denied/i);
  } finally {
    await db.close();
  }
});
