-- Partial preparation: do not deploy until the client and business isolation
-- are validated together. Requires add_player_registration.sql.
begin;

alter table public.providers
    add column if not exists is_active boolean not null default true;

create table if not exists public.provider_archive_requests (
    request_id uuid primary key,
    actor_id uuid not null,
    billar_id text not null,
    provider_id bigint not null,
    completed boolean not null default false,
    completed_at timestamptz
);
alter table public.provider_archive_requests enable row level security;
revoke all on public.provider_archive_requests from public, anon, authenticated;

create or replace function public.archive_provider_idempotent(
    p_request_id uuid,
    p_billar_id text,
    p_provider_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    actor uuid := auth.uid();
    request_row public.provider_archive_requests%rowtype;
    membership public.business_memberships%rowtype;
    owner_id uuid;
    business_count bigint;
    provider_business text;
begin
    if actor is null or p_request_id is null or p_billar_id is null
       or btrim(p_billar_id) = '' or p_provider_id is null or p_provider_id <= 0 then
        raise exception 'La solicitud de archivado no es válida.' using errcode = '22023';
    end if;

    lock table public.billar_settings, public.business_memberships in share mode;
    select count(*) into business_count
    from public.billar_settings where billar_id = p_billar_id;
    if business_count <> 1 then
        raise exception 'No hay una configuración única para este billar.' using errcode = '42501';
    end if;
    select user_id into strict owner_id
    from public.billar_settings where billar_id = p_billar_id;
    select * into membership from public.business_memberships
    where user_id = actor and billar_id = p_billar_id;
    if not found or owner_id is distinct from actor
       or not membership.is_active or membership.role <> 'admin'
       or membership.must_change_password then
        raise exception 'Solo un administrador activo puede archivar proveedores.'
            using errcode = '42501';
    end if;

    insert into public.provider_archive_requests (
        request_id, actor_id, billar_id, provider_id
    ) values (
        p_request_id, actor, p_billar_id, p_provider_id
    ) on conflict (request_id) do nothing;
    select * into strict request_row
    from public.provider_archive_requests where request_id = p_request_id
    for update;
    if request_row.actor_id is distinct from actor
       or request_row.billar_id is distinct from p_billar_id
       or request_row.provider_id is distinct from p_provider_id then
        raise exception 'El identificador de solicitud ya fue utilizado.'
            using errcode = '23505';
    end if;
    if not request_row.completed then
        select billar_id into provider_business from public.providers
        where id = p_provider_id for update;
        if not found or provider_business is distinct from p_billar_id then
            raise exception 'El proveedor no está disponible en este billar.'
                using errcode = '42501';
        end if;
        update public.providers set is_active = false
        where id = p_provider_id and billar_id = p_billar_id;
        update public.provider_archive_requests
        set completed = true, completed_at = now()
        where request_id = p_request_id;
    end if;

    return jsonb_build_object(
        'request_id', p_request_id,
        'billar_id', p_billar_id,
        'provider_id', p_provider_id,
        'archived', true
    );
end;
$$;

revoke all on function public.archive_provider_idempotent(uuid, text, bigint)
from public, anon, authenticated;
grant execute on function public.archive_provider_idempotent(uuid, text, bigint)
to authenticated;
commit;
