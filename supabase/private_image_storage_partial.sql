-- Preparation only. Do not deploy until the client uses scoped paths and
-- authenticated image downloads. Legacy public URLs will stop working.
-- Requires add_player_registration.sql and add_staff_account_fields.sql.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

do $$
begin
  if (select count(*) from storage.buckets
      where id in ('product_images', 'promo_images', 'player_avatars')) <> 3 then
    raise exception 'Faltan buckets de imágenes; revisar antes de continuar.'
      using errcode = '55000';
  end if;
end;
$$;

create or replace function public.can_access_private_image(
  image_bucket text,
  image_name text,
  write_access boolean
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select auth.uid() is not null
    and image_bucket in ('product_images', 'promo_images', 'player_avatars')
    and position('/' in image_name) > 1
    and (
      exists (
        select 1 from public.business_memberships m
        where m.user_id = auth.uid()
          and m.billar_id = split_part(image_name, '/', 1)
          and m.is_active and not m.must_change_password
          and (
            (m.role = 'admin' and exists (
              select 1 from public.billar_settings s
              where s.user_id = m.user_id and s.billar_id = m.billar_id
            ))
            or (
              m.role = 'manager'
              and (
                (image_bucket = 'player_avatars' and (
                  m.username is null or 'players' = any(m.allowed_modules)
                ))
                or (
                  not write_access and image_bucket = 'product_images'
                  and split_part(image_name, '/', 2) = 'logos'
                  and (m.username is null or 'players' = any(m.allowed_modules))
                )
                or (
                  not write_access and image_bucket in ('product_images', 'promo_images')
                  and (m.allowed_modules && array[
                    'quick_sale', 'billiard_tables', 'dine_in', 'personal_account',
                    'inventory', 'purchases', 'reports', 'settings'
                  ]::text[])
                )
              )
            )
          )
      )
      or (
        not write_access and image_bucket = 'player_avatars'
        and exists (
          select 1 from public.players p
          where p.auth_user_id = auth.uid()
            and p.billar_id = split_part(image_name, '/', 1)
            and p.is_active and not p.must_change_password
            and p.expires_at > now()
            and (
              right(coalesce(p.avatar_url, ''), length('/player_avatars/' || image_name))
                = '/player_avatars/' || image_name
              or right(coalesce(p.avatar, ''), length('/player_avatars/' || image_name))
                = '/player_avatars/' || image_name
            )
        )
      )
    );
$$;

revoke all on function public.can_access_private_image(text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.can_access_private_image(text, text, boolean)
  to anon, authenticated;

-- Replace the older global restriction, which otherwise blocks player reads
-- and all manager product reads even when the new policies allow them.
drop policy if exists player_accounts_block_storage on storage.objects;
create policy player_accounts_block_storage on storage.objects
as restrictive for all to authenticated
using (
  case when bucket_id in ('product_images', 'promo_images', 'player_avatars')
    then public.can_access_private_image(bucket_id, name, false)
    else public.is_billar_admin_account()
  end
)
with check (
  case when bucket_id in ('product_images', 'promo_images', 'player_avatars')
    then public.can_access_private_image(bucket_id, name, false)
    else public.is_billar_admin_account()
  end
);

drop policy if exists private_image_select on storage.objects;
create policy private_image_select on storage.objects as restrictive for select to public
using (
  bucket_id not in ('product_images', 'promo_images', 'player_avatars')
  or public.can_access_private_image(bucket_id, name, false)
);
drop policy if exists private_image_insert on storage.objects;
create policy private_image_insert on storage.objects as restrictive for insert to public
with check (
  bucket_id not in ('product_images', 'promo_images', 'player_avatars')
  or public.can_access_private_image(bucket_id, name, true)
);
drop policy if exists private_image_update on storage.objects;
create policy private_image_update on storage.objects as restrictive for update to public
using (
  bucket_id not in ('product_images', 'promo_images', 'player_avatars')
  or public.can_access_private_image(bucket_id, name, true)
)
with check (
  bucket_id not in ('product_images', 'promo_images', 'player_avatars')
  or public.can_access_private_image(bucket_id, name, true)
);
drop policy if exists private_image_delete on storage.objects;
create policy private_image_delete on storage.objects as restrictive for delete to public
using (
  bucket_id not in ('product_images', 'promo_images', 'player_avatars')
  or public.can_access_private_image(bucket_id, name, true)
);

update storage.buckets set public = false
where id in ('product_images', 'promo_images', 'player_avatars');
commit;
