-- Partial preparation only. Do not enable staff accounts until every POS
-- table, storage operation, Edge Function and local session is protected.
-- Requires add_staff_account_fields.sql.
begin;

create or replace function public.has_staff_module_access(
    requested_billar_id text,
    requested_module text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1
        from public.business_memberships membership
        where membership.user_id = auth.uid()
          and membership.billar_id = requested_billar_id
          and membership.is_active
          and (
              membership.role = 'admin'
              or (
                  membership.role = 'manager'
                  and not membership.must_change_password
                  and (
                      requested_module = any (membership.allowed_modules)
                      or (
                          membership.username is null
                          and requested_module in ('players', 'personal_account')
                      )
                  )
              )
          )
    );
$$;

revoke all on function public.has_staff_module_access(text, text) from public, anon, authenticated;
grant execute on function public.has_staff_module_access(text, text) to authenticated;

drop policy if exists "staff_module_players_select" on public.players;
create policy "staff_module_players_select"
on public.players as restrictive for select to authenticated
using (
    auth_user_id = auth.uid()
    or public.has_staff_module_access(billar_id, 'players')
);

drop policy if exists "staff_module_players_insert" on public.players;
create policy "staff_module_players_insert"
on public.players as restrictive for insert to authenticated
with check (public.has_staff_module_access(billar_id, 'players'));

drop policy if exists "staff_module_players_update" on public.players;
create policy "staff_module_players_update"
on public.players as restrictive for update to authenticated
using (public.has_staff_module_access(billar_id, 'players'))
with check (public.has_staff_module_access(billar_id, 'players'));

drop policy if exists "staff_module_players_delete" on public.players;
create policy "staff_module_players_delete"
on public.players as restrictive for delete to authenticated
using (public.has_staff_module_access(billar_id, 'players'));

drop policy if exists "staff_module_tournaments" on public.billar_tournaments;
create policy "staff_module_tournaments"
on public.billar_tournaments as restrictive for all to authenticated
using (public.has_staff_module_access(billar_id, 'players'))
with check (public.has_staff_module_access(billar_id, 'players'));

-- Replace the older all-business administrator restriction with the
-- business-specific module restriction below.
drop policy if exists "business_admin_only" on public.personal_clients;
drop policy if exists "staff_module_personal_clients" on public.personal_clients;
create policy "staff_module_personal_clients"
on public.personal_clients as restrictive for all to authenticated
using (public.has_staff_module_access(billar_id, 'personal_account'))
with check (public.has_staff_module_access(billar_id, 'personal_account'));

drop policy if exists "business_admin_only" on public.personal_customer_accounts;
drop policy if exists "staff_module_personal_accounts" on public.personal_customer_accounts;
create policy "staff_module_personal_accounts"
on public.personal_customer_accounts as restrictive for all to authenticated
using (public.has_staff_module_access(billar_id, 'personal_account'))
with check (public.has_staff_module_access(billar_id, 'personal_account'));

drop policy if exists "staff_module_player_avatars_insert" on storage.objects;
create policy "staff_module_player_avatars_insert"
on storage.objects as restrictive for insert to authenticated
with check (
    bucket_id is distinct from 'player_avatars'
    or public.has_staff_module_access((storage.foldername(name))[1], 'players')
);

drop policy if exists "staff_module_player_avatars_update" on storage.objects;
create policy "staff_module_player_avatars_update"
on storage.objects as restrictive for update to authenticated
using (
    bucket_id is distinct from 'player_avatars'
    or public.has_staff_module_access((storage.foldername(name))[1], 'players')
)
with check (
    bucket_id is distinct from 'player_avatars'
    or public.has_staff_module_access((storage.foldername(name))[1], 'players')
);

drop policy if exists "staff_module_player_avatars_delete" on storage.objects;
create policy "staff_module_player_avatars_delete"
on storage.objects as restrictive for delete to authenticated
using (
    bucket_id is distinct from 'player_avatars'
    or public.has_staff_module_access((storage.foldername(name))[1], 'players')
);

commit;
