-- Partial preparation only. Do not deploy or enable staff accounts yet.
-- Requires add_player_registration.sql. Resolve duplicate or orphaned business
-- identities explicitly before deployment; this script never chooses an owner.
begin;

lock table public.billar_settings, public.business_memberships in share row exclusive mode;

create table if not exists public.business_identity_registry (
    billar_id text primary key,
    owner_user_id uuid not null,
    created_at timestamptz not null default now()
);
alter table public.business_identity_registry enable row level security;
revoke all on public.business_identity_registry from public, anon, authenticated;

do $$
begin
    if exists (
        select 1 from public.billar_settings
        group by billar_id having count(*) > 1
    ) then
        raise exception 'Hay identificadores de billar duplicados; deben revisarse antes de activar la protección.'
            using errcode = '23505';
    end if;
    if exists (
        select 1 from public.billar_settings settings
        join public.business_identity_registry registry on registry.billar_id = settings.billar_id
        where registry.owner_user_id is distinct from settings.user_id
    ) then
        raise exception 'Hay identificadores de billar con propietarios incompatibles.'
            using errcode = '23505';
    end if;
    if exists (
        select 1 from public.business_memberships membership
        where not exists (
            select 1 from public.billar_settings settings
            where settings.billar_id = membership.billar_id
        ) and not exists (
            select 1 from public.business_identity_registry registry
            where registry.billar_id = membership.billar_id
        )
    ) then
        raise exception 'Hay membresías sin propietario registrado; deben revisarse antes de activar la protección.'
            using errcode = '23503';
    end if;
end;
$$;

insert into public.business_identity_registry (billar_id, owner_user_id)
select billar_id, user_id from public.billar_settings
on conflict (billar_id) do nothing;

create unique index if not exists billar_settings_billar_id_unique
    on public.billar_settings (billar_id);

create or replace function public.sync_billar_admin_membership()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    insert into public.business_memberships (user_id, billar_id, email, role)
    select new.user_id, new.billar_id, coalesce(users.email, ''), 'admin'
    from auth.users users
    where users.id = new.user_id
    on conflict (user_id, billar_id) do update
    set email = excluded.email;
    return new;
end;
$$;

create or replace function public.guard_business_identity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    registered_owner uuid;
begin
    if new.billar_id is null or btrim(new.billar_id) = '' or new.user_id is null then
        raise exception 'La identidad del billar no es válida.' using errcode = '22023';
    end if;
    if tg_op = 'UPDATE' then
        if new.billar_id is distinct from old.billar_id or new.user_id is distinct from old.user_id then
            raise exception 'La identidad del billar no puede modificarse directamente.'
                using errcode = '42501';
        end if;
        return new;
    end if;

    insert into public.business_identity_registry (billar_id, owner_user_id)
    values (new.billar_id, new.user_id)
    on conflict (billar_id) do nothing;
    select owner_user_id into strict registered_owner
    from public.business_identity_registry where billar_id = new.billar_id;
    if registered_owner is distinct from new.user_id then
        raise exception 'El identificador del billar pertenece a otra cuenta.'
            using errcode = '42501';
    end if;
    return new;
end;
$$;

revoke all on function public.guard_business_identity() from public, anon, authenticated;
drop trigger if exists guard_business_identity on public.billar_settings;
create trigger guard_business_identity
before insert or update of user_id, billar_id on public.billar_settings
for each row execute function public.guard_business_identity();

commit;
