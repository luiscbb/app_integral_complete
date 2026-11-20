const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');
const { functionDefinition } = require('../supabase/build_staff_rollout.cjs');

const owner = '00000000-0000-0000-0000-000000000001';
const staff = '00000000-0000-0000-0000-000000000002';
const other = '00000000-0000-0000-0000-000000000003';
const read = file => fs.readFileSync(path.join(__dirname, '..', 'supabase', file), 'utf8');

async function fixture() {
  const db = new PGlite();
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create schema auth;
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
    $$;
    grant usage on schema auth,public to anon,authenticated;
    alter default privileges in schema public grant all on tables to anon,authenticated;
    alter default privileges in schema public grant execute on functions to anon,authenticated;
    create table business_memberships (user_id uuid,billar_id text,role text,
      is_active boolean,username text,must_change_password boolean,allowed_modules text[]);
    insert into business_memberships values
      ('${owner}','A','admin',true,null,false,'{}'),
      ('${staff}','A','manager',true,'consulta',false,'{reports_sales}'),
      ('${other}','B','admin',true,null,false,'{}');
    create function public.has_billar_role(b text,r text[]) returns boolean
    language sql stable security definer as $$
      select exists(select 1 from business_memberships where user_id=auth.uid()
        and billar_id=b and is_active and role=any(r))
    $$;
    create table sales_history (id bigint primary key,billar_id text,date text,
      total double precision,paid double precision,payment_method text,cancelled boolean,
      private_notes text);
    create table sale_details (id bigint primary key,sale_id bigint,quantity double precision,
      cost_at_sale numeric,cancelled boolean);
    create table products (id bigint primary key,billar_id text,name text);
    create table inventory_movements (id bigint primary key,billar_id text,product_id bigint,
      created_at timestamptz,quantity double precision,movement_type text,unit_cost numeric);
    create table purchases (id bigint primary key,billar_id text,date text,total double precision,
      paid_amount double precision,payment_condition text,payment_method text,cash_source text,cancelled boolean);
    create table cash_outflows (id bigint primary key,billar_id text,created_at timestamptz,
      amount double precision,payment_method text);
    alter table sales_history enable row level security;
    alter table sale_details enable row level security;
    alter table inventory_movements enable row level security;
    alter table purchases enable row level security;
    alter table cash_outflows enable row level security;
  `);
  await db.exec(functionDefinition(read('staff_module_guards_partial.sql'), 'has_staff_module_access'));
  await db.exec(read('shared_cash.sql'));
  await db.exec(read('staff_reports.sql'));
  return db;
}

async function login(db, actor) {
  await db.exec(`reset role; set role authenticated;
    select set_config('request.jwt.claim.sub','${actor}',false)`);
}

test('all report categories are isolated, independent, bounded and do not expose operations', async () => {
  const db = await fixture();
  try {
    await db.exec(`
      insert into sales_history select id,'A','2026-01-15T12:00:00Z',10,12,'Efectivo',false,'secret'
        from generate_series(1,52) id;
      insert into sale_details select id,id,1,4,false from generate_series(1,52) id;
      insert into sales_history values
        (53,'B','2026-01-15',900,900,'Efectivo',false,'secret'),
        (54,'A','2026-01-15',900,900,'Efectivo',true,'secret'),
        (55,'A','2026-02-01',900,900,'Efectivo',false,'secret');
      insert into products values (1,'A','Agua'),(2,'B','Producto ajeno');
      insert into inventory_movements values
        (1,'A',1,'2026-01-15',-2,'sale',50),(2,'A',2,'2026-01-15',1,'purchase',99),
        (3,'B',2,'2026-01-15',100,'purchase',900);
      insert into purchases values
        (1,'A','2026-01-15',200,0,'credito',null,null,false),
        (2,'A','2026-01-15',30,30,'contado','Efectivo','cajero',false),
        (3,'A','2026-01-15',20,20,'contado','Efectivo','caja',false),
        (4,'B','2026-01-15',900,900,'contado','Efectivo','caja',false);
    `);
    const load = (kind, business = 'A', start = '2026-01-01', end = '2026-02-01', cursor = null) =>
      db.query('select public.staff_read_report($1,$2,$3,$4,$5) as r',[business,kind,start,end,cursor])
        .then(result => result.rows[0].r);
    await login(db, staff);
    const first = await load('reports_sales');
    assert.deepEqual([first.count,first.metrics,first.items.length,first.has_more],
      [52,{total:520,paid:520},50,true]);
    assert.deepEqual(first.items.map(r=>r.id),Array.from({length:50},(_,i)=>52-i));
    assert.deepEqual(Object.keys(first.items[0]).sort(),['id','billar_id','date','label','amount','details'].sort());
    const next = await load('reports_sales','A','2026-01-01','2026-02-01',3);
    assert.deepEqual(next.items.map(r=>r.id),[2,1]);
    assert.deepEqual(next.metrics,first.metrics);
    assert.equal(next.has_more,false);
    for (const kind of ['reports_cash_flow','reports_kardex','reports_profit','reports','purchases',null]) {
      await assert.rejects(load(kind),/permiso/i);
    }
    await assert.rejects(load('reports_sales','B'),/permiso/i);
    for (const [start,end,cursor] of [
      ['2026-02-01','2026-01-01',null],['2025-01-01','2026-02-01',null],
      ['2026-01-01','infinity',null],['2026-01-01','2026-02-01',0],
    ]) await assert.rejects(load('reports_sales','A',start,end,cursor),/invalidos/i);

    for (const kind of ['reports_cash_flow','reports_kardex','reports_profit']) {
      await db.exec(`reset role; update business_memberships set allowed_modules=array['${kind}'] where user_id='${staff}'`);
      await login(db,staff);
      await assert.rejects(load('reports_sales'),/permiso/i);
      const report = await load(kind);
      if (kind === 'reports_cash_flow') {
        assert.deepEqual(report.metrics,{sales:520,purchases:20,inflows:0,outflows:0,netCash:500,netFlow:470});
      } else if (kind === 'reports_kardex') {
        assert.deepEqual(report.items.map(r=>[r.label,r.amount]),[['Producto no disponible',1],['Agua',-2]]);
        assert.ok(report.items.every(r=>!Object.hasOwn(r,'unit_cost')));
      } else {
        assert.deepEqual(report.metrics,{sales:520,cost:208,expenses:0,profit:312});
        await db.exec('reset role; update sale_details set cost_at_sale=null where id=1');
        await login(db,staff);
        assert.equal((await load(kind)).metrics.profit,null);
        await db.exec(`reset role; update sale_details set cost_at_sale=4 where id=1;
          insert into cash_outflows values (1,'A','2026-01-15',10,'Efectivo')`);
        await login(db,staff);
        const incomplete = await load(kind);
        assert.equal(incomplete.metrics.profit,null);
        assert.equal(incomplete.incomplete_expenses,true);
      }
    }
    for (const change of ["is_active=false","is_active=true,must_change_password=true",
      "must_change_password=false,allowed_modules='{quick_sale}'"]) {
      await db.exec(`reset role; update business_memberships set ${change} where user_id='${staff}'`);
      await login(db,staff);
      await assert.rejects(load('reports_profit'),/permiso/i);
    }
    for (const table of ['sales_history','sale_details','inventory_movements','cash_shared_movements']) {
      if (table === 'cash_shared_movements') {
        await assert.rejects(db.query(`select * from ${table}`),/permission denied/i);
      } else {
        assert.deepEqual((await db.query(`select * from ${table}`)).rows,[]);
      }
    }
    await db.exec('reset role; set role anon');
    await assert.rejects(load('reports_sales'),/permission denied/i);
  } finally { await db.close(); }
});

test('shared cash has one active turn, durable idempotency, cancellation and closed snapshots', async () => {
  const db = await fixture();
  let serial = 0;
  const uuid = () => `10000000-0000-4000-8000-${String(++serial).padStart(12,'0')}`;
  const apply = (id,operation,payload,business='A') =>
    db.query('select public.cash_shared_apply($1,$2,$3,$4) as r',[business,id,operation,JSON.stringify(payload)])
      .then(result=>result.rows[0].r);
  const state = () => db.query("select public.cash_shared_state('A',now()-interval '1 day',now()+interval '1 day') as r")
    .then(result=>result.rows[0].r);
  try {
    await db.exec(read('shared_cash.sql'));
    await login(db,staff);
    await assert.rejects(apply(uuid(),'open',{amount:100}),/administradores/i);
    await login(db,owner);
    const openRequest = uuid();
    const opened = await apply(openRequest,'open',{amount:100});
    assert.deepEqual(await apply(openRequest,'open',{amount:100}),opened);
    await assert.rejects(apply(openRequest,'open',{amount:101}),/utilizada/i);
    await assert.rejects(apply(uuid(),'open',{amount:0}),/Ya hay un turno/i);
    const movement = (kind,amount,extra={}) => ({
      session_id:opened.id,kind,amount,description:'Movimiento',payment_method:'Efectivo',...extra,
    });
    const moveRequest = uuid();
    const moved = await apply(moveRequest,'move',movement('contribution',50));
    assert.deepEqual(await apply(moveRequest,'move',movement('contribution',50)),moved);
    await apply(uuid(),'move',movement('expense',10));
    await apply(uuid(),'move',movement('withdrawal',20));
    await apply(uuid(),'move',movement('partial',5));
    await apply(uuid(),'move',movement('expense',8,{payment_method:'Tarjeta'}));
    assert.equal((await state()).summary.netCash,15);
    await db.exec(`reset role; insert into sales_history values
      (101,'A',clock_timestamp()::text,0.1,0.1,'Efectivo',false,''),
      (102,'A',clock_timestamp()::text,0.2,0.2,'Efectivo',false,''),
      (103,'A',clock_timestamp()::text,0.3,0.3,'Efectivo',false,'')`);
    await login(db,owner);
    assert.equal((await state()).summary.netCash,15.6);
    const pending = uuid();
    const cancelled = await apply(pending,'cancel',{});
    assert.equal(cancelled.cancelled,true);
    await assert.rejects(apply(pending,'move',movement('contribution',50)),/cancelada/i);
    assert.deepEqual(await apply(moveRequest,'cancel',{}),moved);
    for (const payload of [movement('contribution',0),movement('withdrawal',2.123),
      movement('expense',1,{session_id:opened.id+1}),movement('contribution',1,{payment_method:'Tarjeta'})]) {
      await assert.rejects(apply(uuid(),'move',payload),/invalido|cambio|decimales/i);
    }
    const closeRequest = uuid();
    const closed = await apply(closeRequest,'close',{session_id:opened.id,amount:110,next_opening:30});
    assert.deepEqual([closed.summary.expected,closed.summary.difference],[115.6,-5.6]);
    assert.deepEqual(await apply(closeRequest,'close',{session_id:opened.id,amount:110,next_opening:30}),closed);
    assert.equal((await state()).session.opening_amount,30);
    assert.equal((await state()).sessions.length,2);
    await assert.rejects(apply(uuid(),'move',movement('expense',1)),/cambio/i);
    const history = (await state()).sessions.find(s=>s.id===opened.id);
    assert.equal(history.needs_reconciliation,false);
    // A late synchronized sale must flag, not silently rewrite, the closed cut.
    await db.exec(`reset role; insert into sales_history
      select 90,'A',opened_at::text,9,9,'Efectivo',false,'' from cash_shared_sessions where id=${opened.id}`);
    await login(db,owner);
    const reconciled = (await state()).sessions.find(s=>s.id===opened.id);
    assert.equal(reconciled.needs_reconciliation,true);
    assert.equal(reconciled.expected_amount,115.6);
    for (const fn of ['cash_shared_apply(text,uuid,text,jsonb)','cash_shared_state(text,timestamptz,timestamptz,bigint,bigint)',
      'cash_shared_summary(text,timestamptz,timestamptz)']) {
      const privileges = (await db.query(`select has_function_privilege('anon','public.${fn}','EXECUTE') as anon,
        has_function_privilege('authenticated','public.${fn}','EXECUTE') as member`)).rows[0];
      assert.equal(privileges.anon,false);
      assert.equal(privileges.member,!fn.startsWith('cash_shared_summary'));
    }
    await login(db,other);
    await assert.rejects(state(),/administradores/i);
    await assert.rejects(apply(uuid(),'open',{amount:0}),/administradores/i);
    await db.exec('reset role; set role anon');
    await assert.rejects(state(),/permission denied/i);
  } finally { await db.close(); }
});
