const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('staff preflight handles missing columns, detects incompatible data and reports rollout grants without changing rows', async () => {
  const db = new PGlite();
  const script = (name) => fs.readFileSync(path.join(__dirname, '..', 'supabase', name), 'utf8');
  const diagnosticSql = script('staff_rollout_diagnostic.sql');
  const diagnose = async () => (await db.query(diagnosticSql)).rows[0].diagnostic;
  const snapshot = async () => (await db.query('select to_jsonb(m) as data from public.business_memberships m order by user_id')).rows;
  try {
    await db.exec(`
      create role anon nologin;
      create role authenticated nologin;
      create role service_role nologin;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      create table auth.users (id uuid primary key, email text, raw_app_meta_data jsonb);
      create table public.business_memberships (
        user_id uuid not null, billar_id text not null, role text not null,
        email text not null default '', created_by uuid,
        is_active boolean not null default true,
        must_change_password boolean not null default false,
        primary key (user_id, billar_id)
      );
      create function public.has_billar_role(b text, r text[]) returns boolean
      language sql stable security definer set search_path = public, pg_temp as $$
        select exists (select 1 from public.business_memberships m
          where m.user_id = auth.uid() and m.billar_id = b and m.is_active
            and m.role = any(r))
      $$;
      insert into public.business_memberships (user_id, billar_id, role)
      values ('00000000-0000-0000-0000-000000000001', 'PRIVATE_BUSINESS', 'admin');
    `);
    const initialRows = await snapshot();
    const initial = await diagnose();
    assert.equal(initial.membership_columns.find((column) => column.name === 'username').installed, false);
    assert.equal(initial.membership_checks.staff_rows, 0);
    assert.ok(initial.staff_functions.every((fn) => !fn.installed && fn.anon_execute === null));
    assert.ok(initial.purchase_payment_columns.every(column => !column.installed));
    assert.equal(initial.staff_tables.find((table) => table.name === 'staff_account_requests').installed, false);
    assert.deepEqual(await snapshot(), initialRows);

    await db.exec(`
      alter table public.business_memberships
        add column username text, add column full_name text,
        add column job_title text, add column allowed_modules text[];
      insert into public.business_memberships
        (user_id, billar_id, role, username, full_name, job_title, allowed_modules)
      values
        ('00000000-0000-0000-0000-000000000002', 'PRIVATE_BUSINESS', 'manager',
         'SecretCashier', 'PRIVATE_NAME', 'Caja', '{quick_sale,quick_sale}'),
        ('00000000-0000-0000-0000-000000000003', 'PRIVATE_BUSINESS', 'admin',
         ' secretcashier ', '', 'Caja', '{unknown}'),
        ('00000000-0000-0000-0000-000000000004', 'PRIVATE_BUSINESS', 'manager',
         'valid_user', 'PRIVATE_NAME', 'Caja', null);
    `);
    const incompatibleRows = await snapshot();
    const incompatible = await diagnose();
    assert.deepEqual(incompatible.membership_checks, {
      staff_rows: 3, invalid_usernames: 2, non_manager_staff: 1,
      invalid_names_or_jobs: 1, invalid_modules: 3,
      normalized_username_duplicate_groups: 1,
    });
    assert.deepEqual(await snapshot(), incompatibleRows);
    const output = JSON.stringify(incompatible);
    for (const privateValue of ['PRIVATE_BUSINESS', 'PRIVATE_NAME', 'SecretCashier', 'valid_user', '00000000-0000-0000-0000-000000000001']) {
      assert.equal(output.includes(JSON.stringify(privateValue)), false);
    }

    await assert.rejects(db.exec(script('add_staff_account_fields.sql')), /business_memberships_username_format/);
    await db.exec('rollback');
    assert.deepEqual(await snapshot(), incompatibleRows);
    assert.equal((await diagnose()).membership_columns.find((column) => column.name === 'staff_revision').installed, false);

    await db.exec('delete from public.business_memberships where username is not null');
    await db.exec(script('add_staff_account_fields.sql'));
    await db.exec(script('add_staff_account_fields.sql'));
    const prepared = await diagnose();
    const preparedRevision = prepared.membership_columns.find((column) => column.name === 'staff_revision');
    assert.equal(preparedRevision.installed, true);
    assert.equal(preparedRevision.data_type, 'bigint');
    assert.equal(preparedRevision.not_null, true);
    assert.equal(preparedRevision.default_expression, '0');
    assert.ok(prepared.staff_functions.every((fn) => !fn.installed));
    assert.ok(prepared.staff_tables.filter((table) => table.name !== 'business_memberships').every((table) => !table.installed));
    assert.deepEqual(prepared.staff_tables.find((table) => table.name === 'business_memberships'),
      initial.staff_tables.find((table) => table.name === 'business_memberships'));
    assert.equal(prepared.membership_checks.staff_rows, 0);
    await db.exec(script('staff_account_creation_partial.sql'));
    const installedRows = await snapshot();
    const installed = await diagnose();
    const revision = installed.membership_columns.find((column) => column.name === 'staff_revision');
    assert.equal(revision.installed, true);
    assert.equal(revision.data_type, 'bigint');
    assert.equal(revision.not_null, true);
    assert.equal(installed.staff_tables.find((table) => table.name === 'staff_account_requests').rls_enabled, true);
    const complete = installed.staff_functions.find((fn) => fn.name === 'complete_staff_password_change');
    assert.equal(complete.installed, true);
    assert.equal(complete.security_definer, true);
    assert.equal(complete.anon_execute, false);
    assert.equal(complete.authenticated_execute, false);
    assert.equal(complete.service_role_execute, true);
    assert.equal(installed.staff_functions.find((fn) => fn.name === 'list_staff_accounts').authenticated_execute, true);
    assert.equal(installed.staff_functions.find((fn) => fn.name === 'record_staff_sale').installed, false);
    assert.equal(installed.membership_constraints.length, 2);
    assert.equal(installed.username_indexes.length, 1);
    assert.deepEqual(await snapshot(), installedRows);
  } finally {
    await db.close();
  }
});
