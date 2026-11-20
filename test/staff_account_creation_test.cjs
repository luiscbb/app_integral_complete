// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('staff creation reserves and recovers requests without duplicating audit or exposing old passwords', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated nologin;
      create role anon nologin;
      create role service_role nologin;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      grant usage on schema public, auth to authenticated, service_role;
      create table auth.users (id uuid primary key, email text not null unique, raw_app_meta_data jsonb not null);
      create table public.business_memberships (
        user_id uuid not null, billar_id text not null, email text not null default '',
        role text not null, is_active boolean not null default true,
        must_change_password boolean not null default false, created_by uuid,
        username text unique, full_name text not null default '',
        job_title text not null default '', allowed_modules text[] not null default '{}',
        primary key (user_id, billar_id)
      );
      alter table public.business_memberships enable row level security;
      grant select, insert, update, delete on public.business_memberships to authenticated;
      create policy fixture_existing_admin_policy on public.business_memberships
        for all to authenticated using (true) with check (true);
      create function public.has_billar_role(b text, r text[]) returns boolean
      language sql stable security definer set search_path = public, pg_temp as $$
        select exists (select 1 from public.business_memberships m
          where m.user_id = auth.uid() and m.billar_id = b and m.is_active
            and m.role = any(r))
      $$;
      insert into public.business_memberships (user_id, billar_id, role, is_active) values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true),
        ('00000000-0000-0000-0000-000000000002', 'B', 'admin', true),
        ('00000000-0000-0000-0000-000000000003', 'A', 'manager', true),
        ('00000000-0000-0000-0000-000000000004', 'A', 'admin', false),
        ('00000000-0000-0000-0000-000000000005', 'A', 'admin', true);
    `);
    const sql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'staff_account_creation_partial.sql'),
      'utf8',
    );
    await db.exec(sql);
    await db.exec(sql);
    const id = (n) => `00000000-0000-0000-0000-${n.toString().padStart(12, '0')}`;
    const request = (n) => `10000000-0000-4000-8000-${n.toString().padStart(12, '0')}`;
    const email = '63616a65726f2e2e3031@staff.baumar.invalid';
    const fingerprint = 'a'.repeat(64);
    const reserve = (req = 1, actor = 1, name = 'Ana', modules = '{quick_sale}', key = fingerprint, address = email, username = 'cajero..01') =>
      db.query(
        'select public.reserve_staff_account($1, $2, $3, $4, $5, $6, $7::text[], $8, $9) as result',
        [request(req), id(actor), 'A', username, name, 'Caja', modules, address, key],
      );
    const lookup = (req = 1, actor = 1) => db.query(
      'select public.find_staff_creation_auth_user($1, $2, $3) as user_id',
      [request(req), id(actor), 'A'],
    );
    const finalize = (req = 1, actor = 1, user = 11) => db.query(
      'select public.finalize_staff_account($1, $2, $3, $4) as staff',
      [request(req), id(actor), 'A', id(user)],
    );

    await db.exec('set role authenticated');
    await assert.rejects(reserve(), /permission denied/i);
    await assert.rejects(lookup(), /permission denied/i);
    await assert.rejects(db.query('select public.stop_staff_password_recovery($1)', [id(11)]), /permission denied/i);
    await assert.rejects(
      db.query('select public.complete_staff_password_change($1, $2, $3)', [id(11), 'A', 0]),
      /permission denied/i,
    );
    await assert.rejects(
      db.query('select public.update_staff_account($1, $2, $3, $4, $5, $6::text[], $7, $8)',
        [id(1), 'A', id(3), 'Ana', 'Caja', '{quick_sale}', true, 0]),
      /permission denied/i,
    );
    assert.ok((await db.query('select * from public.business_memberships')).rows.length > 0);
    await assert.rejects(
      db.query("insert into public.business_memberships (user_id, billar_id, role) values ($1, 'A', 'manager')", [id(12)]),
      /row-level security/i,
    );
    assert.equal((await db.query("update public.business_memberships set role = 'admin' where user_id = $1 returning user_id", [id(3)])).rows.length, 0);
    assert.equal((await db.query('delete from public.business_memberships where user_id = $1 returning user_id', [id(3)])).rows.length, 0);
    await db.exec('reset role; set role service_role');
    for (const actor of [2, 3, 4]) {
      await assert.rejects(reserve(1, actor), /administrador activo/i);
    }
    await assert.rejects(reserve(1, 1, 'Ana', '{admin}'), /inválidos/i);
    await assert.rejects(
      reserve(1, 1, 'Ana', '{billiard_tables_open}'),
      /inválidos/i,
    );
    await assert.rejects(reserve(1, 1, 'Ana', '{quick_sale}', fingerprint, 'other@example.com'), /identificador/i);
    assert.equal(
      (
        await reserve(
          3,
          1,
          'Mesero',
          '{billiard_tables,billiard_tables_open,billiard_tables_consume}',
          fingerprint,
          '6d657365726f2e2e3031@staff.baumar.invalid',
          'mesero..01',
        )
      ).rows[0].result.completed,
      false,
    );
    assert.equal((await reserve()).rows[0].result.completed, false);
    assert.equal((await reserve()).rows[0].result.completed, false);
    await assert.rejects(reserve(1, 5), /otros datos/i);
    await assert.rejects(lookup(1, 5), /no está disponible/i);
    await assert.rejects(finalize(1, 5), /no está disponible/i);
    await assert.rejects(db.query(
      'select public.reserve_staff_account($1, $2, $3, $4, $5, $6, $7::text[], $8, $9)',
      [request(1), id(2), 'B', 'cajero..01', 'Ana', 'Caja', '{quick_sale}', email, fingerprint],
    ), /otros datos/i);
    await assert.rejects(reserve(1, 1, 'Otro'), /otros datos/i);
    await assert.rejects(reserve(1, 1, 'Ana', '{quick_sale}', 'b'.repeat(64)), /otros datos/i);
    await assert.rejects(reserve(2), /duplicate key/i);
    assert.equal((await lookup()).rows[0].user_id, null);

    await db.exec('reset role');
    await db.query('insert into auth.users values ($1, $2, $3::jsonb)', [
      id(11), email, JSON.stringify({ account_type: 'player', billar_id: 'A' }),
    ]);
    await db.exec('set role service_role');
    await assert.rejects(lookup(), /ya está registrado/i);
    await db.exec('reset role');
    await db.query('update auth.users set raw_app_meta_data = $1::jsonb where id = $2', [
      JSON.stringify({ account_type: 'staff', billar_id: 'A', creation_request_id: request(1) }), id(11),
    ]);
    await db.exec('set role service_role');
    assert.equal((await lookup()).rows[0].user_id, id(11));
    await assert.rejects(finalize(1, 1, 12), /no coincide/i);

    await db.exec(`
      reset role;
      create function public.fixture_audit_failure() returns trigger language plpgsql as $$
      begin raise exception 'audit failure'; end $$;
      create trigger fixture_audit_failure before insert on public.staff_account_audit
        for each row execute function public.fixture_audit_failure();
      set role service_role;
    `);
    await assert.rejects(finalize(), /audit failure/i);
    await db.exec('reset role');
    assert.equal((await db.query('select user_id from public.business_memberships where user_id = $1', [id(11)])).rows.length, 0);
    assert.equal((await db.query('select completed from public.staff_account_requests where request_id = $1', [request(1)])).rows[0].completed, false);
    await db.exec('drop trigger fixture_audit_failure on public.staff_account_audit; set role service_role');
    const staff = (await finalize()).rows[0].staff;
    assert.equal(staff.username, 'cajero..01');
    assert.equal(staff.must_change_password, true);
    assert.equal(staff.can_deliver_password, true);
    assert.deepEqual(staff.allowed_modules, ['quick_sale']);
    assert.deepEqual((await finalize()).rows[0].staff, staff);
    assert.equal((await reserve()).rows[0].result.completed, true);

    await db.exec('reset role; set role authenticated');
    const asUser = async (n) => db.query("select set_config('request.jwt.claim.sub', $1, false)", [id(n)]);
    await asUser(1);
    const listed = (await db.query("select public.list_staff_accounts('A') as staff")).rows[0].staff;
    assert.equal(listed.length, 1);
    assert.equal(listed[0].user_id, id(11));
    assert.equal(listed[0].staff_revision, 0);
    assert.equal('email' in listed[0], false);
    for (const actor of [2, 3, 4]) {
      await asUser(actor);
      await assert.rejects(db.query("select public.list_staff_accounts('A')"), /administrador activo/i);
    }
    await asUser(1);
    await assert.rejects(db.query("select public.list_staff_accounts('B')"), /administrador activo/i);
    await db.exec('reset role');
    const audit = (await db.query('select actor_id, target_user_id, event_type from public.staff_account_audit')).rows;
    assert.deepEqual(audit, [{ actor_id: id(1), target_user_id: id(11), event_type: 'create' }]);
    await db.exec('set role service_role');
    const updateStaff = (actor = 1, user = 11, active = true, modules = '{reports,quick_sale}', name = 'Ana', revision = 0) =>
      db.query('select public.update_staff_account($1, $2, $3, $4, $5, $6::text[], $7, $8) as staff',
        [id(actor), 'A', id(user), name, 'Caja', modules, active, revision]);
    for (const actor of [2, 3, 4]) {
      await assert.rejects(updateStaff(actor), /administrador activo/i);
    }
    await assert.rejects(updateStaff(1, 3), /No se encontró/i);
    await assert.rejects(updateStaff(1, 11, true, '{admin}'), /inválidos/i);
    await db.exec('reset role; create trigger fixture_audit_failure before insert on public.staff_account_audit for each row execute function public.fixture_audit_failure(); set role service_role');
    await assert.rejects(updateStaff(), /audit failure/i);
    await db.exec('reset role');
    assert.deepEqual((await db.query('select allowed_modules from public.business_memberships where user_id = $1', [id(11)])).rows[0].allowed_modules, ['quick_sale']);
    await db.exec('drop trigger fixture_audit_failure on public.staff_account_audit; set role service_role');
    const updated = (await updateStaff()).rows[0].staff;
    assert.deepEqual(updated.allowed_modules, ['quick_sale', 'reports']);
    assert.equal(updated.is_active, true);
    assert.equal(updated.staff_revision, 1);
    assert.deepEqual((await updateStaff(1, 11, true, '{quick_sale,reports,quick_sale}')).rows[0].staff, updated);
    await assert.rejects(updateStaff(1, 11, false), /cambió/i);
    assert.equal((await updateStaff(5, 11, true, '{reports,quick_sale}', 'Ana Maria', 1)).rows[0].staff.staff_revision, 2);
    await assert.rejects(updateStaff(1, 11, false, '{reports,quick_sale}', 'Ana', 1), /cambió/i);
    assert.equal((await updateStaff(1, 11, false, '{reports,quick_sale}', 'Ana Maria', 2)).rows[0].staff.is_active, false);
    await assert.rejects(updateStaff(), /cambió/i);
    await db.exec('reset role');
    const updates = (await db.query("select actor_id, target_user_id, details from public.staff_account_audit where event_type = 'update' order by id")).rows;
    assert.equal(updates.length, 3);
    assert.equal(updates[0].actor_id, id(1));
    assert.equal(updates[0].target_user_id, id(11));
    assert.deepEqual(updates[0].details.before.modules, ['quick_sale']);
    assert.deepEqual(updates[0].details.after.modules, ['quick_sale', 'reports']);
    assert.equal(updates[1].actor_id, id(5));
    assert.equal(updates[1].details.before.full_name, 'Ana');
    assert.equal(updates[1].details.after.full_name, 'Ana Maria');
    assert.equal(updates[2].details.before.is_active, true);
    assert.equal(updates[2].details.after.is_active, false);
    await db.query('update public.business_memberships set is_active = false where user_id = $1', [id(11)]);
    await db.exec('set role service_role');
    assert.equal((await finalize()).rows[0].staff.can_deliver_password, false);
    await db.exec('reset role');
    await db.query('update public.business_memberships set is_active = true where user_id = $1', [id(11)]);
    await db.query('update public.business_memberships set must_change_password = false where user_id = $1', [id(11)]);
    await db.exec('set role service_role');
    assert.equal((await finalize()).rows[0].staff.can_deliver_password, false);
    await db.exec('reset role');
    await db.query('update public.business_memberships set must_change_password = true where user_id = $1', [id(11)]);
    await db.exec('set role service_role');
    assert.equal((await db.query('select public.stop_staff_password_recovery($1) as stopped', [id(11)])).rows[0].stopped, true);
    assert.equal((await finalize()).rows[0].staff.can_deliver_password, false);
    const completePassword = (revision = 3) => db.query(
      'select public.complete_staff_password_change($1, $2, $3) as completed',
      [id(11), 'A', revision],
    );
    await assert.rejects(completePassword(2), /cambió/i);
    await db.exec('reset role');
    await db.query('update public.business_memberships set is_active = false where user_id = $1', [id(11)]);
    await db.exec('set role service_role');
    await assert.rejects(completePassword(), /acceso activo/i);
    await db.exec('reset role');
    await db.query('update public.business_memberships set is_active = true where user_id = $1', [id(11)]);
    await db.exec('create trigger fixture_audit_failure before insert on public.staff_account_audit for each row execute function public.fixture_audit_failure(); set role service_role');
    await assert.rejects(completePassword(), /audit failure/i);
    await db.exec('reset role');
    assert.equal((await db.query('select must_change_password from public.business_memberships where user_id = $1', [id(11)])).rows[0].must_change_password, true);
    await db.exec('drop trigger fixture_audit_failure on public.staff_account_audit; set role service_role');
    assert.equal((await completePassword()).rows[0].completed, true);
    assert.equal((await completePassword()).rows[0].completed, true);
    await db.exec('reset role');
    const passwordAudit = (await db.query("select details from public.staff_account_audit where event_type = 'password_changed'")).rows;
    assert.deepEqual(passwordAudit, [{ details: { staff_revision: 4 } }]);
    await db.exec('reset role');
    await db.query('update public.business_memberships set is_active = false where user_id = $1', [id(1)]);
    await db.exec('set role service_role');
    await assert.rejects(lookup(), /administrador activo/i);
    await assert.rejects(finalize(), /administrador activo/i);
  } finally {
    await db.close();
  }
});
