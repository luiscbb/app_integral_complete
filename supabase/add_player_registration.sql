-- Player registration, account roles, annual enrollment and authorization.
-- Safe to run on installations using either schema_players.sql or
-- recovery_full_schema.sql.

create table if not exists public.business_memberships (
    user_id uuid not null references auth.users(id) on delete cascade,
    billar_id text not null,
    email text not null default '',
    role text not null check (role in ('admin', 'manager')),
    is_active boolean not null default true,
    must_change_password boolean not null default false,
    created_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    primary key (user_id, billar_id)
);

create index if not exists idx_business_memberships_billar_role
    on public.business_memberships (billar_id, role, is_active);

alter table public.business_memberships enable row level security;

create or replace function public.has_billar_role(
    requested_billar_id text,
    allowed_roles text[] default array['admin', 'manager']::text[]
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
          and membership.role = any (allowed_roles)
    );
$$;

revoke all on function public.has_billar_role(text, text[]) from public;
grant execute on function public.has_billar_role(text, text[]) to authenticated;

create or replace function public.is_billar_admin_account()
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
          and membership.role = 'admin'
          and membership.is_active
    );
$$;

revoke all on function public.is_billar_admin_account() from public;
grant execute on function public.is_billar_admin_account() to authenticated;

-- Existing billar_settings owners become the business administrators.
insert into public.business_memberships (user_id, billar_id, email, role)
select settings.user_id, settings.billar_id, coalesce(users.email, ''), 'admin'
from public.billar_settings settings
join auth.users users on users.id = settings.user_id
on conflict (user_id, billar_id) do update
set email = excluded.email,
    role = 'admin',
    is_active = true;

create or replace function public.sync_billar_admin_membership()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if tg_op = 'UPDATE'
       and (old.user_id is distinct from new.user_id
            or old.billar_id is distinct from new.billar_id) then
        delete from public.business_memberships
        where user_id = old.user_id
          and billar_id = old.billar_id
          and role = 'admin';
    end if;

    insert into public.business_memberships (user_id, billar_id, email, role)
    select new.user_id, new.billar_id, coalesce(users.email, ''), 'admin'
    from auth.users users
    where users.id = new.user_id
    on conflict (user_id, billar_id) do update
    set email = excluded.email,
        role = 'admin',
        is_active = true;

    return new;
end;
$$;

drop trigger if exists billar_settings_admin_membership on public.billar_settings;
create trigger billar_settings_admin_membership
after insert or update of user_id, billar_id on public.billar_settings
for each row execute function public.sync_billar_admin_membership();

drop policy if exists "business_memberships_select" on public.business_memberships;
drop policy if exists "business_memberships_admin_all" on public.business_memberships;
create policy "business_memberships_select"
on public.business_memberships for select to authenticated
using (
    user_id = auth.uid()
    or public.has_billar_role(billar_id, array['admin']::text[])
);
create policy "business_memberships_admin_all"
on public.business_memberships for all to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]))
with check (public.has_billar_role(billar_id, array['admin']::text[]));

create table if not exists public.players (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    nickname text not null default '',
    avatar text not null default '',
    avatar_url text not null default '',
    handicap integer not null default 1,
    wins integer not null default 0,
    losses integer not null default 0,
    draws integer not null default 0,
    total_matches integer not null default 0,
    total_seconds integer not null default 0,
    break_and_run integer not null default 0,
    golden_breaks integer not null default 0,
    high_run integer not null default 0,
    current_streak integer not null default 0,
    best_streak integer not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    local_id integer,
    billar_id text not null default 'BILLAR_001',
    version integer not null default 1,
    cloud_id text,
    auth_user_id uuid references auth.users(id) on delete set null,
    email text,
    phone text not null default '',
    player_code text,
    is_active boolean not null default true,
    registered_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '1 year'),
    archived_at timestamptz,
    must_change_password boolean not null default true,
    client_id text
);

alter table public.players
    add column if not exists avatar text not null default '',
    add column if not exists avatar_url text not null default '',
    add column if not exists handicap integer not null default 1,
    add column if not exists billar_id text not null default 'BILLAR_001',
    add column if not exists local_id integer,
    add column if not exists version integer not null default 1,
    add column if not exists cloud_id text,
    add column if not exists auth_user_id uuid references auth.users(id) on delete set null,
    add column if not exists email text,
    add column if not exists phone text not null default '',
    add column if not exists player_code text,
    add column if not exists is_active boolean not null default true,
    add column if not exists registered_at timestamptz not null default now(),
    add column if not exists expires_at timestamptz not null default (now() + interval '1 year'),
    add column if not exists archived_at timestamptz,
    add column if not exists must_change_password boolean not null default true,
    add column if not exists client_id text,
    add column if not exists updated_at timestamptz not null default now();

update public.players
set avatar_url = avatar
where avatar_url = '' and avatar <> '';

update public.players
set avatar = avatar_url
where avatar = '' and avatar_url <> '';

update public.players
set handicap = greatest(1, least(handicap, 6))
where handicap < 1 or handicap > 6;

update public.players
set registered_at = coalesce(created_at, now()),
    expires_at = now() + interval '1 year'
where registered_at is null or expires_at is null;

update public.players
set player_code = 'JUG-' || upper(substr(replace(id::text, '-', ''), 1, 8))
where player_code is null or btrim(player_code) = '';

update public.players
set client_id = gen_random_uuid()::text
where client_id is null or btrim(client_id) = '';

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.players'::regclass
          and conname = 'players_handicap_range'
    ) then
        alter table public.players
            add constraint players_handicap_range check (handicap between 1 and 6);
    end if;
end;
$$;

create unique index if not exists idx_players_billar_code
    on public.players (billar_id, player_code);
create unique index if not exists idx_players_auth_user
    on public.players (auth_user_id) where auth_user_id is not null;
create unique index if not exists idx_players_billar_client
    on public.players (billar_id, client_id);
create index if not exists idx_players_billar_registered
    on public.players (billar_id, registered_at desc);
create index if not exists idx_players_billar_expiry
    on public.players (billar_id, expires_at);

create or replace function public.assign_player_code()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
    code_candidate text;
    attempts integer := 0;
begin
    if new.player_code is null or btrim(new.player_code) = '' then
        loop
            code_candidate := 'JUG-' || upper(
                substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)
            );
            exit when not exists (
                select 1
                from public.players existing
                where existing.billar_id = new.billar_id
                  and existing.player_code = code_candidate
            );
            attempts := attempts + 1;
            if attempts >= 10 then
                raise exception 'No se pudo generar un código único para el jugador.';
            end if;
        end loop;
        new.player_code := code_candidate;
    end if;
    return new;
end;
$$;

drop trigger if exists players_assign_code on public.players;
create trigger players_assign_code
before insert or update of player_code on public.players
for each row execute function public.assign_player_code();

alter table public.players enable row level security;
drop policy if exists "players_select" on public.players;
drop policy if exists "players_insert" on public.players;
drop policy if exists "players_update" on public.players;
drop policy if exists "players_delete" on public.players;
create policy "players_select"
on public.players for select to authenticated
using (
    auth_user_id = auth.uid()
    or public.has_billar_role(billar_id, array['admin', 'manager']::text[])
);
create policy "players_insert"
on public.players for insert to authenticated
with check (public.has_billar_role(billar_id, array['admin', 'manager']::text[]));
create policy "players_update"
on public.players for update to authenticated
using (public.has_billar_role(billar_id, array['admin', 'manager']::text[]))
with check (public.has_billar_role(billar_id, array['admin', 'manager']::text[]));
create policy "players_delete"
on public.players for delete to authenticated
using (public.has_billar_role(billar_id, array['admin', 'manager']::text[]));

-- Limit the manager account to player management. Restrictive policies are
-- combined with existing policies using AND, so older `USING (true)` policies
-- cannot grant managers access to POS data.
do $$
declare
    table_record record;
begin
    for table_record in
        select tablename
        from pg_tables
        where schemaname = 'public'
          and tablename not in (
              'players',
              'business_memberships',
              'billar_tournaments'
          )
    loop
        execute format(
            'alter table public.%I enable row level security',
            table_record.tablename
        );
        execute format(
            'drop policy if exists "business_admin_only" on public.%I',
            table_record.tablename
        );
        execute format(
            'create policy "business_admin_only" on public.%I as restrictive for all to authenticated using (public.is_billar_admin_account()) with check (public.is_billar_admin_account())',
            table_record.tablename
        );
    end loop;
end;
$$;

drop trigger if exists players_updated_at on public.players;
create trigger players_updated_at before update on public.players
for each row execute function public.set_updated_at();

drop policy if exists "billar_settings_select" on public.billar_settings;
create policy "billar_settings_select"
on public.billar_settings for select to authenticated
using (
    user_id = auth.uid()
    or public.has_billar_role(billar_id, array['admin', 'manager']::text[])
);

drop policy if exists "player_avatars_insert" on storage.objects;
create policy "player_avatars_insert"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'player_avatars'
    and public.has_billar_role((storage.foldername(name))[1], array['admin', 'manager']::text[])
);

drop policy if exists "player_avatars_update" on storage.objects;
create policy "player_avatars_update"
on storage.objects for update to authenticated
using (
    bucket_id = 'player_avatars'
    and public.has_billar_role((storage.foldername(name))[1], array['admin', 'manager']::text[])
)
with check (
    bucket_id = 'player_avatars'
    and public.has_billar_role((storage.foldername(name))[1], array['admin', 'manager']::text[])
);

drop policy if exists "player_avatars_delete" on storage.objects;
create policy "player_avatars_delete"
on storage.objects for delete to authenticated
using (
    bucket_id = 'player_avatars'
    and public.has_billar_role((storage.foldername(name))[1], array['admin', 'manager']::text[])
);

drop policy if exists "player_accounts_block_storage" on storage.objects;
create policy "player_accounts_block_storage"
on storage.objects as restrictive for all to authenticated
using (
    public.is_billar_admin_account()
    or (
        bucket_id = 'player_avatars'
        and public.has_billar_role((storage.foldername(name))[1], array['manager']::text[])
    )
)
with check (
    public.is_billar_admin_account()
    or (
        bucket_id = 'player_avatars'
        and public.has_billar_role((storage.foldername(name))[1], array['manager']::text[])
    )
);
