// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('inventory access is isolated and sale products do not expose costs', async () => {
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
        username text, allowed_modules text[] not null
      );
      create function public.has_billar_role(b text, r text[]) returns boolean
      language sql stable security definer as $$
        select exists (select 1 from public.business_memberships m
          where m.user_id = auth.uid() and m.billar_id = b and m.is_active
            and m.role = any(r))
      $$;
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, false, null, '{}'),
        ('00000000-0000-0000-0000-000000000002', 'B', 'admin', true, false, null, '{}'),
        ('00000000-0000-0000-0000-000000000003', 'A', 'manager', true, false, 'caja', '{quick_sale}'),
        ('00000000-0000-0000-0000-000000000004', 'A', 'manager', true, false, 'inventario', '{inventory}'),
        ('00000000-0000-0000-0000-000000000005', 'A', 'manager', false, false, 'inactivo', '{quick_sale,inventory}'),
        ('00000000-0000-0000-0000-000000000006', 'A', 'manager', true, true, 'nuevo', '{quick_sale,inventory}'),
        ('00000000-0000-0000-0000-000000000007', 'A', 'manager', true, false, null, '{}'),
        ('00000000-0000-0000-0000-000000000008', 'A', 'admin', true, false, null, '{}'),
        ('00000000-0000-0000-0000-000000000008', 'B', 'admin', true, false, null, '{}'),
        ('00000000-0000-0000-0000-000000000009', 'A', 'manager', true, false, 'compras', '{purchases}'),
        ('00000000-0000-0000-0000-000000000010', 'A', 'manager', true, false, 'informes', '{reports}');
      create table public.products (
        id bigint primary key, billar_id text not null, barcode text, name text not null,
        description text, price double precision, cost double precision, stock double precision,
        image_path text, is_promo integer, parent_id bigint, pieces_per_unit integer,
        category text, presentation text, is_active boolean not null,
        stock_revision bigint not null default 0
      );
      create table public.promo_items (
        parent_id bigint not null, child_id bigint not null, quantity integer not null
      );
      insert into public.products values
        (1, 'A', null, 'A', null, 10, 4, 5, null, 0, null, 1, null, null, true),
        (2, 'B', null, 'B', null, 20, 7, 5, null, 0, null, 1, null, null, true),
        (3, 'A', null, 'Archivado', null, 15, 5, 5, null, 0, null, 1, null, null, false);
      alter table public.products enable row level security;
      grant select, insert, update, delete on public.products to authenticated;
      create policy fixture_all on public.products for all to authenticated
        using (true) with check (true);
      create policy business_admin_only on public.products as restrictive for all to authenticated
        using (false) with check (false);
      create policy owner_business_scope on public.products as restrictive for all to authenticated
        using (public.has_billar_role(billar_id, array['admin']::text[]))
        with check (public.has_billar_role(billar_id, array['admin']::text[]));
    `);
    const sql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'staff_inventory_guards_partial.sql'), 'utf8',
    );
    await db.exec(sql);
    await db.exec(sql);
    const asUser = id => db.query(
      "select set_config('request.jwt.claim.sub', $1, false)",
      [`00000000-0000-0000-0000-${id.toString().padStart(12, '0')}`],
    );
    const ids = async () => (await db.query('select id from public.products order by id'))
      .rows.map(row => Number(row.id));
    const saleProducts = billar => db.query('select * from public.staff_sale_products($1)', [billar]);
    await db.exec('set role authenticated');
    await asUser(3);
    assert.deepEqual(await ids(), []);
    const products = (await saleProducts('A')).rows;
    assert.equal(products.length, 1);
    assert.equal(Number(products[0].id), 1);
    assert.equal(products[0].price, 10);
    assert.equal(Object.hasOwn(products[0], 'cost'), false);
    await assert.rejects(saleProducts('B'), /permiso/i);
    await assert.rejects(db.query("insert into public.products (id, billar_id, name, is_active) values (4, 'A', 'X', true)"), /row-level security/i);
    assert.equal((await db.query('update public.products set stock = 9 where id = 1 returning id')).rows.length, 0);

    for (const id of [4, 9, 10]) {
      await asUser(id);
      assert.deepEqual(await ids(), [1, 3]);
      assert.equal((await db.query('update public.products set cost = 1 where id = 1 returning id')).rows.length, 0);
      await assert.rejects(saleProducts('A'), /permiso/i);
    }
    for (const id of [5, 6, 7]) {
      await asUser(id);
      assert.deepEqual(await ids(), []);
      await assert.rejects(saleProducts('A'), /permiso/i);
    }
    await asUser(1);
    assert.deepEqual(await ids(), [1, 3]);
    await db.query('update public.products set stock = 6 where id = 1');
    await assert.rejects(db.query("update public.products set billar_id = 'B' where id = 1"), /identidad/i);
    await asUser(2);
    assert.deepEqual(await ids(), [2]);
    await asUser(8);
    await assert.rejects(db.query("update public.products set billar_id = 'B' where id = 1"), /identidad/i);
    await asUser(3);
    await db.exec(`
      reset role;
      insert into public.products
        (id, billar_id, name, price, cost, stock, is_promo, parent_id, pieces_per_unit, is_active)
      values
        (11, 'A', 'Presentacion', 20, 8, 999, 0, 1, 2, true),
        (12, 'A', 'Promo', 25, 10, 999, 1, null, 1, true),
        (13, 'A', 'Promo sin componentes', 25, 10, 999, 1, null, 1, true),
        (14, 'A', 'Promo ajena', 25, 10, 999, 1, null, 1, true),
        (15, 'A', 'Presentacion ajena', 20, 8, 999, 0, 2, 1, true),
        (16, 'A', 'Promo archivada', 25, 10, 999, 1, null, 1, true),
        (17, 'A', 'Promo invalida', 25, 10, 999, 1, null, 1, true),
        (18, 'A', 'Presentacion invalida', 25, 10, 999, 0, 1, 0, true);
      insert into public.promo_items values
        (12, 1, 1), (12, 1, 2), (14, 1, 1), (14, 2, 1),
        (16, 3, 1), (17, 1, 0);
      set role authenticated;
    `);
    const catalog = (await saleProducts('A')).rows;
    const stock = id => catalog.find(product => Number(product.id) === id).stock;
    assert.equal(stock(1), 6);
    assert.equal(stock(11), 3);
    assert.equal(stock(12), 2);
    const promotion = catalog.find(product => Number(product.id) === 12);
    assert.deepEqual(promotion.components, [{ product_id: 1, quantity: 3 }]);
    assert.equal(promotion.inventory_stock, 999);
    assert.equal(Number(promotion.stock_revision), 0);
    for (const id of [13, 14, 15, 16, 17, 18]) assert.equal(stock(id), 0);
    for (const id of [13, 14, 16, 17]) {
      assert.deepEqual(catalog.find(product => Number(product.id) === id).components, []);
    }
    for (const product of catalog) {
      assert.equal(product.billar_id, 'A');
      assert.equal(Object.hasOwn(product, 'cost'), false);
    }
    await db.exec("reset role; update public.business_memberships set allowed_modules = '{}' where username = 'caja'; set role authenticated");
    await assert.rejects(saleProducts('A'), /permiso/i);
    await db.exec('set role anon');
    await assert.rejects(saleProducts('A'), /permission denied/i);
  } finally {
    await db.close();
  }
});
