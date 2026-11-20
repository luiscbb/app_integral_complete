const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('role templates are isolated, admin-only, versioned and do not change accounts', async () => {
  const db = new PGlite();
  const id = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
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
        is_active boolean not null, must_change_password boolean not null default false,
        allowed_modules text[] not null default '{}',
        constraint business_memberships_allowed_modules_valid check (
          allowed_modules <@ array[
            'quick_sale', 'billiard_tables', 'dine_in', 'personal_account',
            'inventory', 'purchases', 'reports', 'reports_sales',
            'reports_purchases', 'reports_cash_flow', 'reports_kardex',
            'reports_profit', 'players', 'settings'
          ]::text[]
        ),
        primary key(user_id, billar_id)
      );
    `);
    for (const [n, business, role, active, change] of [
      [1, 'A', 'admin', true, false], [2, 'B', 'admin', true, false],
      [3, 'A', 'manager', true, false], [4, 'A', 'admin', false, false],
      [5, 'A', 'admin', true, true], [6, 'A', 'admin', true, false],
    ]) {
      await db.query('insert into public.business_memberships values ($1,$2,$3,$4,$5,$6::text[])',
        [id(n), business, role, active, change, ['quick_sale']]);
    }
    const sql = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'staff_role_templates.sql'), 'utf8');
    await db.exec(sql);
    await db.exec(sql);
    const updateSql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'staff_role_templates_operational_update.sql'),
      'utf8',
    );
    await db.exec(updateSql);
    await db.exec(updateSql);
    await db.exec(`update public.business_memberships set allowed_modules =
      '{billiard_tables,billiard_tables_open,billiard_tables_consume,dine_in,dine_in_open,dine_in_consume}'
      where user_id = '${id(3)}'`);
    await assert.rejects(db.exec(`update public.business_memberships
      set allowed_modules = '{billiard_tables}' where user_id = '${id(3)}'`), /check constraint/i);
    await db.exec(`update public.business_memberships set allowed_modules = '{quick_sale}'
      where user_id = '${id(3)}'`);
    const actor = (n) => db.query("select set_config('request.jwt.claim.sub', $1, false)", [id(n)]);
    const list = async (business = 'A') =>
      (await db.query('select public.staff_role_templates_list($1) as result', [business])).rows[0].result;
    const save = async (business, template, revision, name, modules) =>
      (await db.query('select public.staff_role_template_save($1,$2,$3,$4,$5::text[]) as result',
        [business, template, revision, name, modules])).rows[0].result;
    const remove = (business, template, revision) =>
      db.query('select public.staff_role_template_delete($1,$2,$3)', [business, template, revision]);

    await db.exec('set role anon');
    await assert.rejects(list(), /permission denied/i);
    await db.exec('reset role; set role authenticated');
    await assert.rejects(db.query('select * from public.staff_role_templates'), /permission denied/i);
    for (const n of [2, 3, 4, 5]) {
      await actor(n);
      await assert.rejects(list(), /administrador activo/i);
      await assert.rejects(save('A', null, null, 'Caja', ['quick_sale']), /administrador activo/i);
    }
    await actor(1);
    assert.deepEqual(await list(), []);
    await assert.rejects(save('A', null, null, 'Inseguro', ['players']), /inválidos/i);
    await assert.rejects(save('A', null, null, 'Inseguro', ['admin']), /inválidos/i);
    await assert.rejects(save('A', null, null, 'Inseguro', ['billiard_tables']), /inválidos/i);
    await assert.rejects(save('A', null, null, 'Inseguro', ['dine_in_charge']), /inválidos/i);
    await assert.rejects(save('A', null, 0, 'Caja', []), /inválidos/i);
    const waiter = await save('A', null, null, '  Mesero  ', [
      'billiard_tables', 'billiard_tables_open', 'billiard_tables_consume',
      'dine_in', 'dine_in_open', 'dine_in_consume',
    ]);
    assert.equal(waiter.name, 'Mesero');
    assert.deepEqual(waiter.modules, [
      'billiard_tables', 'billiard_tables_consume', 'billiard_tables_open',
      'dine_in', 'dine_in_consume', 'dine_in_open',
    ]);
    const original = await save('A', null, null, 'Caja', ['quick_sale', 'inventory', 'quick_sale']);
    assert.deepEqual(original.modules, ['inventory', 'quick_sale']);
    await assert.rejects(save('A', null, null, 'caja', []), /unique/i);

    await actor(2);
    assert.deepEqual(await list('B'), []);
    const other = await save('B', null, null, 'Caja', ['purchases']);
    await assert.rejects(save('B', original.id, 0, 'Otro', []), /cambió/i);
    await assert.rejects(remove('B', original.id, 0), /cambió/i);
    await actor(6);
    const changed = await save('A', original.id, 0, 'Caja turno', ['purchases']);
    assert.equal(changed.revision, 1);
    await actor(1);
    await assert.rejects(save('A', original.id, 0, 'Perdido', []), /cambió/i);
    await assert.rejects(remove('A', original.id, 0), /cambió/i);
    assert.deepEqual((await list()).map((item) => item.name), ['Caja turno', 'Mesero']);
    await remove('A', original.id, 1);
    assert.deepEqual((await list()).map((item) => item.name), ['Mesero']);
    await actor(2);
    assert.equal((await list('B'))[0].id, other.id);
    await db.exec('reset role');
    const memberships = await db.query('select allowed_modules from public.business_memberships');
    assert.ok(memberships.rows.every((row) => row.allowed_modules.join() === 'quick_sale'));
  } finally {
    await db.close();
  }
});
