// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('staff module policies restrict rows and preserve existing access', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated nologin;
      create role anon nologin;
      create schema auth;
      create schema storage;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      create function storage.foldername(name text) returns text[] language sql immutable as $$
        select case when position('/' in name) > 0
          then string_to_array(regexp_replace(name, '/[^/]*$', ''), '/')
          else array[]::text[] end
      $$;
      grant usage on schema public, auth, storage to authenticated;

      create table public.business_memberships (
        user_id uuid not null, billar_id text not null, role text not null,
        is_active boolean not null, username text, allowed_modules text[] not null,
        must_change_password boolean not null default false
      );
      create table public.players (
        id text primary key, billar_id text not null, auth_user_id uuid
      );
      create table public.billar_tournaments (id text primary key, billar_id text not null);
      create table public.personal_clients (id text primary key, billar_id text not null);
      create table public.personal_customer_accounts (id text primary key, billar_id text not null);
      create table storage.objects (id text primary key, bucket_id text, name text not null);

      insert into public.business_memberships
        (user_id, billar_id, role, is_active, username, allowed_modules) values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, null, '{}'),
        ('00000000-0000-0000-0000-000000000002', 'A', 'manager', true, null, '{}'),
        ('00000000-0000-0000-0000-000000000003', 'A', 'manager', true, 'jugadores', '{players}'),
        ('00000000-0000-0000-0000-000000000004', 'A', 'manager', true, 'cuentas', '{personal_account}'),
        ('00000000-0000-0000-0000-000000000005', 'A', 'manager', false, 'inactivo', '{players,personal_account}'),
        ('00000000-0000-0000-0000-000000000006', 'A', 'manager', true, 'cajero', '{quick_sale}');
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000009', 'A', 'manager', true, 'nuevo', '{players,personal_account}', true);
      insert into public.players values
        ('player-a', 'A', '00000000-0000-0000-0000-000000000007'),
        ('player-b', 'B', '00000000-0000-0000-0000-000000000008');
      insert into public.billar_tournaments values ('tournament-a', 'A'), ('tournament-b', 'B');
      insert into public.personal_clients values ('client-a', 'A'), ('client-b', 'B');
      insert into public.personal_customer_accounts values ('account-a', 'A'), ('account-b', 'B');
      insert into storage.objects values
        ('avatar-a', 'player_avatars', 'A/avatar.jpg'),
        ('avatar-b', 'player_avatars', 'B/avatar.jpg');

      alter table public.players enable row level security;
      alter table public.billar_tournaments enable row level security;
      alter table public.personal_clients enable row level security;
      alter table public.personal_customer_accounts enable row level security;
      alter table storage.objects enable row level security;
      grant select, insert, update, delete on public.players, public.billar_tournaments,
        public.personal_clients, public.personal_customer_accounts to authenticated;
      grant select, insert, update, delete on storage.objects to authenticated;

      -- A permissive policy models the most permissive existing policy.
      create policy fixture_all on public.players for all to authenticated
        using (true) with check (true);
      create policy fixture_all on public.billar_tournaments for all to authenticated
        using (true) with check (true);
      create policy fixture_all on public.personal_clients for all to authenticated
        using (true) with check (true);
      create policy fixture_all on public.personal_customer_accounts for all to authenticated
        using (true) with check (true);
      create policy fixture_all on storage.objects for all to authenticated
        using (true) with check (true);
      -- add_player_registration.sql may have installed this older restriction.
      create policy business_admin_only on public.personal_clients as restrictive for all to authenticated
        using (false) with check (false);
      create policy business_admin_only on public.personal_customer_accounts as restrictive for all to authenticated
        using (false) with check (false);
    `);

    const migration = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'staff_module_guards_partial.sql'),
      'utf8',
    );
    await db.exec(migration);
    await db.exec(migration);
    await db.exec('set role authenticated');

    const asUser = async (id) => {
      await db.query("select set_config('request.jwt.claim.sub', $1, false)", [
        `00000000-0000-0000-0000-${id.toString().padStart(12, '0')}`,
      ]);
    };
    const ids = async (table) => {
      const { rows } = await db.query(`select id from public.${table} order by id`);
      return rows.map((row) => row.id);
    };

    await asUser(1);
    assert.deepEqual(await ids('players'), ['player-a']);
    assert.deepEqual(await ids('personal_clients'), ['client-a']);
    assert.deepEqual(await ids('billar_tournaments'), ['tournament-a']);
    await assert.rejects(
      db.query("update public.players set billar_id = 'B' where id = 'player-a'"),
      /row-level security/i,
    );
    await assert.rejects(
      db.query("insert into storage.objects values ('avatar-other', 'player_avatars', 'B/new.jpg')"),
      /row-level security/i,
    );
    await assert.rejects(
      db.query("update storage.objects set name = 'B/new.jpg' where id = 'avatar-a'"),
      /row-level security/i,
    );

    await asUser(2);
    assert.deepEqual(await ids('players'), ['player-a']);
    assert.deepEqual(await ids('personal_customer_accounts'), ['account-a']);
    assert.equal(
      (await db.query("select public.has_staff_module_access('A', 'quick_sale') as allowed"))
        .rows[0].allowed,
      false,
    );

    await asUser(3);
    assert.deepEqual(await ids('players'), ['player-a']);
    assert.deepEqual(await ids('billar_tournaments'), ['tournament-a']);
    assert.deepEqual(await ids('personal_clients'), []);
    assert.deepEqual(await ids('personal_customer_accounts'), []);
    await db.query("insert into storage.objects values ('avatar-new', 'player_avatars', 'A/new.jpg')");
    await db.exec(`
      reset role;
      update public.business_memberships set allowed_modules = '{}'
      where username = 'jugadores';
      set role authenticated;
    `);
    assert.deepEqual(await ids('players'), []);
    assert.deepEqual(await ids('billar_tournaments'), []);

    await asUser(4);
    assert.deepEqual(await ids('players'), []);
    assert.deepEqual(await ids('billar_tournaments'), []);
    assert.deepEqual(await ids('personal_clients'), ['client-a']);
    assert.deepEqual(await ids('personal_customer_accounts'), ['account-a']);
    await db.query("insert into public.personal_clients values ('client-new', 'A')");
    await assert.rejects(
      db.query("insert into public.personal_clients values ('client-other', 'B')"),
      /row-level security/i,
    );
    await assert.rejects(
      db.query("update public.personal_customer_accounts set billar_id = 'B' where id = 'account-a'"),
      /row-level security/i,
    );
    await db.query("delete from public.personal_clients where id = 'client-new'");
    await assert.rejects(
      db.query("insert into storage.objects values ('avatar-denied', 'player_avatars', 'A/denied.jpg')"),
      /row-level security/i,
    );
    assert.equal(
      (await db.query("delete from storage.objects where id = 'avatar-a' returning id")).rows.length,
      0,
    );

    for (const id of [5, 6]) {
      await asUser(id);
      assert.deepEqual(await ids('players'), []);
      assert.deepEqual(await ids('personal_clients'), []);
      await assert.rejects(
        db.query("insert into public.players values ('new-player', 'A', null)"),
        /row-level security/i,
      );
    }

    await asUser(9);
    assert.deepEqual(await ids('players'), []);
    assert.deepEqual(await ids('billar_tournaments'), []);
    assert.deepEqual(await ids('personal_clients'), []);
    await assert.rejects(
      db.query("insert into storage.objects values ('avatar-pending', 'player_avatars', 'A/new.jpg')"),
      /row-level security/i,
    );
    await db.exec(`
      reset role;
      update public.business_memberships set must_change_password = false where username = 'nuevo';
      set role authenticated;
    `);
    assert.deepEqual(await ids('players'), ['player-a']);
    assert.deepEqual(await ids('personal_clients'), ['client-a']);

    await asUser(7);
    assert.deepEqual(await ids('players'), ['player-a']);
    assert.deepEqual(await ids('billar_tournaments'), []);
    assert.equal(
      (await db.query("update public.players set billar_id = 'A' where id = 'player-a' returning id"))
        .rows.length,
      0,
    );
    await assert.rejects(
      db.query("insert into public.players values ('new-player', 'A', null)"),
      /row-level security/i,
    );
  } finally {
    await db.close();
  }
});
