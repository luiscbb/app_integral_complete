const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('staff branding exposes only its business identity and checks current membership', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon nologin;
      create role authenticated nologin;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      grant usage on schema auth, public to authenticated, anon;
      alter default privileges in schema public grant execute on functions to anon, authenticated;
      create table public.business_memberships (
        user_id uuid, billar_id text, role text, username text,
        is_active boolean, must_change_password boolean
      );
      create table public.billar_settings (
        billar_id text, business_name text, logo_url text, primary_color integer,
        private_setting text
      );
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'manager', 'mesero1', true, false);
      insert into public.billar_settings values
        ('A', 'Billar A', 'A/logos/logo.png', 123, 'not exposed'),
        ('B', 'Billar B', 'B/logos/logo.png', 456, 'not exposed');
      alter table public.billar_settings enable row level security;
    `);
    const sql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'staff_business_profile.sql'), 'utf8');
    await db.exec(sql);
    await db.exec(sql);
    assert.equal((await db.query(
      "select has_function_privilege('anon', 'public.staff_business_profile(text)', 'EXECUTE') as allowed"
    )).rows[0].allowed, false);
    await db.exec(`set role authenticated;
      select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);`);
    assert.deepEqual((await db.query("select * from public.staff_business_profile('A')")).rows, [
      { billar_id: 'A', business_name: 'Billar A', logo_url: 'A/logos/logo.png', primary_color: 123 },
    ]);
    await assert.rejects(db.query('select * from public.billar_settings'), /permission denied/i);
    await assert.rejects(db.query("select * from public.staff_business_profile('B')"), /acceso activo/i);
    for (const change of [
      'is_active = false',
      'is_active = true, must_change_password = true',
      "must_change_password = false, role = 'admin'",
      "role = 'manager', username = null",
    ]) {
      await db.exec(`reset role; update public.business_memberships set ${change}; set role authenticated;`);
      await assert.rejects(db.query("select * from public.staff_business_profile('A')"), /acceso activo/i);
    }
    await db.exec(`reset role;
      update public.business_memberships set username = 'mesero1';
      delete from public.billar_settings where billar_id = 'A';
      set role authenticated;`);
    await assert.rejects(db.query("select * from public.staff_business_profile('A')"), /identidad del negocio/i);
  } finally {
    await db.close();
  }
});
