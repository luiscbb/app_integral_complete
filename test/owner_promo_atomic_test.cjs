// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('promo changes are atomic, scoped, revision guarded and idempotent', async () => {
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
      create table public.billar_settings (user_id uuid not null, billar_id text not null);
      create table public.business_memberships (
        user_id uuid not null, billar_id text not null, role text not null,
        is_active boolean not null, must_change_password boolean not null
      );
      create table public.products (
        id bigint primary key, billar_id text not null, name text not null,
        barcode text, description text, price double precision not null, cost double precision not null,
        stock double precision not null, image_path text, is_promo integer not null default 0,
        parent_id bigint, pieces_per_unit integer not null default 1, category text,
        presentation text, is_active boolean not null default true
      );
      create table public.promo_items (parent_id bigint not null, child_id bigint not null, quantity integer not null);
      alter table public.products enable row level security;
      alter table public.promo_items enable row level security;
      grant select, insert, update, delete on public.products, public.promo_items to authenticated;
      create policy product_all on public.products for all to authenticated using (true) with check (true);
      create policy promo_all on public.promo_items for all to authenticated using (true) with check (true);
      insert into public.billar_settings values ('00000000-0000-0000-0000-000000000001', 'A');
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, false),
        ('00000000-0000-0000-0000-000000000002', 'A', 'manager', true, false);
      insert into public.products (id, billar_id, name, price, cost, stock, is_promo) values
        (1, 'A', 'Uno', 5, 2, 10, 0), (2, 'A', 'Dos', 7, 3, 10, 0),
        (3, 'B', 'Ajeno', 7, 3, 10, 0), (10, 'A', 'Promo', 10, 4, 0, 1);
      insert into public.promo_items values (10, 1, 1);
    `);
    for (const file of ['product_stock_conflict_guard_partial.sql', 'owner_promo_atomic_partial.sql']) {
      const sql = fs.readFileSync(path.join(__dirname, '..', 'supabase', file), 'utf8');
      await db.exec(sql);
      await db.exec(sql);
    }
    await db.exec(`
      set role authenticated;
      select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
    `);
    const data = { name: 'PROMO NUEVA', price: 20, cost: 8, is_active: true,
      barcode: null, description: '', image_path: null, category: '', presentation: '' };
    const parts = [{ product_id: 1, quantity: 2 }, { product_id: 2, quantity: 1 }];
    const request = (id, productId, revision, product = data, components = parts, billar = 'A') =>
      db.query('select public.sync_owner_promo($1::uuid, $2, $3, $4, $5::jsonb, $6::jsonb) as revision',
        [id, billar, productId, revision, JSON.stringify(product), JSON.stringify(components)]);
    const first = '10000000-0000-0000-0000-000000000001';
    await assert.rejects(request(first, 10, 0), /permission denied/i);
    await assert.rejects(db.query('select public.read_owner_promo_snapshot($1, $2)', ['A', 10]), /permission denied/i);
    await assert.rejects(db.query(
      "insert into public.products (id, billar_id, name, price, cost, stock, is_promo) values (12, 'A', 'X', 1, 0, 0, 1)",
    ), /row-level security/i);
    assert.equal((await db.query('delete from public.promo_items where parent_id = 10 returning parent_id')).rows.length, 0);
    assert.equal((await db.query("update public.products set price = 100 where id = 10 returning id")).rows.length, 0);
    await db.exec(`
      reset role;
      grant execute on function public.sync_owner_promo(uuid, text, bigint, bigint, jsonb, jsonb) to authenticated;
      grant execute on function public.read_owner_promo_snapshot(text, bigint) to authenticated;
      set role authenticated;
    `);
    assert.equal(Number((await request(first, 10, 0)).rows[0].revision), 1);
    assert.equal(Number((await request(first, 10, 0)).rows[0].revision), 1);
    await assert.rejects(request(first, 10, 0, { ...data, price: 21 }), /ya fue utilizado/i);
    await assert.rejects(request('10000000-0000-0000-0000-000000000002', 10, 0), /cambió/i);
    await assert.rejects(
      request('10000000-0000-0000-0000-000000000002', 10, 1, data, [{ product_id: 3, quantity: 1 }]),
      /no pertenece/i,
    );
    const product = (await db.query('select price, stock_revision from public.products where id = 10')).rows[0];
    assert.equal(product.price, 20);
    assert.equal(Number(product.stock_revision), 1);
    assert.deepEqual((await db.query('select child_id, quantity from public.promo_items where parent_id = 10 order by child_id'))
      .rows.map((r) => [Number(r.child_id), r.quantity]), [[1, 2], [2, 1]]);
    const snapshot = (await db.query(
      'select public.read_owner_promo_snapshot($1, $2) as snapshot', ['A', 10],
    )).rows[0].snapshot;
    assert.equal(snapshot.product.price, 20);
    assert.equal(snapshot.product.stock_revision, 1);
    assert.deepEqual(snapshot.components, [{ child_id: 1, quantity: 2 }, { child_id: 2, quantity: 1 }]);
    await assert.rejects(db.query('select public.read_owner_promo_snapshot($1, $2)', ['B', 10]), /administrador/i);
    await assert.rejects(db.query('select public.read_owner_promo_snapshot($1, $2)', ['A', 3]), /no existe/i);
    await db.exec(`reset role; insert into public.promo_items values (10, 3, 1); set role authenticated;`);
    await assert.rejects(db.query('select public.read_owner_promo_snapshot($1, $2)', ['A', 10]), /componentes/i);
    await db.exec(`reset role; delete from public.promo_items where parent_id = 10 and child_id = 3; set role authenticated;`);
    await assert.rejects(
      request('10000000-0000-0000-0000-000000000003', 10, 1, data,
        [{ product_id: 1, quantity: 1 }, { product_id: 1, quantity: 2 }]),
      /inválido/i,
    );
    const deviceA = (await db.query(
      'select public.read_owner_promo_snapshot($1, $2) as snapshot', ['A', 10],
    )).rows[0].snapshot;
    const deviceB = (await db.query(
      'select public.read_owner_promo_snapshot($1, $2) as snapshot', ['A', 10],
    )).rows[0].snapshot;
    assert.equal(deviceA.product.stock_revision, deviceB.product.stock_revision);
    const updated = { ...data, name: 'DISPOSITIVO A', price: 25 };
    const updatedParts = [{ product_id: 2, quantity: 4 }];
    assert.equal(Number((await request(
      '10000000-0000-0000-0000-000000000006', 10,
      deviceA.product.stock_revision, updated, updatedParts,
    )).rows[0].revision), 2);
    await assert.rejects(request(
      '10000000-0000-0000-0000-000000000007', 10,
      deviceB.product.stock_revision, { ...data, name: 'DISPOSITIVO B' }, parts,
    ), /cambió/i);
    const afterConflict = (await db.query(
      'select public.read_owner_promo_snapshot($1, $2) as snapshot', ['A', 10],
    )).rows[0].snapshot;
    assert.equal(afterConflict.product.name, 'DISPOSITIVO A');
    assert.equal(afterConflict.product.price, 25);
    assert.equal(afterConflict.product.stock_revision, 2);
    assert.deepEqual(afterConflict.components, [{ child_id: 2, quantity: 4 }]);
    assert.equal(Number((await request(
      '10000000-0000-0000-0000-000000000008', 10, 2,
      { ...updated, is_active: false }, updatedParts,
    )).rows[0].revision), 3);
    const archived = (await db.query(
      'select public.read_owner_promo_snapshot($1, $2) as snapshot', ['A', 10],
    )).rows[0].snapshot;
    assert.equal(archived.product.is_active, false);
    assert.deepEqual(archived.components, [{ child_id: 2, quantity: 4 }]);
    assert.equal(Number((await request('10000000-0000-0000-0000-000000000004', 11, null)).rows[0].revision), 0);
    await db.query("select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false)");
    await assert.rejects(db.query('select public.read_owner_promo_snapshot($1, $2)', ['A', 10]), /administrador/i);
    await assert.rejects(
      request('10000000-0000-0000-0000-000000000005', 10, 1), /administrador/i,
    );
  } finally {
    await db.close();
  }
});
