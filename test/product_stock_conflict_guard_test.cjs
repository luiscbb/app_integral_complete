// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('stale stock writes fail instead of overwriting another sale', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create table public.products (
        id bigint primary key, name text not null, stock double precision not null
      );
      insert into public.products values (1, 'Producto', 10), (2, 'Otro', 5);
    `);
    const sql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'product_stock_conflict_guard_partial.sql'),
      'utf8',
    );
    await db.exec(sql);
    await db.exec(sql);

    await db.query('update public.products set stock = stock - 1, stock_revision = stock_revision + 1 where id = 1');
    let row = (await db.query('select stock, stock_revision from public.products where id = 1')).rows[0];
    assert.equal(row.stock, 9);
    assert.equal(Number(row.stock_revision), 1);

    await assert.rejects(
      db.query('update public.products set stock = 8, stock_revision = 1 where id = 1'),
      /inventario cambió/i,
    );
    await assert.rejects(
      db.query('update public.products set stock = 8 where id = 1'),
      /inventario cambió/i,
    );
    await assert.rejects(
      db.query('update public.products set stock = 9, stock_revision = 1 where id = 1'),
      /inventario cambió/i,
    );
    await assert.rejects(
      db.query('update public.products set stock_revision = 0 where id = 1'),
      /inventario cambió/i,
    );
    await assert.rejects(
      db.query(`
        insert into public.products (id, name, stock) values (1, 'Producto', 8)
        on conflict (id) do update
        set name = excluded.name, stock = excluded.stock,
            stock_revision = excluded.stock_revision
      `),
      /inventario cambió/i,
    );
    row = (await db.query('select stock, stock_revision from public.products where id = 1')).rows[0];
    assert.equal(row.stock, 9);
    assert.equal(Number(row.stock_revision), 1);

    await db.query("update public.products set name = 'Nuevo' where id = 1");
    row = (await db.query('select name, stock, stock_revision from public.products where id = 1')).rows[0];
    assert.equal(row.name, 'Nuevo');
    assert.equal(row.stock, 9);
    assert.equal(Number(row.stock_revision), 1);

    await db.query('update public.products set stock = 7, stock_revision = 2 where id = 1');
    row = (await db.query('select stock, stock_revision from public.products where id = 1')).rows[0];
    assert.equal(row.stock, 7);
    assert.equal(Number(row.stock_revision), 2);
    assert.equal(
      Number((await db.query('select stock_revision from public.products where id = 2')).rows[0].stock_revision),
      0,
    );
  } finally {
    await db.close();
  }
});
