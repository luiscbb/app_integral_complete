// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('sale origin migration preserves legacy sales and rejects unknown modules', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create table public.sales_history (id integer primary key, type text not null);
      insert into public.sales_history values (1, 'Venta anterior');
    `);
    const migration = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'add_sales_origin.sql'),
      'utf8',
    );
    await db.exec(migration);
    await db.exec(migration);
    assert.deepEqual(
      (await db.query('select type, source_module from public.sales_history where id = 1')).rows,
      [{ type: 'Venta anterior', source_module: null }],
    );
    for (const [id, source] of [
      [2, 'quick_sale'],
      [3, 'billiard_tables'],
      [4, 'dine_in'],
      [5, 'personal_account'],
    ]) {
      await db.query(
        'insert into public.sales_history (id, type, source_module) values ($1, $2, $3)',
        [id, 'Mesa', source],
      );
    }
    await assert.rejects(
      db.query(
        "insert into public.sales_history (id, type, source_module) values (6, 'Mesa', 'reports')",
      ),
      /check constraint/i,
    );
    await db.query("insert into public.sales_history (id, type) values (7, 'Cliente antiguo')");
  } finally {
    await db.close();
  }
});
