// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('purchases and providers are isolated by business and module', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated nologin;
      create role anon nologin;
      create role service_role nologin;
      create schema auth;
      create schema storage;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      create function storage.foldername(name text) returns text[] language sql immutable as $$
        select string_to_array(name, '/')
      $$;
      grant usage on schema public, auth, storage to authenticated;
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
      create table public.players (id text, billar_id text, auth_user_id uuid);
      create table public.billar_tournaments (id text, billar_id text);
      create table public.personal_clients (id text, billar_id text);
      create table public.personal_customer_accounts (id text, billar_id text);
      create table storage.objects (bucket_id text, name text);
      create table public.products (id integer primary key, billar_id text not null);
      create table public.providers (id integer primary key, billar_id text not null);
      create table public.purchases (id integer primary key, billar_id text not null, provider_id integer);
      create table public.purchase_details (id integer primary key, purchase_id integer not null, product_id integer not null);
      create table public.provider_products (id integer primary key, provider_id integer not null, product_id integer not null);
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, null, '{}', false),
        ('00000000-0000-0000-0000-000000000002', 'B', 'admin', true, null, '{}', false),
        ('00000000-0000-0000-0000-000000000003', 'A', 'manager', true, 'compras', '{purchases}', false),
        ('00000000-0000-0000-0000-000000000004', 'A', 'manager', true, 'informes', '{reports}', false),
        ('00000000-0000-0000-0000-000000000005', 'A', 'manager', true, 'caja', '{quick_sale}', false),
        ('00000000-0000-0000-0000-000000000006', 'A', 'manager', false, 'inactivo', '{purchases}', false),
        ('00000000-0000-0000-0000-000000000007', 'A', 'manager', true, 'nuevo', '{purchases}', true),
        ('00000000-0000-0000-0000-000000000008', 'A', 'manager', true, null, '{}', false),
        ('00000000-0000-0000-0000-000000000009', 'A', 'admin', true, null, '{}', false),
        ('00000000-0000-0000-0000-000000000009', 'B', 'admin', true, null, '{}', false);
      insert into public.products values (1, 'A'), (2, 'B');
      insert into public.providers values (1, 'A'), (2, 'B');
      insert into public.purchases values (1, 'A', 1), (2, 'B', 2);
      insert into public.purchase_details values (1, 1, 1), (2, 2, 2);
      insert into public.provider_products values (1, 1, 1), (2, 2, 2);
      alter table public.products enable row level security;
      create policy fixture_all on public.products for all to authenticated
        using (true) with check (true);
      grant select on public.products to authenticated;
      grant select, insert, update, delete on public.providers, public.purchases,
        public.purchase_details, public.provider_products to authenticated;
      create policy fixture_all on public.providers for all to authenticated using (true) with check (true);
      create policy fixture_all on public.purchases for all to authenticated using (true) with check (true);
      create policy fixture_all on public.purchase_details for all to authenticated using (true) with check (true);
      create policy fixture_all on public.provider_products for all to authenticated using (true) with check (true);
      create policy business_admin_only on public.providers as restrictive for all to authenticated
        using (false) with check (false);
      create policy business_admin_only on public.purchases as restrictive for all to authenticated
        using (false) with check (false);
      create policy business_admin_only on public.purchase_details as restrictive for all to authenticated
        using (false) with check (false);
      create policy business_admin_only on public.provider_products as restrictive for all to authenticated
        using (false) with check (false);
      create policy owner_business_scope on public.providers as restrictive for all to authenticated
        using (public.has_billar_role(billar_id, array['admin']::text[]))
        with check (public.has_billar_role(billar_id, array['admin']::text[]));
      create policy owner_business_scope on public.purchases as restrictive for all to authenticated
        using (public.has_billar_role(billar_id, array['admin']::text[]))
        with check (public.has_billar_role(billar_id, array['admin']::text[]));
      create policy owner_business_scope on public.purchase_details as restrictive for all to authenticated
        using (exists (select 1 from public.purchases p
          where p.id = purchase_details.purchase_id
            and public.has_billar_role(p.billar_id, array['admin']::text[])))
        with check (exists (select 1 from public.purchases p
          where p.id = purchase_details.purchase_id
            and public.has_billar_role(p.billar_id, array['admin']::text[])));
      create policy owner_business_scope on public.provider_products as restrictive for all to authenticated
        using (exists (select 1 from public.providers p
          where p.id = provider_products.provider_id
            and public.has_billar_role(p.billar_id, array['admin']::text[])))
        with check (exists (select 1 from public.providers p
          join public.products product on product.id = provider_products.product_id
            and product.billar_id = p.billar_id
          where p.id = provider_products.provider_id
            and public.has_billar_role(p.billar_id, array['admin']::text[])));
    `);
    for (const file of [
      'staff_module_guards_partial.sql',
      'staff_inventory_guards_partial.sql',
      'staff_purchases_guards_partial.sql',
    ]) {
      const sql = fs.readFileSync(path.join(__dirname, '..', 'supabase', file), 'utf8');
      await db.exec(sql);
      await db.exec(sql);
    }
    await db.exec('set role authenticated');
    const asUser = async id => {
      const user = `00000000-0000-0000-0000-${id.toString().padStart(12, '0')}`;
      return db.query(
        `select set_config('request.jwt.claim.sub', $1, false),
                set_config('request.jwt.claims', $2, false)`,
        [user, JSON.stringify({ app_metadata: { account_type: 'staff', billar_id: id === 2 ? 'B' : 'A' } })],
      );
    };
    const ids = async table => (await db.query(`select id from public.${table} order by id`))
      .rows.map(row => row.id);
    const tables = ['providers', 'purchases', 'purchase_details', 'provider_products'];

    for (const id of [3, 4]) {
      await asUser(id);
      for (const table of tables) assert.deepEqual(await ids(table), [1]);
      await assert.rejects(db.query("insert into public.purchases values (3, 'A', 1)"), /row-level security/i);
      await assert.rejects(db.query('insert into public.purchase_details values (3, 1, 1)'), /row-level security/i);
      await assert.rejects(db.query("insert into public.providers values (3, 'A')"), /row-level security/i);
      await assert.rejects(db.query('insert into public.provider_products values (3, 1, 1)'), /row-level security/i);
      for (const table of tables) {
        assert.equal((await db.query(`delete from public.${table} where id = 1 returning id`)).rows.length, 0);
      }
    }

    for (const id of [5, 6, 7, 8]) {
      await asUser(id);
      for (const table of tables) assert.deepEqual(await ids(table), []);
    }

    await asUser(1);
    for (const table of tables) assert.deepEqual(await ids(table), [1]);
    await db.query("insert into public.providers values (3, 'A')");
    await db.query("insert into public.purchases values (3, 'A', 3)");
    await db.query('insert into public.purchase_details values (3, 3, 1)');
    await db.query('insert into public.provider_products values (3, 3, 1)');
    await assert.rejects(db.query("insert into public.purchases values (4, 'A', 2)"), /row-level security/i);
    await assert.rejects(db.query('insert into public.purchase_details values (4, 3, 2)'), /row-level security/i);
    await assert.rejects(db.query('insert into public.provider_products values (4, 3, 2)'), /row-level security/i);
    await assert.rejects(db.query("update public.purchases set billar_id = 'B' where id = 1"), /no puede modificarse/i);
    await assert.rejects(db.query("update public.providers set billar_id = 'B' where id = 1"), /no puede modificarse/i);
    await assert.rejects(db.query('update public.purchase_details set product_id = 2 where id = 1'), /row-level security/i);
    await assert.rejects(db.query('update public.provider_products set product_id = 2 where id = 1'), /row-level security/i);
    await asUser(2);
    for (const table of tables) assert.deepEqual(await ids(table), [2]);

    await asUser(9);
    await assert.rejects(db.query("update public.purchases set billar_id = 'B', provider_id = 2 where id = 1"), /no puede modificarse/i);
    await assert.rejects(db.query("update public.providers set billar_id = 'B' where id = 1"), /no puede modificarse/i);
    await assert.rejects(db.query('update public.purchase_details set purchase_id = 2, product_id = 2 where id = 1'), /no puede modificarse/i);
    await assert.rejects(db.query('update public.provider_products set provider_id = 2, product_id = 2 where id = 1'), /no puede modificarse/i);

    await asUser(3);
    await db.exec("reset role; update public.business_memberships set allowed_modules = '{}' where username = 'compras'; set role authenticated");
    for (const table of tables) assert.deepEqual(await ids(table), []);

    await db.exec(`
      reset role;
      create function auth.jwt() returns jsonb language sql stable as $$
        select nullif(current_setting('request.jwt.claims', true), '')::jsonb
      $$;
      alter table public.providers
        add column name text not null default '',
        add column phone text default '',
        add column email text default '',
        add column address text default '',
        add column contact_name text default '',
        add column notes text default '',
        add column category text default 'General',
        add column visit_days text default '';
      alter table public.provider_products alter column id
        add generated by default as identity (start with 10);
      update public.business_memberships set allowed_modules = '{purchases}' where username = 'compras';
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000010', 'A', 'manager', true, 'auxiliar', '{purchases}', false);
    `);
    const script = file => fs.readFileSync(path.join(__dirname, '..', 'supabase', file), 'utf8');
    await db.exec(script('provider_delete_idempotent_partial.sql'));
    await db.exec(script('provider_credit_terms_partial.sql'));
    await db.exec(script('provider_credit_terms_partial.sql'));
    const providerSql = script('staff_provider_operations_partial.sql');
    await db.exec(providerSql);
    await db.exec(providerSql);
    await db.exec('set role authenticated');
    await asUser(3);
    const data = {
      name: 'Proveedor de prueba', phone: '', email: '', address: '',
      contact_name: '', notes: '', category: 'General', visit_days: 'Lunes',
    };
    const uuid = n => `10000000-0000-0000-0000-${n.toString().padStart(12, '0')}`;
    const operate = async (id, operation = 'create', provider = data, products = [1], providerId = 100, billar = 'A') =>
      (await db.query(
        'select public.apply_staff_provider_operation($1::uuid, $2, $3, $4, $5::jsonb, $6::bigint[]) as receipt',
        [uuid(id), billar, providerId, operation, JSON.stringify(provider), products],
      )).rows[0].receipt;
    await assert.rejects(operate(1), /permission denied/i);
    await db.exec(`
      reset role;
      grant execute on function public.apply_staff_provider_operation(uuid, text, bigint, text, jsonb, bigint[])
      to authenticated;
      set role authenticated;
    `);
    const snapshot = async () => {
      await db.exec('reset role');
      const state = (await db.query(`select jsonb_build_object(
        'providers', (select jsonb_agg(p order by id) from public.providers p),
        'links', (select jsonb_agg(p order by id) from public.provider_products p),
        'requests', (select jsonb_agg(p order by request_id) from public.staff_provider_requests p),
        'audit', (select jsonb_agg(p order by request_id) from public.staff_provider_audit p),
        'products', (select jsonb_agg(p order by id) from public.products p),
        'purchases', (select jsonb_agg(p order by id) from public.purchases p)
      ) as state`)).rows[0].state;
      await db.exec('set role authenticated');
      return state;
    };
    const before = await snapshot();
    const created = await operate(1);
    assert.equal(created.provider_id, 100);
    assert.equal(created.actor_id, '00000000-0000-0000-0000-000000000003');
    assert.equal(created.billar_id, 'A');
    assert.equal(created.provider.name, data.name);
    assert.equal(created.provider.is_active, true);
    assert.deepEqual(created.product_ids, [1]);
    assert.deepEqual(await operate(1), created);
    const afterCreate = await snapshot();
    assert.equal(afterCreate.requests.length, 1);
    assert.equal(afterCreate.audit.length, 1);
    assert.equal(afterCreate.audit[0].old_values, null);
    assert.equal(afterCreate.audit[0].actor_id, created.actor_id);
    assert.deepEqual(afterCreate.products, before.products);
    assert.deepEqual(afterCreate.purchases, before.purchases);
    assert.deepEqual((await db.query('select * from public.staff_provider_audit')).rows, []);
    await assert.rejects(db.query('select * from public.staff_provider_requests'), /permission denied/i);
    await assert.rejects(
      db.query('delete from public.staff_provider_audit where provider_id = 100'), /permission denied/i,
    );
    assert.equal((await db.query("update public.providers set name = 'Directo' where id = 100 returning id")).rows.length, 0);
    await assert.rejects(operate(1, 'create', { ...data, name: 'Otro' }), /ya fue utilizado/i);
    await assert.rejects(operate(1, 'update'), /ya fue utilizado/i);
    await assert.rejects(operate(2), /ya existe/i);
    await assert.rejects(operate(2, 'update', data, [2]), /no pertenece/i);
    await assert.rejects(operate(2, 'update', data, [1], 2), /no está activo/i);
    await assert.rejects(operate(2, 'create', data, [1], 100, 'B'), /cuenta de personal/i);
    assert.deepEqual(await snapshot(), afterCreate);

    for (const [operation, provider, products] of [
      ['create', null, [1]], ['create', {}, [1]], ['create', { ...data, name: '' }, [1]],
      ['create', { ...data, notes: null }, [1]], ['create', { ...data, billar_id: 'B' }, [1]],
      ...[
        { credit_days: -1, preferred_payment_method: 'credito' },
        { credit_days: 1.5, preferred_payment_method: 'credito' },
        { credit_days: 2147483648, preferred_payment_method: 'credito' },
        { credit_days: '30', preferred_payment_method: 'credito' },
        { credit_days: 30, preferred_payment_method: false },
        { credit_days: 30, preferred_payment_method: 'otro' },
        { credit_days: 30, unexpected: 'credito' },
      ].map(terms => ['create', { ...data, ...terms }, [1]]),
      ['create', data, [1, 1]], ['create', data, [null]], ['create', data, [0]],
      ['create', data, null], ['archive', data, []], ['archive', {}, [1]],
      ['delete', {}, []],
    ]) {
      await assert.rejects(operate(2, operation, provider, products), /válid|complet|obligatorio|admite/i);
    }
    for (const user of [1, 2, 4, 5, 6, 7, 8]) {
      await asUser(user);
      await assert.rejects(operate(2, 'update'), /permiso|cuenta de personal/i);
    }
    await asUser(10);
    await assert.rejects(operate(1), /ya fue utilizado/i);
    await asUser(3);
    await db.query("select set_config('request.jwt.claims', $1, false)", [JSON.stringify({
      app_metadata: { account_type: 'player', billar_id: 'A' },
      user_metadata: { account_type: 'staff', billar_id: 'A' },
    })]);
    await assert.rejects(operate(2, 'update'), /cuenta de personal/i);
    await asUser(3);
    assert.deepEqual(await snapshot(), afterCreate);

    const updated = await operate(2, 'update', { ...data, name: 'Proveedor editado' }, []);
    assert.equal(updated.provider.name, 'Proveedor editado');
    assert.deepEqual(updated.product_ids, []);
    assert.deepEqual(await operate(2, 'update', { ...data, name: 'Proveedor editado' }, []), updated);
    assert.deepEqual(await operate(1), created);
    const beforeFailure = await snapshot();
    await db.exec(`
      reset role;
      create function public.fixture_reject_provider_audit() returns trigger language plpgsql as $$
        begin raise exception 'Auditoría no disponible'; end;
      $$;
      create trigger fixture_reject_audit before insert on public.staff_provider_audit
        for each row execute function public.fixture_reject_provider_audit();
      set role authenticated;
    `);
    await assert.rejects(operate(3, 'update', data, [1]), /auditoría no disponible/i);
    assert.deepEqual(await snapshot(), beforeFailure);
    await db.exec(`
      reset role;
      drop trigger fixture_reject_audit on public.staff_provider_audit;
      drop function public.fixture_reject_provider_audit();
      set role authenticated;
    `);
    await operate(3, 'update', data, [1]);
    const archived = await operate(4, 'archive', {}, []);
    assert.equal(archived.provider.is_active, false);
    assert.deepEqual(archived.product_ids, [1]);
    assert.deepEqual(await operate(4, 'archive', {}, []), archived);
    await assert.rejects(operate(5, 'update'), /no está activo/i);
    await assert.rejects(operate(5, 'archive', {}, []), /no está activo/i);
    await db.exec(`
      reset role;
      update public.business_memberships set allowed_modules = '{}' where username = 'compras';
      set role authenticated;
    `);
    await assert.rejects(operate(4, 'archive', {}, []), /permiso/i);
    await asUser(1);
    const audit = (await db.query('select * from public.staff_provider_audit order by request_id')).rows;
    assert.equal(audit.length, 4);
    assert.equal(audit[1].old_values.provider.name, data.name);
    assert.equal(audit[1].new_values.provider.name, 'Proveedor editado');
    assert.deepEqual(audit[1].old_values.product_ids, [1]);
    assert.deepEqual(audit[1].new_values.product_ids, []);
    assert.equal(audit[3].operation, 'archive');
    await asUser(2);
    assert.deepEqual((await db.query('select * from public.staff_provider_audit')).rows, []);

    await db.exec(`reset role;
      update public.business_memberships set allowed_modules = '{purchases}' where username = 'compras';
      set role authenticated`);
    await asUser(3);
    const terms = { ...data, credit_days: 30, preferred_payment_method: 'credito' };
    const withTerms = await operate(6, 'create', terms, [], 101);
    assert.equal(withTerms.provider.credit_days, 30);
    assert.equal(withTerms.provider.preferred_payment_method, 'credito');
    assert.deepEqual(await operate(6, 'create', terms, [], 101), withTerms);
    await assert.rejects(operate(6, 'create', { ...terms, credit_days: 60 }, [], 101), /ya fue utilizado/i);
    const legacyUpdate = await operate(7, 'update', data, [], 101);
    assert.equal(legacyUpdate.provider.credit_days, 30);
    assert.equal(legacyUpdate.provider.preferred_payment_method, 'credito');
    const cleared = await operate(8, 'update', {
      ...data, credit_days: null, preferred_payment_method: null,
    }, [], 101);
    assert.equal(cleared.provider.credit_days, null);
    assert.equal(cleared.provider.preferred_payment_method, null);
    assert.deepEqual(await operate(6, 'create', terms, [], 101), withTerms);

    await db.exec('reset role');
    const finalState = await snapshot();
    await db.exec('reset role');
    await db.exec(providerSql);
    const diagnostic = (await db.query(script('staff_rollout_diagnostic.sql'))).rows[0].diagnostic;
    const providerFunction = diagnostic.staff_functions.find(fn => fn.name === 'apply_staff_provider_operation');
    assert.equal(providerFunction.installed, true);
    assert.equal(providerFunction.anon_execute, false);
    assert.equal(providerFunction.authenticated_execute, false);
    for (const name of ['staff_provider_requests', 'staff_provider_audit']) {
      assert.equal(diagnostic.staff_tables.find(table => table.name === name).rls_enabled, true);
    }
    assert.deepEqual(await snapshot(), finalState);
    await db.exec('reset role');
    await db.exec(script('staff_purchase_resolution_partial.sql'));
    await db.exec('set role authenticated');
    await asUser(3);
    const payload = { provider_id: 102, operation: 'create', provider: terms, product_ids: [1] };
    const resolve = async (id, body = payload) => (await db.query(
      'select public.resolve_staff_purchase_request($1::uuid, $2, $3, $4::jsonb) as receipt',
      [uuid(id), 'A', 'provider', JSON.stringify(body)],
    )).rows[0].receipt;
    await assert.rejects(resolve(501), /permission denied/i);
    await db.exec(`reset role;
      grant execute on function public.resolve_staff_purchase_request(uuid, text, text, jsonb) to authenticated;
      grant execute on function public.apply_staff_provider_operation(uuid, text, bigint, text, jsonb, bigint[]) to authenticated;
      set role authenticated`);
    const beforeResolution = await snapshot();
    assert.deepEqual(await resolve(6, {
      provider_id: 101, operation: 'create', provider: terms, product_ids: [],
    }), withTerms);
    assert.deepEqual(await snapshot(), beforeResolution);
    const closed = await resolve(501);
    assert.equal(closed.reason_code, 'not_applied_closed');
    assert.equal(closed.kind, 'provider');
    assert.deepEqual(closed.request_payload, payload);
    assert.deepEqual(await resolve(501), closed);
    assert.deepEqual(await operate(501, 'create', terms, [1], 102), closed);
    await assert.rejects(operate(502, 'update', terms, [999], 101), /producto/i);
    const failed = { provider_id: 101, operation: 'update', provider: terms, product_ids: [999] };
    const failedClosed = await resolve(502, failed);
    assert.deepEqual(await operate(502, 'update', terms, [999], 101), failedClosed);
    const afterResolution = await snapshot();
    for (const field of ['providers', 'links', 'audit', 'products', 'purchases']) {
      assert.deepEqual(afterResolution[field], beforeResolution[field]);
    }
    assert.equal(afterResolution.requests.length, beforeResolution.requests.length + 2);
    await assert.rejects(resolve(501, { ...payload, provider_id: 103 }), /ya fue utilizado/i);
    await asUser(10);
    await assert.rejects(resolve(501), /ya fue utilizado/i);
  } finally {
    await db.close();
  }
});
