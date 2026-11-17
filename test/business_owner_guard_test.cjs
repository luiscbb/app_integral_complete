// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

const migration = fs.readFileSync(
  path.join(__dirname, '..', 'supabase', 'business_owner_guard_partial.sql'),
  'utf8',
);
const id = (n) => `00000000-0000-0000-0000-${n.toString().padStart(12, '0')}`;

async function fixture() {
  const db = new PGlite();
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create schema auth;
    create table auth.users (id uuid primary key, email text);
    insert into auth.users (id, email) values
      ('00000000-0000-0000-0000-000000000001', 'one@example.com'),
      ('00000000-0000-0000-0000-000000000002', 'two@example.com'),
      ('00000000-0000-0000-0000-000000000003', 'three@example.com'),
      ('00000000-0000-0000-0000-000000000004', 'four@example.com');
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
    $$;
    grant usage on schema public, auth to authenticated;
    create table public.billar_settings (
      user_id uuid not null unique, billar_id text not null, business_name text not null default ''
    );
    create table public.business_memberships (
      user_id uuid not null, billar_id text not null, role text not null,
      is_active boolean not null default true, email text not null default '',
      primary key (user_id, billar_id)
    );
    create function public.sync_billar_admin_membership() returns trigger
    language plpgsql security definer set search_path = public, pg_temp as $$
    begin
      if tg_op = 'UPDATE' and (old.user_id is distinct from new.user_id
          or old.billar_id is distinct from new.billar_id) then
        delete from public.business_memberships
        where user_id = old.user_id and billar_id = old.billar_id and role = 'admin';
      end if;
      insert into public.business_memberships (user_id, billar_id, role)
      values (new.user_id, new.billar_id, 'admin')
      on conflict (user_id, billar_id) do update set role = 'admin', is_active = true;
      return new;
    end $$;
    create trigger billar_settings_admin_membership
      after insert or update of user_id, billar_id on public.billar_settings
      for each row execute function public.sync_billar_admin_membership();
    alter table public.billar_settings enable row level security;
    grant select, insert, update, delete on public.billar_settings to authenticated;
    create policy fixture_owner on public.billar_settings for all to authenticated
      using (user_id = auth.uid()) with check (user_id = auth.uid());
  `);
  return db;
}

test('business identities cannot be claimed, transferred or reused by another account', async () => {
  const db = await fixture();
  try {
    await db.query("insert into public.billar_settings (user_id, billar_id) values ($1, 'A'), ($2, 'B')", [id(1), id(2)]);
    await db.query("insert into public.business_memberships (user_id, billar_id, role) values ($1, 'A', 'manager')", [id(3)]);
    await db.exec(migration);
    await db.exec(migration);
    await db.exec('set role authenticated');
    const asUser = async (n) => db.query("select set_config('request.jwt.claim.sub', $1, false)", [id(n)]);
    await asUser(1);
    await db.query(`insert into public.billar_settings (user_id, billar_id, business_name)
      values ($1, 'A', 'Actualizado') on conflict (user_id)
      do update set billar_id = excluded.billar_id, business_name = excluded.business_name`, [id(1)]);
    await assert.rejects(db.query(`insert into public.billar_settings (user_id, billar_id)
      values ($1, 'B') on conflict (user_id)
      do update set billar_id = excluded.billar_id`, [id(1)]), /pertenece a otra cuenta/i);
    await db.exec('reset role');
    await db.query("update public.business_memberships set is_active = false where user_id = $1 and billar_id = 'A'", [id(1)]);
    await db.exec('set role authenticated');
    await db.query(`insert into public.billar_settings (user_id, billar_id)
      values ($1, 'A') on conflict (user_id)
      do update set billar_id = excluded.billar_id`, [id(1)]);
    await db.exec('reset role');
    assert.equal((await db.query("select is_active from public.business_memberships where user_id = $1 and billar_id = 'A'", [id(1)])).rows[0].is_active, false);
    await db.query("update public.business_memberships set role = 'manager', is_active = true where user_id = $1 and billar_id = 'A'", [id(1)]);
    await db.exec('set role authenticated');
    await db.query(`insert into public.billar_settings (user_id, billar_id)
      values ($1, 'A') on conflict (user_id)
      do update set billar_id = excluded.billar_id`, [id(1)]);
    await db.exec('reset role');
    assert.equal((await db.query("select role from public.business_memberships where user_id = $1 and billar_id = 'A'", [id(1)])).rows[0].role, 'manager');
    await db.exec('set role authenticated');
    await asUser(3);
    await assert.rejects(db.query('select * from public.business_identity_registry'), /permission denied/i);
    await assert.rejects(
      db.query("insert into public.billar_settings (user_id, billar_id) values ($1, 'A')", [id(3)]),
      /pertenece a otra cuenta/i,
    );
    await assert.rejects(
      db.query("insert into public.billar_settings (user_id, billar_id) values ($1, 'B')", [id(3)]),
      /pertenece a otra cuenta/i,
    );
    await db.query("insert into public.billar_settings (user_id, billar_id) values ($1, 'C')", [id(3)]);
    await assert.rejects(
      db.query("update public.billar_settings set billar_id = 'A' where user_id = $1", [id(3)]),
      /no puede modificarse/i,
    );
    await assert.rejects(
      db.query('update public.billar_settings set user_id = $1 where user_id = $2', [id(4), id(3)]),
      /no puede modificarse/i,
    );
    await db.query("update public.billar_settings set business_name = 'Cambio permitido' where user_id = $1", [id(3)]);
    await db.query('delete from public.billar_settings where user_id = $1', [id(3)]);
    await asUser(4);
    await assert.rejects(
      db.query("insert into public.billar_settings (user_id, billar_id) values ($1, 'C')", [id(4)]),
      /pertenece a otra cuenta/i,
    );
    await asUser(3);
    await db.query("insert into public.billar_settings (user_id, billar_id) values ($1, 'C')", [id(3)]);
    await db.exec('reset role');
    const roles = (await db.query('select billar_id, role from public.business_memberships where user_id = $1 order by billar_id', [id(3)])).rows;
    assert.deepEqual(roles, [{ billar_id: 'A', role: 'manager' }, { billar_id: 'C', role: 'admin' }]);
  } finally {
    await db.close();
  }
});

test('migration fails without changing data when business identities are ambiguous', async () => {
  for (const problem of ['duplicate', 'orphan']) {
    const db = await fixture();
    try {
      if (problem === 'duplicate') {
        await db.query("insert into public.billar_settings (user_id, billar_id) values ($1, 'A'), ($2, 'A')", [id(1), id(2)]);
      } else {
        await db.query("insert into public.business_memberships (user_id, billar_id, role) values ($1, 'A', 'admin')", [id(1)]);
      }
      await assert.rejects(db.exec(migration), problem === 'duplicate' ? /duplicados/i : /sin propietario/i);
      await db.exec('rollback');
      assert.equal((await db.query("select to_regclass('public.business_identity_registry') as name")).rows[0].name, null);
      const count = (await db.query('select count(*)::int as count from public.business_memberships')).rows[0].count;
      assert.equal(count, problem === 'duplicate' ? 2 : 1);
    } finally {
      await db.close();
    }
  }
});
