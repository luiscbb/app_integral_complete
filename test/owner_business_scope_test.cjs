// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('owner business restrictions limit existing broad policies', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated nologin;
      create role anon nologin;
      create schema auth;
      create table auth.users (id uuid primary key, email text);
      insert into auth.users (id, email)
      select ('00000000-0000-0000-0000-' || lpad(user_id::text, 12, '0'))::uuid,
        user_id::text || '@example.com'
      from generate_series(1, 6) user_id;
      create schema storage;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      create function storage.foldername(name text) returns text[] language sql immutable as $$
        select string_to_array(name, '/')
      $$;
      grant usage on schema public, auth, storage to authenticated;
      create table storage.objects (bucket_id text, name text);
      create table storage.buckets (id text primary key, public boolean not null);
      insert into storage.buckets values ('product_images', true), ('other', true);
      alter table storage.objects enable row level security;
      create table public.business_memberships (
        user_id uuid not null, billar_id text not null, role text not null,
        is_active boolean not null, must_change_password boolean not null default false,
        username text, allowed_modules text[] not null default '{}',
        email text not null default '', primary key (user_id, billar_id)
      );
      create table public.billar_settings (user_id uuid not null, billar_id text not null);
      create function public.has_billar_role(requested text, roles text[])
      returns boolean language sql stable security definer as $$
        select exists (select 1 from public.business_memberships
          where user_id = auth.uid() and billar_id = requested
          and role = any(roles) and is_active)
      $$;
      insert into public.business_memberships (user_id, billar_id, role, is_active) values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true),
        ('00000000-0000-0000-0000-000000000002', 'B', 'admin', true),
        ('00000000-0000-0000-0000-000000000003', 'A', 'admin', false),
        ('00000000-0000-0000-0000-000000000004', 'A', 'manager', true);
      update public.business_memberships set username = 'staff',
        allowed_modules = '{inventory,purchases,reports,players,personal_account,quick_sale}'
        where user_id = '00000000-0000-0000-0000-000000000004';
      insert into public.billar_settings values
        ('00000000-0000-0000-0000-000000000001', 'A'),
        ('00000000-0000-0000-0000-000000000002', 'B');
      create table public.products (
        id bigint primary key, billar_id text not null, barcode text, name text,
        description text, price double precision, cost double precision, stock double precision,
        image_path text, is_promo integer, parent_id bigint, pieces_per_unit integer,
        category text, presentation text, is_active boolean not null default true,
        stock_revision bigint not null default 0
      );
      create table public.providers (id bigint primary key, billar_id text not null);
      create table public.sales_history (id bigint primary key, billar_id text not null, source_module text);
      create table public.purchases (id bigint primary key, billar_id text not null, provider_id bigint);
      create table public.sale_details (id bigint primary key, sale_id bigint not null, product_id bigint);
      create table public.purchase_details (id bigint primary key, purchase_id bigint not null, product_id bigint);
      create table public.promo_items (
        parent_id bigint not null, child_id bigint not null, quantity integer not null default 1
      );
      create table public.provider_products (provider_id bigint not null, product_id bigint not null);
      create table public.billiard_tables (id bigint primary key, billar_id text not null);
      create table public.cash_outflows (id bigint primary key, billar_id text not null);
      create table public.cashier_sessions (id bigint primary key, billar_id text not null);
      create table public.categories (id bigint primary key, billar_id text not null);
      create table public.inventory_movements (id bigint primary key, billar_id text not null);
      create table public.match_results (id bigint primary key, billar_id text not null);
      create table public.pending_sales (id bigint primary key, billar_id text not null);
      create table public.cash_outflow_concepts (id bigint primary key, billar_id text not null);
      create table public.billar_tournaments (id bigint primary key, billar_id text not null);
      create table public.personal_clients (id bigint primary key, billar_id text not null);
      create table public.personal_customer_accounts (id bigint primary key, billar_id text not null);
      create table public.players (id bigint primary key, billar_id text not null, auth_user_id uuid);
      insert into public.products values (1,'A'), (2,'B'), (3,'A');
      insert into public.providers values (1,'A'), (2,'B');
      insert into public.sales_history values (1,'A'), (2,'B');
      insert into public.purchases values (1,'A'), (2,'B');
      insert into public.sale_details values (1,1), (2,2);
      insert into public.purchase_details values (1,1,1), (2,2,2);
      insert into public.promo_items values (1,3), (2,2);
      insert into public.provider_products values (1,1), (2,2);
      insert into public.players values
        (1,'A','00000000-0000-0000-0000-000000000005'),
        (2,'B','00000000-0000-0000-0000-000000000006');
      insert into public.personal_clients values (1,'A'), (2,'B');
      insert into public.billar_tournaments values (1,'A'), (2,'B');
      alter table public.billar_settings enable row level security;
      alter table public.business_memberships enable row level security;
      grant select,insert,update,delete on public.billar_settings to authenticated;
      grant select,insert,update,delete on public.business_memberships to authenticated, anon;
      create policy fixture_all on public.business_memberships for all to authenticated, anon
        using (true) with check (true);
      create policy fixture_all on public.billar_settings for all to authenticated
        using (true) with check (true);
      grant select, insert on public.billar_settings, public.sales_history to anon;
      create policy fixture_anon on public.billar_settings for all to anon
        using (true) with check (true);
      create policy fixture_anon on public.sales_history for all to anon
        using (true) with check (true);
      create policy business_admin_only on public.billar_settings as restrictive for all
        to authenticated using (false) with check (false);
      do $$
      declare t text;
      begin
        foreach t in array array['products','providers','sales_history','purchases',
          'sale_details','purchase_details','promo_items','provider_products',
          'billiard_tables','cash_outflows','cashier_sessions','categories',
          'inventory_movements','match_results','pending_sales','cash_outflow_concepts',
          'billar_tournaments','personal_clients','personal_customer_accounts','players'] loop
          execute format('alter table public.%I enable row level security', t);
          execute format('grant select,insert,update,delete on public.%I to authenticated', t);
          execute format('create policy legacy_open on public.%I for all to authenticated using (true) with check (true)', t);
        end loop;
      end $$;
      alter table public.sales_history disable row level security;
    `);
    const identityGuardSql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'business_owner_guard_partial.sql'), 'utf8',
    );
    await db.exec(identityGuardSql);
    await db.exec(identityGuardSql);
    const sql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'owner_business_scope_partial.sql'), 'utf8',
    );
    await db.exec(sql);
    await db.exec(sql);
    const diagnosticSql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'remote_security_diagnostic.sql'), 'utf8',
    );
    const diagnostic = (await db.query(diagnosticSql)).rows[0].diagnostic;
    assert.equal(diagnostic.relations.find(row => row.name === 'sales_history').rls_enabled, true);
    assert.equal(diagnostic.relations.find(row => row.name === 'sales_history').anon_select, true);
    assert.ok(diagnostic.policies.some(row =>
      row.tablename === 'sales_history' && row.policyname === 'owner_no_anon'));
    assert.ok(diagnostic.definer_functions.some(row => row.name === 'has_billar_role'));
    assert.deepEqual(diagnostic.image_buckets, [{id: 'product_images', public: true}]);
    assert.equal((await db.query(`select relrowsecurity from pg_class
      where oid = 'public.sales_history'::regclass`)).rows[0].relrowsecurity, true);
    await db.exec('set role anon');
    assert.deepEqual((await db.query('select * from public.sales_history')).rows, []);
    assert.deepEqual((await db.query('select * from public.billar_settings')).rows, []);
    assert.deepEqual((await db.query('select * from public.business_memberships')).rows, []);
    await assert.rejects(db.query("insert into public.sales_history values (9, 'A')"), /row-level security/i);
    await db.exec('reset role');
    await db.exec(`create policy staff_products_select on public.products
      as restrictive for select to authenticated using (true)`);
    await assert.rejects(db.exec(sql), /personal ya están instaladas/i);
    await db.exec('rollback');
    assert.equal((await db.query(`select count(*)::int as n from pg_policies
      where schemaname = 'public' and tablename = 'products'
        and policyname = 'owner_business_scope'`)).rows[0].n, 1);
    await db.exec('drop policy staff_products_select on public.products');
    await db.exec('set role authenticated');
    const asUser = id => db.query("select set_config('request.jwt.claim.sub', $1, false)", [
      `00000000-0000-0000-0000-${id.toString().padStart(12, '0')}`,
    ]);
    const ids = async table => (await db.query(`select id from public.${table} order by id`)).rows.map(r => Number(r.id));
    await asUser(1);
    assert.deepEqual((await db.query('select billar_id from public.billar_settings')).rows.map(r => r.billar_id), ['A']);
    assert.deepEqual((await db.query('select distinct billar_id from public.business_memberships')).rows.map(r => r.billar_id), ['A']);
    await assert.rejects(db.query(`insert into public.business_memberships
      (user_id, billar_id, role, is_active)
      values ('00000000-0000-0000-0000-000000000005', 'A', 'admin', true)`), /row-level security/i);
    assert.equal((await db.query(`update public.business_memberships set role = 'admin'
      where user_id = '00000000-0000-0000-0000-000000000004' returning user_id`)).rows.length, 0);
    assert.equal((await db.query(`delete from public.business_memberships
      where user_id = '00000000-0000-0000-0000-000000000004' returning user_id`)).rows.length, 0);
    for (const table of ['products', 'providers', 'sales_history', 'purchases', 'sale_details', 'purchase_details']) {
      assert.deepEqual(await ids(table), table === 'products' ? [1, 3] : [1]);
    }
    assert.equal((await db.query('select * from public.promo_items')).rows.length, 1);
    assert.equal((await db.query('select * from public.provider_products')).rows.length, 1);
    await db.query("insert into public.sales_history values (3,'A')");
    await db.query('insert into public.sale_details values (3,3)');
    await db.query('insert into public.sale_details values (4,3,1)');
    await db.query('insert into public.purchase_details values (3,1,1)');
    await db.query('insert into public.provider_products values (1,3)');
    await assert.rejects(db.query("insert into public.sales_history values (4,'B')"), /row-level security/i);
    await assert.rejects(db.query('insert into public.sale_details values (5,2)'), /row-level security/i);
    await assert.rejects(db.query('insert into public.sale_details values (5,3,2)'), /row-level security/i);
    await assert.rejects(db.query('insert into public.purchase_details values (4,2,2)'), /row-level security/i);
    await assert.rejects(db.query('insert into public.purchase_details values (4,1,2)'), /row-level security/i);
    await assert.rejects(db.query('insert into public.promo_items values (1,2)'), /row-level security/i);
    await assert.rejects(db.query('insert into public.provider_products values (1,2)'), /row-level security/i);
    await assert.rejects(db.query("update public.products set billar_id='B' where id=1"), /row-level security/i);
    assert.equal((await db.query('delete from public.sale_details where id=2 returning id')).rows.length, 0);
    await asUser(2);
    assert.deepEqual(await ids('sales_history'), [2]);
    assert.deepEqual(await ids('purchase_details'), [2]);
    await asUser(3);
    assert.deepEqual(await ids('sales_history'), []);
    assert.deepEqual(await ids('players'), []);
    await asUser(4);
    assert.equal((await db.query('select * from public.business_memberships')).rows.length, 1);
    assert.deepEqual(await ids('sales_history'), []);
    assert.deepEqual(await ids('players'), [1]);
    assert.deepEqual(await ids('personal_clients'), [1]);
    await asUser(5);
    assert.deepEqual(await ids('players'), [1]);
    assert.deepEqual(await ids('personal_clients'), []);
    assert.equal((await db.query('delete from public.players where id=1 returning id')).rows.length, 0);
    assert.deepEqual((await db.query('select billar_id from public.billar_settings')).rows, []);
    await db.query(`insert into public.billar_settings values
      ('00000000-0000-0000-0000-000000000005','C')`);
    await assert.rejects(db.query(`insert into public.billar_settings values
      ('00000000-0000-0000-0000-000000000001','C')`), /pertenece a otra cuenta/i);

    await db.exec('reset role');
    for (const file of [
      'staff_module_guards_partial.sql',
      'staff_inventory_guards_partial.sql',
      'staff_sales_guards_partial.sql',
      'staff_purchases_guards_partial.sql',
    ]) {
      await db.exec(fs.readFileSync(path.join(__dirname, '..', 'supabase', file), 'utf8'));
    }
    await db.exec('set role authenticated');
    await asUser(4);
    assert.deepEqual(await ids('products'), [1, 3]);
    assert.deepEqual(await ids('sales_history'), [1, 3]);
    assert.deepEqual(await ids('sale_details'), [1, 3, 4]);
    assert.deepEqual(await ids('purchases'), [1]);
    assert.deepEqual(await ids('purchase_details'), [1, 3]);
    assert.deepEqual(await ids('providers'), [1]);
    assert.deepEqual(await ids('personal_clients'), [1]);
    const saleProducts = (await db.query("select * from public.staff_sale_products('A')")).rows;
    assert.equal(saleProducts.length, 2);
    assert.equal(Object.hasOwn(saleProducts[0], 'cost'), false);
    await assert.rejects(db.query("insert into public.sales_history values (9, 'A', 'quick_sale')"), /row-level security/i);
    await assert.rejects(db.query("insert into public.purchases values (9, 'A', 1)"), /row-level security/i);
    await assert.rejects(db.query("select * from public.staff_sale_products('B')"), /permiso/i);
    await asUser(2);
    assert.deepEqual(await ids('products'), [2]);
    assert.deepEqual(await ids('sales_history'), [2]);
    assert.deepEqual(await ids('purchase_details'), [2]);
  } finally {
    await db.close();
  }
});
