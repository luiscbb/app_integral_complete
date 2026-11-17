// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('sales policies restrict modules, businesses and cancellation', async () => {
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
        is_active boolean not null, username text, allowed_modules text[] not null,
        must_change_password boolean not null default false
      );
      create function public.has_billar_role(b text, r text[]) returns boolean
      language sql stable security definer set search_path = public, pg_temp as $$
        select exists (select 1 from public.business_memberships m
          where m.user_id = auth.uid() and m.billar_id = b and m.is_active
            and m.role = any(r))
      $$;
      create table public.sales_history (
        id integer primary key, billar_id text not null,
        source_module text, cancelled boolean not null default false
      );
      create table public.products (id integer primary key, billar_id text not null);
      insert into public.products values (1, 'A'), (2, 'B');
      alter table public.products enable row level security;
      grant select on public.products to authenticated;
      create policy fixture_all on public.products for select to authenticated using (true);
      create table public.sale_details (
        id integer primary key, sale_id integer not null references public.sales_history(id),
        cancelled boolean not null default false, product_id integer
      );
      insert into public.business_memberships
        (user_id, billar_id, role, is_active, username, allowed_modules) values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, null, '{}'),
        ('00000000-0000-0000-0000-000000000002', 'B', 'admin', true, null, '{}'),
        ('00000000-0000-0000-0000-000000000003', 'A', 'manager', true, 'cajero', '{quick_sale}'),
        ('00000000-0000-0000-0000-000000000004', 'A', 'manager', true, 'informes', '{reports}'),
        ('00000000-0000-0000-0000-000000000005', 'A', 'manager', true, 'cuentas', '{personal_account}'),
        ('00000000-0000-0000-0000-000000000006', 'A', 'manager', true, null, '{}'),
        ('00000000-0000-0000-0000-000000000007', 'A', 'manager', false, 'inactivo', '{quick_sale}'),
        ('00000000-0000-0000-0000-000000000008', 'B', 'manager', true, 'otro', '{quick_sale}');
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000009', 'A', 'manager', true, 'nuevo', '{quick_sale,reports}', true);
      insert into public.sales_history values
        (1, 'A', 'quick_sale', false), (2, 'A', 'personal_account', false),
        (3, 'A', null, false), (4, 'B', 'quick_sale', false),
        (5, 'A', 'quick_sale', false);
      insert into public.sale_details values
        (1, 1, false), (2, 2, false), (3, 3, false), (4, 4, false), (5, 5, false);
      alter table public.sales_history enable row level security;
      alter table public.sale_details enable row level security;
      grant select, insert, update, delete on public.sales_history, public.sale_details to authenticated;
      create policy fixture_all on public.sales_history for all to authenticated
        using (true) with check (true);
      create policy fixture_all on public.sale_details for all to authenticated
        using (true) with check (true);
      create policy business_admin_only on public.sales_history as restrictive for all to authenticated
        using (false) with check (false);
      create policy business_admin_only on public.sale_details as restrictive for all to authenticated
        using (false) with check (false);
      create policy owner_business_scope on public.sales_history as restrictive for all to authenticated
        using (public.has_billar_role(billar_id, array['admin']::text[]))
        with check (public.has_billar_role(billar_id, array['admin']::text[]));
      create policy owner_business_scope on public.sale_details as restrictive for all to authenticated
        using (exists (select 1 from public.sales_history s
          where s.id = sale_details.sale_id
            and public.has_billar_role(s.billar_id, array['admin']::text[])))
        with check (exists (select 1 from public.sales_history s
          where s.id = sale_details.sale_id
            and public.has_billar_role(s.billar_id, array['admin']::text[])));
    `);

    const migration = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'staff_sales_guards_partial.sql'),
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
    const ids = async (table) => (await db.query(`select id from public.${table} order by id`))
      .rows.map((row) => row.id);

    await asUser(3);
    assert.deepEqual(await ids('sales_history'), [1, 5]);
    assert.deepEqual(await ids('sale_details'), []);
    for (const sql of [
      "insert into public.sales_history values (6, 'A', 'quick_sale', false)",
      "insert into public.sales_history values (6, 'B', 'quick_sale', false)",
      "insert into public.sales_history values (6, 'A', 'personal_account', false)",
      "insert into public.sales_history values (6, 'A', null, false)",
      "insert into public.sales_history values (6, 'A', 'quick_sale', true)",
      'insert into public.sale_details values (6, 2, false)',
      'insert into public.sale_details values (6, 5, false)',
      'insert into public.sale_details values (6, 5, true)',
    ]) {
      await assert.rejects(db.query(sql), /row-level security/i);
    }
    assert.equal(
      (await db.query('update public.sales_history set cancelled = true where id = 5 returning id')).rows.length,
      0,
    );
    assert.equal(
      (await db.query('delete from public.sale_details where id = 5 returning id')).rows.length,
      0,
    );
    await db.exec(`
      reset role;
      update public.business_memberships set is_active = false where username = 'cajero';
      set role authenticated;
    `);
    assert.deepEqual(await ids('sales_history'), []);
    assert.deepEqual(await ids('sale_details'), []);

    await asUser(4);
    assert.deepEqual(await ids('sales_history'), [1, 2, 3, 5]);
    assert.deepEqual(await ids('sale_details'), [1, 2, 3, 5]);
    await assert.rejects(
      db.query("insert into public.sales_history values (6, 'A', 'quick_sale', false)"),
      /row-level security/i,
    );
    assert.equal(
      (await db.query('update public.sales_history set cancelled = true where id = 1 returning id')).rows.length,
      0,
    );

    await asUser(5);
    assert.deepEqual(await ids('sales_history'), [2]);
    for (const id of [6, 7]) {
      await asUser(id);
      assert.deepEqual(await ids('sales_history'), []);
      assert.deepEqual(await ids('sale_details'), []);
    }
    await asUser(8);
    assert.deepEqual(await ids('sales_history'), [4]);

    await asUser(9);
    assert.deepEqual(await ids('sales_history'), []);
    assert.deepEqual(await ids('sale_details'), []);
    await db.exec(`
      reset role;
      update public.business_memberships set must_change_password = false where username = 'nuevo';
      set role authenticated;
    `);
    assert.deepEqual(await ids('sales_history'), [1, 2, 3, 5]);
    assert.deepEqual(await ids('sale_details'), [1, 2, 3, 5]);

    await asUser(1);
    assert.deepEqual(await ids('sales_history'), [1, 2, 3, 5]);
    await db.query("insert into public.sales_history values (6, 'A', 'quick_sale', false)");
    await db.query('insert into public.sale_details values (6, 6, false)');
    await db.query('insert into public.sale_details values (7, 6, false, 1)');
    await assert.rejects(db.query('insert into public.sale_details values (8, 6, false, 2)'), /row-level security/i);
    await assert.rejects(db.query('update public.sale_details set product_id = 2 where id = 7'), /row-level security/i);
    assert.equal(
      (await db.query('update public.sales_history set cancelled = true where id = 1 returning id')).rows.length,
      1,
    );
    await assert.rejects(
      db.query("update public.sales_history set billar_id = 'B' where id = 2"),
      /row-level security/i,
    );
    assert.equal(
      (await db.query('delete from public.sale_details where id = 1 returning id')).rows.length,
      1,
    );
    await asUser(2);
    assert.deepEqual(await ids('sales_history'), [4]);
  } finally {
    await db.close();
  }
});
