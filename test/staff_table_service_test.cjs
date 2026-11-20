const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('table openings and consumptions are attributed, idempotent and preserve conflicts', async () => {
  const db = new PGlite();
  const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const service = (n) => `10000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const request = (n) => `20000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const time = '2020-11-17T18:00:00Z';
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
        username text, allowed_modules text[] not null,
        primary key (user_id, billar_id)
      );
      create table public.billiard_tables (
        id bigint not null, billar_id text not null, name text not null,
        table_type text not null, is_occupied integer not null default 0,
        start_time timestamptz, orders text default '[]', is_deleted integer not null default 0,
        primary key (billar_id, id)
      );
      create table public.billar_settings (
        billar_id text not null, hourly_rate double precision not null
      );
      insert into public.billar_settings values ('A',0),('B',0);
      grant select, insert, update, delete on public.billiard_tables to authenticated;
    `);
    for (const [n, business, role, active, change, username, permissions] of [
      [1, 'A', 'manager', true, false, 'uno', ['billiard_tables', 'billiard_tables_open', 'billiard_tables_consume']],
      [2, 'A', 'manager', true, false, 'dos', ['billiard_tables', 'billiard_tables_open', 'billiard_tables_consume']],
      [3, 'A', 'manager', true, false, 'encargado', ['billiard_tables', 'billiard_tables_view_all', 'billiard_tables_charge', 'dine_in', 'dine_in_charge', 'dine_in_view_all']],
      [4, 'A', 'admin', true, false, null, []],
      [5, 'B', 'manager', true, false, 'otro', ['billiard_tables', 'billiard_tables_open', 'billiard_tables_consume', 'billiard_tables_view_all']],
      [6, 'A', 'manager', false, false, 'inactivo', ['billiard_tables', 'billiard_tables_open']],
      [7, 'A', 'manager', true, true, 'cambio', ['billiard_tables', 'billiard_tables_open']],
      [8, 'A', 'manager', true, false, 'sin', ['quick_sale']],
      [9, 'A', 'manager', true, false, 'solo_apertura', ['billiard_tables', 'billiard_tables_open']],
      [10, 'A', 'manager', true, false, 'comanda', ['dine_in', 'dine_in_open', 'dine_in_consume']],
      [11, 'A', 'manager', true, false, 'sin_padre', ['billiard_tables_open']],
      [12, 'A', 'manager', true, false, 'solo_cobro', ['billiard_tables', 'billiard_tables_charge']],
      [13, 'A', 'manager', true, false, 'cajero_sin_ver', ['dine_in', 'dine_in_charge']],
    ]) {
      await db.query('insert into public.business_memberships values ($1,$2,$3,$4,$5,$6,$7::text[])',
        [id(n), business, role, active, change, username, permissions]);
    }
    await db.exec(`
      insert into public.billiard_tables (id,billar_id,name,table_type,is_occupied,orders,is_deleted) values
        (1,'A','Mesa 1','Billar',0,'[]',0), (2,'A','Mesa 2','Billar',1,'[]',0),
        (3,'A','Mesa 3','Billar',0,'[{"productId":99}]',0),
        (4,'A','Mesa 4','Billar',0,'[]',1), (5,'A','Comanda 1','Comanda',0,'[]',0),
        (6,'A','Mesa 6','Billar',0,'[]',0), (7,'A','Mesa 7','Billar',0,'[]',0),
        (8,'A','Pool 1','Pool',0,'[]',0),
        (1,'B','Mesa B','Billar',0,'[]',0);
    `);
    const sql = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'staff_table_service_partial.sql'), 'utf8');
    await db.exec(sql);
    await db.exec(sql);
    const conflictReviewSql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'staff_table_conflict_review_partial.sql'),
      'utf8',
    );
    await db.exec(conflictReviewSql);
    await db.exec(conflictReviewSql);
    const actor = (n) => db.query("select set_config('request.jwt.claim.sub', $1, false)", [id(n)]);
    const open = async (n, business = 'A', table = 1, type = 'Billar', opened = time) =>
      (await db.query('select public.staff_table_open($1,$2,$3,$4,$5) as data',
        [service(n), business, table, type, opened])).rows[0].data;
    const add = async (n, s, business = 'A', type = 'Billar', product = 7, name = 'Agua', quantity = 2, price = 12) =>
      (await db.query('select public.staff_table_add_consumption($1,$2,$3,$4,$5,$6,$7,$8,$9) as data',
        [request(n), business, service(s), type, product, name, quantity, price, time])).rows[0].data;
    const conflicts = async (business = 'A', type = 'Billar', before = null) =>
      (await db.query('select public.staff_table_conflicts($1,$2,$3) as data',
        [business, type, before])).rows[0].data;
    const conflictItems = async (s, business = 'A', type = 'Billar', before = null) =>
      (await db.query('select public.staff_table_conflict_consumptions($1,$2,$3,$4) as data',
        [business, type, service(s), before])).rows[0].data;
    const reviewOpening = async (s, business = 'A', type = 'Billar') =>
      (await db.query('select public.staff_table_review_opening_conflict($1,$2,$3) as data',
        [business, type, service(s)])).rows[0].data;
    const visibleTables = async (business = 'A', type = 'Billar') =>
      (await db.query('select public.staff_table_visible_tables($1,$2) as data',
        [business, type])).rows[0].data;
    const checkoutSnapshot = async (s, business = 'A', type = 'Billar', revision = null, before = null) =>
      (await db.query('select public.staff_table_checkout_snapshot($1,$2,$3,$4,$5) as data',
        [business, type, service(s), revision, before])).rows[0].data;

    await db.exec('set role anon');
    await assert.rejects(open(1), /permission denied/i);
    await assert.rejects(checkoutSnapshot(1), /permission denied/i);
    await db.exec('reset role; set role authenticated');
    await actor(1);
    await assert.rejects(db.query('select * from public.staff_table_service_requests'), /permission denied/i);
    await assert.rejects(db.query("select public.staff_table_require_permission('A','billiard_tables_open')"), /permission denied/i);
    for (const n of [5, 6, 7, 8, 11]) {
      await actor(n);
      await assert.rejects(open(1), /Sin permiso/i);
    }
    await actor(1);
    assert.equal((await open(1)).state, 'active');
    assert.deepEqual(await open(1), await open(1));
    await assert.rejects(open(1, 'A', 6), /identificador/i);
    const firstItem = await add(1, 1);
    assert.equal(firstItem.service_state, 'active');
    assert.deepEqual(await add(1, 1), firstItem);
    const waiterTables = await visibleTables();
    assert.deepEqual(waiterTables.items.map((table) => table.id), [1, 6, 7, 8]);
    assert.equal(waiterTables.items[0].service_id, service(1));
    assert.equal(waiterTables.items[0].service_actor_id, id(1));
    assert.deepEqual(waiterTables.items[0].service_items.map((item) => item.productName), ['Agua']);
    await actor(2);
    const otherWaiterTables = await visibleTables();
    assert.deepEqual(otherWaiterTables.items.map((table) => table.id), [6, 7, 8]);
    assert.equal(otherWaiterTables.items.some((table) => table.id === 1), false);
    await actor(8);
    await assert.rejects(visibleTables(), /Sin permiso/i);
    await actor(3);
    const cashierTables = await visibleTables();
    assert.deepEqual(cashierTables.items.map((table) => table.id), [1, 2, 3, 6, 7, 8]);
    assert.deepEqual(cashierTables.items[0].service_items.map((item) => item.productName), ['Agua']);
    await actor(4);
    assert.deepEqual((await visibleTables()).items.map((table) => table.id), [1, 2, 3, 6, 7, 8]);
    await actor(5);
    assert.deepEqual((await visibleTables('B')).items.map((table) => table.id), [1]);
    await actor(1);
    await assert.rejects(add(1, 1, 'A', 'Billar', 7, 'Agua', 3), /identificador/i);
    await assert.rejects(add(2, 1, 'A', 'Billar', 7, 'Agua', 'NaN'), /inválidos/i);
    await assert.rejects(add(2, 1, 'A', 'Billar', 7, 'Agua', 1, 'Infinity'), /inválidos/i);
    await assert.rejects(add(2, 1, 'A', 'Billar', 7, 'x'.repeat(256)), /inválidos/i);
    await assert.rejects(conflicts(), /Sin permiso/i);
    await assert.rejects(conflictItems(1), /Sin permiso/i);

    await actor(2);
    const losingOpen = await open(2);
    assert.equal(losingOpen.state, 'conflict');
    assert.deepEqual(await open(2), losingOpen);
    assert.equal((await add(2, 2)).service_state, 'conflict');
    await add(3, 2, 'A', 'Billar', 8, 'Refresco', 1, 15);
    await assert.rejects(add(4, 1), /no está disponible/i);
    await assert.rejects(open(1), /identificador/i);
    await db.exec(`reset role; update public.business_memberships set is_active=false where user_id='${id(2)}'; set role authenticated`);
    await assert.rejects(add(2, 2), /Sin permiso/i);
    await db.exec(`reset role; update public.business_memberships set is_active=true where user_id='${id(2)}'; set role authenticated`);
    assert.equal((await open(3, 'A', 2)).state, 'conflict');
    assert.equal((await open(4, 'A', 3)).state, 'conflict');
    assert.equal((await open(5, 'A', 4)).state, 'conflict');
    assert.equal((await open(6, 'A', 999)).state, 'conflict');

    await actor(9);
    const noConsumption = await open(7, 'A', 6);
    assert.equal(noConsumption.state, 'active');
    await assert.rejects(add(5, 7), /Sin permiso/i);
    const poolService = await open(12, 'A', 8);
    assert.equal(poolService.state, 'active');
    assert.equal(poolService.table_type, 'Billar');
    await actor(3);
    assert.equal((await checkoutSnapshot(12)).table_id, 8);
    await actor(10);
    assert.equal((await open(8, 'A', 5, 'Comanda')).state, 'active');
    assert.equal((await add(6, 8, 'A', 'Comanda')).service_state, 'active');
    const waiterOrders = await visibleTables('A', 'Comanda');
    assert.deepEqual(waiterOrders.items.map((table) => table.id), [5]);
    assert.equal(waiterOrders.items[0].service_id, service(8));
    await assert.rejects(add(7, 8, 'A', 'Billar'), /Sin permiso/i);

    await actor(3);
    const review = await conflicts();
    assert.equal(review.has_more, false);
    const conflicted = review.items.find((item) => item.service_id === service(2));
    assert.equal(conflicted.actor_id, id(2));
    const conflictDetail = await conflictItems(2);
    assert.deepEqual(conflictDetail.items.map((item) => item.product_name), ['Refresco', 'Agua']);
    assert.equal(conflictDetail.items[1].quantity, 2);
    assert.equal(conflictDetail.has_more, false);
    await assert.rejects(conflictItems(1), /no está disponible/i);
    await actor(13);
    await assert.rejects(conflicts('A', 'Comanda'), /Sin permiso/i);
    await actor(5);
    assert.deepEqual((await conflicts('B')).items, []);
    await assert.rejects(conflictItems(2, 'B'), /no está disponible/i);
    await actor(4);
    assert.equal((await conflicts()).items.length, 5);
    await assert.rejects(db.query(
      "update public.billiard_tables set is_occupied=0, start_time=null, orders='[]' where billar_id='A' and id=1",
    ), (error) => error.code === 'PST01' && /servicio de personal activo/i.test(error.message));
    await assert.rejects(db.query(
      "update public.billiard_tables set is_deleted=1 where billar_id='A' and id=1",
    ), /servicio de personal activo/i);
    await assert.rejects(db.query(
      "delete from public.billiard_tables where billar_id='A' and id=1",
    ), /servicio de personal activo/i);
    await assert.rejects(db.query(`
      insert into public.billiard_tables (id,billar_id,name,table_type,is_occupied,orders)
      values (1,'A','Mesa 1','Billar',0,'[]')
      on conflict (billar_id,id) do update set is_occupied=excluded.is_occupied, start_time=null
    `), /servicio de personal activo/i);
    assert.equal((await db.query(
      "update public.billiard_tables set name=name where billar_id='A' and id=1 returning id",
    )).rows.length, 1);
    assert.equal((await db.query(
      "update public.billiard_tables set name='Mesa B actualizada' where billar_id='B' and id=1 returning id",
    )).rows.length, 1);

    await db.exec('reset role');
    await db.exec(`
      create function public.fixture_fail_open() returns trigger language plpgsql as $$
      begin if new.id = 7 then raise exception 'fixture failure'; end if; return new; end $$;
      create trigger fixture_fail_open before update on public.billiard_tables
        for each row execute function public.fixture_fail_open();
      set role authenticated;
    `);
    await actor(1);
    await assert.rejects(open(9, 'A', 7), /fixture failure/i);
    await db.exec('reset role');
    assert.equal((await db.query('select count(*)::int as n from public.staff_table_service_requests where service_id=$1', [service(9)])).rows[0].n, 0);
    await db.exec('drop trigger fixture_fail_open on public.billiard_tables; set role authenticated');
    assert.equal((await open(9, 'A', 7)).state, 'active');
    await db.exec('reset role');
    await db.exec(`
      insert into public.staff_table_service_requests
        (service_id,billar_id,actor_id,table_id,table_type,opened_at,state,confirmed_at)
      select ('30000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
        'A','${id(2)}',1000+n,'Billar',now(),'conflict',now()
      from generate_series(1,52) n;
      set role authenticated;
    `);
    await actor(3);
    const page1 = await conflicts();
    assert.equal(page1.items.length, 50);
    assert.equal(page1.has_more, true);
    const page2 = await conflicts('A', 'Billar', page1.items.at(-1).ordinal);
    assert.equal(page2.items.length, 7);
    assert.equal(page2.has_more, false);
    assert.equal(new Set([...page1.items, ...page2.items].map((item) => item.service_id)).size, 57);
    await db.exec('reset role');
    const tables = await db.query("select id,is_occupied,orders from public.billiard_tables where billar_id='A' order by id");
    assert.equal(tables.rows[0].is_occupied, 1);
    assert.equal(tables.rows[0].orders, '[]');
    assert.equal(tables.rows[2].orders, '[{"productId":99}]');
    const counts = await db.query('select count(*)::int as n from public.staff_table_service_consumptions');
    assert.equal(counts.rows[0].n, 4);
    await db.exec(`
      insert into public.staff_table_service_consumptions
        (request_id,service_id,billar_id,actor_id,product_id,product_name,quantity,price,recorded_at)
      select ('40000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
        '${service(2)}','A','${id(2)}',1000+n,'Producto',1,10,now()
      from generate_series(1,52) n;
      set role authenticated;
    `);
    await actor(3);
    const itemPage1 = await conflictItems(2);
    assert.equal(itemPage1.items.length, 50);
    assert.equal(itemPage1.has_more, true);
    const itemPage2 = await conflictItems(2, 'A', 'Billar', itemPage1.items.at(-1).ordinal);
    assert.equal(itemPage2.items.length, 4);
    assert.equal(itemPage2.has_more, false);
    assert.equal(new Set([...itemPage1.items, ...itemPage2.items].map((item) => item.request_id)).size, 54);

    await actor(1);
    await assert.rejects(checkoutSnapshot(1), /Sin permiso/i);
    await actor(12);
    await assert.rejects(checkoutSnapshot(1), /Sin permiso/i);
    await actor(3);
    const checkout = await checkoutSnapshot(1);
    assert.equal(checkout.service_id, service(1));
    assert.equal(checkout.table_id, 1);
    assert.equal(checkout.actor_id, id(1));
    assert.equal(checkout.item_count, 1);
    assert.equal(checkout.time_cost, 0);
    assert.equal(checkout.total, 24);
    assert.ok(Date.parse(checkout.quoted_at) >= Date.parse(checkout.opened_at));
    assert.equal(checkout.items[0].request_id, request(1));
    assert.equal(checkout.has_more, false);
    const comandaQuote = await checkoutSnapshot(8, 'A', 'Comanda');
    assert.equal(comandaQuote.item_count, 1);
    assert.equal(comandaQuote.time_cost, 0);
    assert.equal(comandaQuote.total, 24);
    await assert.rejects(checkoutSnapshot(2), /servicio activo no está disponible/i);
    await assert.rejects(checkoutSnapshot(1, 'B'), /Sin permiso/i);
    await assert.rejects(checkoutSnapshot(1, 'A', 'Billar', null, 1), /inválida/i);
    await db.exec(`
      reset role;
      alter table public.billiard_tables disable trigger billiard_tables_staff_active_guard;
      update public.billiard_tables set start_time=null where billar_id='A' and id=6;
      alter table public.billiard_tables enable trigger billiard_tables_staff_active_guard;
      set role authenticated;
    `);
    await assert.rejects(checkoutSnapshot(7), /estado de la mesa requiere revisión/i);
    await db.exec(`
      reset role;
      alter table public.billiard_tables disable trigger billiard_tables_staff_active_guard;
      update public.billiard_tables set start_time='${time}' where billar_id='A' and id=6;
      alter table public.billiard_tables enable trigger billiard_tables_staff_active_guard;
      set role authenticated;
    `);
    await actor(1);
    await add(8, 1, 'A', 'Billar', 8, 'Refresco', 1, 15);
    await actor(3);
    await assert.rejects(checkoutSnapshot(1, 'A', 'Billar', checkout.revision),
      (error) => error.code === 'PST02');
    await db.exec(`reset role; update public.business_memberships set is_active=false where user_id='${id(3)}'; set role authenticated`);
    await assert.rejects(checkoutSnapshot(1), /Sin permiso/i);
    await db.exec(`reset role; update public.business_memberships set is_active=true where user_id='${id(3)}'`);
    await db.exec(`
      insert into public.staff_table_service_consumptions
        (request_id,service_id,billar_id,actor_id,product_id,product_name,quantity,price,recorded_at)
      select ('50000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
        '${service(1)}','A','${id(1)}',1000+n,'Producto',1,10,now()
      from generate_series(1,51) n;
      set role authenticated;
    `);
    const checkoutPage1 = await checkoutSnapshot(1);
    assert.equal(checkoutPage1.item_count, 53);
    assert.equal(checkoutPage1.items.length, 50);
    assert.equal(checkoutPage1.has_more, true);
    const checkoutPage2 = await checkoutSnapshot(
      1, 'A', 'Billar', checkoutPage1.revision, checkoutPage1.items.at(-1).ordinal,
    );
    assert.equal(checkoutPage2.items.length, 3);
    assert.equal(checkoutPage2.has_more, false);
    assert.equal(new Set([...checkoutPage1.items, ...checkoutPage2.items]
      .map((item) => item.request_id)).size, 53);
    await db.exec('reset role');
    const unchanged = (await db.query(
      "select is_occupied, orders from public.billiard_tables where billar_id='A' and id=1",
    )).rows[0];
    assert.deepEqual(unchanged, { is_occupied: 1, orders: '[]' });

    // Simulate an atomic checkout after the first item was recorded.
    await db.query("update public.staff_table_service_requests set state='closed' where service_id=$1", [service(1)]);
    await db.exec("update public.billiard_tables set is_occupied=0, start_time=null where billar_id='A' and id=1; set role authenticated");
    await actor(1);
    assert.equal((await open(1)).state, 'closed');
    const retriedBeforeClose = await add(1, 1);
    assert.equal(retriedBeforeClose.service_state, 'closed');
    assert.equal(retriedBeforeClose.late, false);
    const lateItem = await add(10, 1, 'A', 'Billar', 9, 'Jugo', 2, 20);
    assert.equal(lateItem.service_state, 'closed');
    assert.equal(lateItem.late, true);
    assert.deepEqual(await add(10, 1, 'A', 'Billar', 9, 'Jugo', 2, 20), lateItem);
    await assert.rejects(add(10, 1, 'A', 'Billar', 9, 'Jugo', 3, 20), /identificador/i);
    await actor(2);
    await assert.rejects(add(11, 1), /no está disponible/i);
    await actor(3);
    const lateDetails = await conflictItems(1);
    assert.deepEqual(lateDetails.items.map((item) => item.request_id), [request(10)]);
    const laterPage = await conflicts('A', 'Billar', page1.items.at(-1).ordinal);
    const lateConflict = laterPage.items.find((item) => item.service_id === service(1));
    assert.equal(lateConflict.reason, 'late_consumption');
    await assert.rejects(checkoutSnapshot(1), /servicio activo no está disponible/i);
    await actor(1);
    await assert.rejects(reviewOpening(2), /Sin permiso/i);
    await actor(3);
    const reviewedOpening = await reviewOpening(2);
    assert.equal(reviewedOpening.state, 'conflict');
    assert.equal(reviewedOpening.reviewed_by, id(3));
    assert.ok(Date.parse(reviewedOpening.reviewed_at));
    assert.deepEqual(await reviewOpening(2), reviewedOpening);
    const remaining = await conflicts();
    assert.equal(remaining.items.some((item) => item.service_id === service(2)), false);
    await actor(2);
    assert.equal((await open(2)).state, 'conflict');
    await db.exec('reset role');
    assert.equal((await db.query(
      "select is_occupied from public.billiard_tables where billar_id='A' and id=1",
    )).rows[0].is_occupied, 0);
    await db.exec('set role authenticated');
    await actor(3);
    await db.exec('reset role');
    assert.equal((await db.query("select is_occupied from public.billiard_tables where billar_id='A' and id=1")).rows[0].is_occupied, 0);
  } finally {
    await db.close();
  }
});
