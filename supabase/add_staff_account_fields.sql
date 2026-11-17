-- Preparation only: these fields do not grant access to POS modules.
-- Server-side authorization must be implemented and verified before enabling
-- the creation or login of staff accounts using these fields.
begin;

set local lock_timeout = '3s';
set local statement_timeout = '30s';

alter table public.business_memberships
    add column if not exists username text,
    add column if not exists full_name text not null default '',
    add column if not exists job_title text not null default '',
    add column if not exists allowed_modules text[] not null default '{}',
    add column if not exists staff_revision bigint not null default 0;

create unique index if not exists business_memberships_username_unique
    on public.business_memberships (username)
    where username is not null;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.business_memberships'::regclass
          and conname = 'business_memberships_username_format'
    ) then
        alter table public.business_memberships
            add constraint business_memberships_username_format
            check (username is null or username ~ '^[a-z0-9][a-z0-9._-]{2,31}$');
    end if;

    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.business_memberships'::regclass
          and conname = 'business_memberships_allowed_modules_valid'
    ) then
        alter table public.business_memberships
            add constraint business_memberships_allowed_modules_valid
            check (
                allowed_modules <@ array[
                    'quick_sale', 'billiard_tables', 'dine_in',
                    'personal_account', 'inventory', 'purchases',
                    'reports', 'players', 'settings'
                ]::text[]
            );
    end if;
end;
$$;

commit;
