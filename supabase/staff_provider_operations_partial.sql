-- Preparation only: do not deploy or enable staff purchases yet.
-- Requires staff account fields, staff_purchases_guards_partial.sql and
-- provider_delete_idempotent_partial.sql and provider_credit_terms_partial.sql.
-- No execution grants are enabled.
-- The client must persist the UUID, provider ID and exact payload before sending.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

create table if not exists public.staff_provider_requests (
    request_id uuid primary key,
    billar_id text not null,
    actor_id uuid not null,
    request_payload jsonb not null,
    result jsonb
);
alter table public.staff_provider_requests enable row level security;
revoke all on public.staff_provider_requests from public, anon, authenticated;

create table if not exists public.staff_provider_audit (
    request_id uuid primary key references public.staff_provider_requests(request_id),
    billar_id text not null,
    actor_id uuid not null,
    provider_id bigint not null,
    operation text not null check (operation in ('create', 'update', 'archive')),
    old_values jsonb,
    new_values jsonb not null,
    recorded_at timestamptz not null default clock_timestamp()
);
alter table public.staff_provider_audit enable row level security;
revoke all on public.staff_provider_audit from public, anon, authenticated;
grant select on public.staff_provider_audit to authenticated;
drop policy if exists staff_provider_audit_admin_select on public.staff_provider_audit;
create policy staff_provider_audit_admin_select on public.staff_provider_audit
for select to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]));

create or replace function public.apply_staff_provider_operation(
    p_request_id uuid,
    p_billar_id text,
    p_provider_id bigint,
    p_operation text,
    p_provider jsonb,
    p_product_ids bigint[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    actor uuid := auth.uid();
    metadata jsonb := auth.jwt() -> 'app_metadata';
    payload jsonb;
    request_row public.staff_provider_requests%rowtype;
    provider_row public.providers%rowtype;
    previous_values jsonb;
    current_values jsonb;
    receipt jsonb;
    field text;
begin
    if actor is null or metadata ->> 'account_type' is distinct from 'staff'
       or metadata ->> 'billar_id' is distinct from p_billar_id then
        raise exception 'Se requiere una cuenta de personal de este billar.'
            using errcode = '42501';
    end if;
    if p_request_id is null or p_billar_id is null or btrim(p_billar_id) = ''
       or p_provider_id is null or p_provider_id <= 0
       or p_operation is null or p_operation not in ('create', 'update', 'archive')
       or jsonb_typeof(p_provider) is distinct from 'object'
       or p_product_ids is null then
        raise exception 'La operación de proveedor no es válida.' using errcode = '22023';
    end if;
    if exists (select 1 from unnest(p_product_ids) requested(id) where requested.id is null or requested.id <= 0)
       or cardinality(p_product_ids) <> (select count(distinct requested.id) from unnest(p_product_ids) requested(id))
       or (cardinality(p_product_ids) > 0 and array_ndims(p_product_ids) <> 1) then
        raise exception 'La lista de productos no es válida.' using errcode = '22023';
    end if;
    if p_operation = 'archive' then
        if p_provider <> '{}'::jsonb or cardinality(p_product_ids) <> 0 then
            raise exception 'El archivado no admite cambios adicionales.' using errcode = '22023';
        end if;
    else
        if (select count(*) from jsonb_object_keys(p_provider)) not in (8, 10) then
            raise exception 'Los datos del proveedor no están completos.' using errcode = '22023';
        end if;
        foreach field in array array[
            'name', 'phone', 'email', 'address', 'contact_name', 'notes', 'category', 'visit_days'
        ] loop
            if jsonb_typeof(p_provider -> field) is distinct from 'string' then
                raise exception 'Los datos del proveedor no son válidos.' using errcode = '22023';
            end if;
        end loop;
        if btrim(p_provider ->> 'name') = '' then
            raise exception 'El nombre del proveedor es obligatorio.' using errcode = '22023';
        end if;
        if (select count(*) from jsonb_object_keys(p_provider)) = 10 then
            if not (p_provider ?& array['credit_days', 'preferred_payment_method'])
               or jsonb_typeof(p_provider -> 'credit_days') not in ('null', 'number')
               or jsonb_typeof(p_provider -> 'preferred_payment_method') not in ('null', 'string') then
                raise exception 'Las condiciones de pago del proveedor no son válidas.' using errcode = '22023';
            end if;
            if jsonb_typeof(p_provider -> 'credit_days') = 'number' then
                if (p_provider ->> 'credit_days')::numeric < 0
                   or (p_provider ->> 'credit_days')::numeric > 2147483647
                   or (p_provider ->> 'credit_days')::numeric <> trunc((p_provider ->> 'credit_days')::numeric) then
                    raise exception 'Los días de crédito no son válidos.' using errcode = '22023';
                end if;
            end if;
            if jsonb_typeof(p_provider -> 'preferred_payment_method') = 'string'
               and p_provider ->> 'preferred_payment_method' not in ('efectivo', 'tarjeta', 'transferencia', 'credito') then
                raise exception 'La preferencia de pago no es válida.' using errcode = '22023';
            end if;
        end if;
    end if;

    perform 1 from public.business_memberships membership
    where membership.user_id = actor and membership.billar_id = p_billar_id
      and membership.role = 'manager' and membership.is_active
      and not membership.must_change_password
      and membership.username is not null and btrim(membership.username) <> ''
      and 'purchases' = any(membership.allowed_modules)
    for share;
    if not found then
        raise exception 'No tienes permiso para gestionar proveedores.' using errcode = '42501';
    end if;

    payload := jsonb_build_object(
        'provider_id', p_provider_id, 'operation', p_operation,
        'provider', p_provider, 'product_ids', to_jsonb(p_product_ids)
    );
    insert into public.staff_provider_requests(request_id, billar_id, actor_id, request_payload)
    values (p_request_id, p_billar_id, actor, payload)
    on conflict (request_id) do nothing;
    select * into strict request_row from public.staff_provider_requests
    where request_id = p_request_id for update;
    if request_row.billar_id <> p_billar_id or request_row.actor_id <> actor
       or request_row.request_payload <> payload then
        raise exception 'El identificador de solicitud ya fue utilizado.' using errcode = '23505';
    end if;
    if request_row.result is not null then return request_row.result; end if;

    select * into provider_row from public.providers
    where id = p_provider_id for update;
    if p_operation = 'create' then
        if found then
            raise exception 'El identificador de proveedor ya existe.' using errcode = '23505';
        end if;
    else
        if not found or provider_row.billar_id <> p_billar_id or not provider_row.is_active then
            raise exception 'El proveedor no está activo en este billar.' using errcode = '42501';
        end if;
        previous_values := jsonb_build_object(
            'provider', to_jsonb(provider_row),
            'product_ids', (select coalesce(jsonb_agg(product_id order by product_id), '[]'::jsonb)
                from public.provider_products where provider_id = p_provider_id)
        );
    end if;

    perform 1 from public.products product
    where product.billar_id = p_billar_id and product.id = any(p_product_ids)
    order by product.id for share;
    if exists (
        select 1 from unnest(p_product_ids) requested(id) where not exists (
            select 1 from public.products product where product.id = requested.id
              and product.billar_id = p_billar_id
        )
    ) then
        raise exception 'Un producto no pertenece a este billar.' using errcode = '42501';
    end if;

    if p_operation = 'create' then
        insert into public.providers (
            id, billar_id, name, phone, email, address, contact_name, notes, category, visit_days,
            credit_days, preferred_payment_method, is_active
        ) values (
            p_provider_id, p_billar_id, p_provider ->> 'name', p_provider ->> 'phone',
            p_provider ->> 'email', p_provider ->> 'address', p_provider ->> 'contact_name',
            p_provider ->> 'notes', p_provider ->> 'category', p_provider ->> 'visit_days',
            (p_provider ->> 'credit_days')::integer, p_provider ->> 'preferred_payment_method', true
        );
    elsif p_operation = 'update' then
        update public.providers set
            name = p_provider ->> 'name', phone = p_provider ->> 'phone',
            email = p_provider ->> 'email', address = p_provider ->> 'address',
            contact_name = p_provider ->> 'contact_name', notes = p_provider ->> 'notes',
            category = p_provider ->> 'category', visit_days = p_provider ->> 'visit_days',
            credit_days = case when p_provider ? 'credit_days'
                then (p_provider ->> 'credit_days')::integer else provider_row.credit_days end,
            preferred_payment_method = case when p_provider ? 'preferred_payment_method'
                then p_provider ->> 'preferred_payment_method' else provider_row.preferred_payment_method end
        where id = p_provider_id and billar_id = p_billar_id;
    else
        update public.providers set is_active = false
        where id = p_provider_id and billar_id = p_billar_id;
    end if;
    if p_operation <> 'archive' then
        delete from public.provider_products where provider_id = p_provider_id;
        insert into public.provider_products(provider_id, product_id)
        select p_provider_id, requested.id from unnest(p_product_ids) requested(id);
    end if;
    select * into strict provider_row from public.providers
    where id = p_provider_id and billar_id = p_billar_id;
    current_values := jsonb_build_object(
        'provider', to_jsonb(provider_row),
        'product_ids', (select coalesce(jsonb_agg(product_id order by product_id), '[]'::jsonb)
            from public.provider_products where provider_id = p_provider_id)
    );
    insert into public.staff_provider_audit (
        request_id, billar_id, actor_id, provider_id, operation, old_values, new_values
    ) values (
        p_request_id, p_billar_id, actor, p_provider_id, p_operation, previous_values, current_values
    );
    receipt := jsonb_build_object(
        'request_id', p_request_id, 'billar_id', p_billar_id, 'actor_id', actor,
        'provider_id', p_provider_id, 'operation', p_operation,
        'provider', current_values -> 'provider', 'product_ids', current_values -> 'product_ids'
    );
    update public.staff_provider_requests set result = receipt where request_id = p_request_id;
    return receipt;
end;
$$;
revoke all on function public.apply_staff_provider_operation(uuid, text, bigint, text, jsonb, bigint[])
from public, anon, authenticated;
commit;
