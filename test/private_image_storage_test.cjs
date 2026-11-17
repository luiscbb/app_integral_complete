// Requires @electric-sql/pglite to be available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { PGlite } = require('@electric-sql/pglite');

test('private image policies restrict reads and writes by business and role', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated nologin;
      create role anon nologin;
      create schema auth;
      create schema storage;
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      create function storage.foldername(name text) returns text[] language sql immutable as $$
        select case when position('/' in name) > 0
          then string_to_array(regexp_replace(name, '/[^/]*$', ''), '/')
          else array[]::text[] end
      $$;
      grant usage on schema public, auth, storage to authenticated, anon;
      create table public.business_memberships (
        user_id uuid, billar_id text, role text, is_active boolean,
        must_change_password boolean, username text, allowed_modules text[]
      );
      create table public.billar_settings (user_id uuid, billar_id text);
      create table public.players (
        auth_user_id uuid, billar_id text, is_active boolean,
        must_change_password boolean, expires_at timestamptz, avatar_url text, avatar text
      );
      create table public.billar_tournaments (billar_id text);
      create table public.personal_clients (billar_id text);
      create table public.personal_customer_accounts (billar_id text);
      create table storage.buckets (id text primary key, public boolean not null);
      create table storage.objects (bucket_id text not null, name text not null);
      insert into storage.buckets values ('product_images', true), ('promo_images', true),
        ('player_avatars', true), ('other', true);
      insert into public.billar_settings values
        ('00000000-0000-0000-0000-000000000001', 'A'),
        ('00000000-0000-0000-0000-000000000002', 'B');
      insert into public.business_memberships values
        ('00000000-0000-0000-0000-000000000001', 'A', 'admin', true, false, null, '{}'),
        ('00000000-0000-0000-0000-000000000002', 'B', 'admin', true, false, null, '{}'),
        ('00000000-0000-0000-0000-000000000003', 'A', 'manager', true, false, 'jugadores', '{players}'),
        ('00000000-0000-0000-0000-000000000004', 'A', 'manager', true, false, 'caja', '{quick_sale}'),
        ('00000000-0000-0000-0000-000000000006', 'A', 'admin', true, false, null, '{}'),
        ('00000000-0000-0000-0000-000000000007', 'A', 'manager', true, true, 'nuevo', '{players}');
      insert into public.players values
        ('00000000-0000-0000-0000-000000000005', 'A', true, false,
         now() + interval '1 day', 'https://example.test/player_avatars/A/self.jpg', '');
      create function public.is_billar_admin_account() returns boolean language sql stable security definer as $$
        select exists (select 1 from public.business_memberships m
          where m.user_id = auth.uid() and m.role = 'admin' and m.is_active)
      $$;
      create function public.has_billar_role(business text, roles text[])
      returns boolean language sql stable security definer as $$
        select exists (select 1 from public.business_memberships m
          where m.user_id = auth.uid() and m.billar_id = business
            and m.role = any(roles) and m.is_active)
      $$;
      insert into storage.objects values
        ('product_images', 'A/products/item.jpg'), ('product_images', 'B/products/item.jpg'),
        ('product_images', 'A/logos/logo.jpg'), ('product_images', 'B/logos/logo.jpg'),
        ('player_avatars', 'A/self.jpg'), ('player_avatars', 'A/other.jpg'),
        ('player_avatars', 'B/avatar.jpg'), ('other', 'shared');
      alter table storage.objects enable row level security;
      grant select, insert, update, delete on storage.objects to authenticated, anon;
      -- Policies reported by the real project, plus a separate other-bucket fixture.
      create policy fixture_other on storage.objects for all to public
        using (bucket_id = 'other') with check (bucket_id = 'other');
      create policy "Allow all operations 11z6cbg_0" on storage.objects for insert to public
        with check (bucket_id = 'player_avatars');
      create policy "Allow all operations 11z6cbg_1" on storage.objects for select to public
        using (bucket_id = 'player_avatars');
      create policy player_avatars_select on storage.objects for select to public
        using (bucket_id = 'player_avatars');
      create policy player_avatars_insert on storage.objects for insert to authenticated
        with check (bucket_id = 'player_avatars' and public.has_billar_role((storage.foldername(name))[1], array['admin', 'manager']));
      create policy player_avatars_update on storage.objects for update to authenticated
        using (bucket_id = 'player_avatars' and public.has_billar_role((storage.foldername(name))[1], array['admin', 'manager']))
        with check (bucket_id = 'player_avatars' and public.has_billar_role((storage.foldername(name))[1], array['admin', 'manager']));
      create policy player_avatars_delete on storage.objects for delete to authenticated
        using (bucket_id = 'player_avatars' and public.has_billar_role((storage.foldername(name))[1], array['admin', 'manager']));
      create function auth.role() returns text language sql stable as $$
        select current_user::text
      $$;
      create policy product_images_select on storage.objects for select to public using (bucket_id = 'product_images');
      create policy product_images_insert on storage.objects for insert to public with check (bucket_id = 'product_images' and auth.role() = 'authenticated');
      create policy product_images_update on storage.objects for update to public using (bucket_id = 'product_images' and auth.role() = 'authenticated');
      create policy product_images_delete on storage.objects for delete to public using (bucket_id = 'product_images' and auth.role() = 'authenticated');
      create policy promo_images_select on storage.objects for select to public using (bucket_id = 'promo_images');
      create policy promo_images_insert on storage.objects for insert to public with check (bucket_id = 'promo_images' and auth.role() = 'authenticated');
      create policy promo_images_update on storage.objects for update to public using (bucket_id = 'promo_images' and auth.role() = 'authenticated');
      create policy promo_images_delete on storage.objects for delete to public using (bucket_id = 'promo_images' and auth.role() = 'authenticated');
      create policy player_accounts_block_storage on storage.objects as restrictive for all to authenticated
        using (public.is_billar_admin_account()
          or (bucket_id = 'player_avatars'
            and public.has_billar_role((storage.foldername(name))[1], array['manager'])))
        with check (public.is_billar_admin_account()
          or (bucket_id = 'player_avatars'
            and public.has_billar_role((storage.foldername(name))[1], array['manager'])));
    `);
    const sql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'private_image_storage_partial.sql'), 'utf8',
    );
    const staffSql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'staff_module_guards_partial.sql'), 'utf8',
    );
    await db.exec(`
      create table public.products (billar_id text, image_path text);
      insert into public.products values
        ('A', 'https://example.test/storage/v1/object/public/product_images/A/products/item.jpg'),
        ('A', 'https://example.test/storage/v1/object/public/product_images/B/products/item.jpg'),
        ('A', 'https://example.test/storage/v1/object/public/product_images/A/products/missing.jpg');
      insert into storage.objects values
        ('product_images', 'logos/old.jpg'),
        ('product_images', 'logos/.emptyFolderPlaceholder');
    `);
    const preflightSql = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'private_image_rollout_diagnostic.sql'), 'utf8',
    );
    const beforePreflight = (await db.query('select * from storage.buckets order by id')).rows;
    const preflight = (await db.query(preflightSql)).rows[0].diagnostic;
    assert.deepEqual((await db.query('select * from storage.buckets order by id')).rows, beforePreflight);
    const productBucket = preflight.buckets.find(bucket => bucket.id === 'product_images');
    assert.equal(productBucket.public, true);
    assert.equal(productBucket.objects_without_known_business, 1);
    assert.equal(productBucket.placeholders, 1);
    const references = preflight.references.find(row => row.kind === 'products');
    assert.equal(references.paths_outside_row_business, 1);
    assert.equal(references.unresolved_object_paths, 1);
    assert.equal(preflight.authenticated_api_and_offline_tests_still_required, true);
    await db.exec("delete from storage.objects where name in ('logos/old.jpg', 'logos/.emptyFolderPlaceholder')");
    await db.exec('set role anon');
    await db.query("insert into storage.objects values ('player_avatars', 'A/anonymous-before.jpg')");
    await db.exec("reset role; delete from storage.objects where name = 'A/anonymous-before.jpg'");
    const emergencyGuard = fs.readFileSync(
      path.join(__dirname, '..', 'supabase', 'anonymous_avatar_insert_guard.sql'), 'utf8',
    );
    await db.exec(emergencyGuard);
    await db.exec(emergencyGuard);
    await db.exec('set role anon');
    await assert.rejects(db.query("insert into storage.objects values ('player_avatars', 'A/anonymous-after.jpg')"), /row-level security/i);
    await db.query("insert into storage.objects values ('other', 'anonymous-other')");
    await db.exec(`reset role;
      delete from storage.objects where name = 'anonymous-other';
      set role authenticated`);
    await db.query("select set_config('request.jwt.claim.sub', $1, false)", [
      '00000000-0000-0000-0000-000000000001',
    ]);
    await db.query("insert into storage.objects values ('player_avatars', 'A/admin-before.jpg')");
    await db.exec("reset role; delete from storage.objects where name = 'A/admin-before.jpg'");
    await db.exec(staffSql);
    await db.exec(sql);
    await db.exec(staffSql);
    await db.exec(sql);
    assert.deepEqual((await db.query('select id from storage.buckets where public order by id')).rows, [{id: 'other'}]);
    const asUser = id => db.query("select set_config('request.jwt.claim.sub', $1, false)", [
      `00000000-0000-0000-0000-${id.toString().padStart(12, '0')}`,
    ]);
    const visible = async () => (await db.query('select name from storage.objects order by name')).rows.map(row => row.name);
    await db.exec('set role anon');
    await db.query("select set_config('request.jwt.claim.sub', '', false)");
    assert.deepEqual(await visible(), ['shared']);
    await assert.rejects(db.query("insert into storage.objects values ('product_images', 'A/new.jpg')"), /row-level security/i);
    await assert.rejects(db.query("insert into storage.objects values ('player_avatars', 'A/anonymous.jpg')"), /row-level security/i);
    await db.exec('set role authenticated');
    await asUser(1);
    assert.deepEqual(await visible(), ['A/logos/logo.jpg', 'A/other.jpg', 'A/products/item.jpg', 'A/self.jpg', 'shared']);
    await db.query("insert into storage.objects values ('product_images', 'A/products/new.jpg')");
    await assert.rejects(db.query("insert into storage.objects values ('product_images', 'B/products/new.jpg')"), /row-level security/i);
    await assert.rejects(db.query("update storage.objects set name = 'B/new.jpg' where name = 'A/products/new.jpg'"), /row-level security/i);
    await asUser(3);
    assert.deepEqual(await visible(), ['A/logos/logo.jpg', 'A/other.jpg', 'A/self.jpg']);
    await db.query("insert into storage.objects values ('player_avatars', 'A/new.jpg')");
    await assert.rejects(db.query("insert into storage.objects values ('product_images', 'A/new.jpg')"), /row-level security/i);
    await asUser(4);
    assert.deepEqual(await visible(), ['A/logos/logo.jpg', 'A/products/item.jpg', 'A/products/new.jpg']);
    await asUser(5);
    assert.deepEqual(await visible(), ['A/self.jpg']);
    await assert.rejects(db.query("insert into storage.objects values ('player_avatars', 'A/forbidden.jpg')"), /row-level security/i);
    for (const id of [6, 7]) {
      await asUser(id);
      assert.deepEqual(await visible(), id === 6 ? ['shared'] : []);
    }
    await asUser(2);
    assert.deepEqual(await visible(), ['B/avatar.jpg', 'B/logos/logo.jpg', 'B/products/item.jpg', 'shared']);
  } finally {
    await db.close();
  }
});
