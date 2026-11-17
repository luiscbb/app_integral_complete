-- Preparation only. Do not deploy until the administrator client uses this
-- RPC for every promo creation, edit and archive, including offline retries.
-- Legacy direct promo writes will be blocked by the restrictive policies.
-- Requires product_stock_conflict_guard_partial.sql and owner identity guards.
begin;

create table if not exists public.owner_promo_requests (
    request_id uuid primary key,
    actor_id uuid not null,
    billar_id text not null,
    request_payload jsonb not null,
    result_revision bigint,
    completed boolean not null default false
);
alter table public.owner_promo_requests enable row level security;
revoke all on public.owner_promo_requests from public, anon, authenticated;

alter table public.products enable row level security;
drop policy if exists promo_rpc_insert_only on public.products;
create policy promo_rpc_insert_only on public.products
as restrictive for insert to authenticated with check (is_promo <> 1);
drop policy if exists promo_rpc_update_only on public.products;
create policy promo_rpc_update_only on public.products
as restrictive for update to authenticated
using (is_promo <> 1) with check (is_promo <> 1);
drop policy if exists promo_rpc_delete_only on public.products;
create policy promo_rpc_delete_only on public.products
as restrictive for delete to authenticated using (is_promo <> 1);

alter table public.promo_items enable row level security;
drop policy if exists promo_items_rpc_insert_only on public.promo_items;
create policy promo_items_rpc_insert_only on public.promo_items
as restrictive for insert to authenticated with check (false);
drop policy if exists promo_items_rpc_update_only on public.promo_items;
create policy promo_items_rpc_update_only on public.promo_items
as restrictive for update to authenticated using (false) with check (false);
drop policy if exists promo_items_rpc_delete_only on public.promo_items;
create policy promo_items_rpc_delete_only on public.promo_items
as restrictive for delete to authenticated using (false);

create or replace function public.sync_owner_promo(
    p_request_id uuid,
    p_billar_id text,
    p_product_id bigint,
    p_expected_revision bigint,
    p_product jsonb,
    p_components jsonb
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    actor uuid := auth.uid();
    payload jsonb;
    request_row public.owner_promo_requests%rowtype;
    promo public.products%rowtype;
    component jsonb;
    component_id bigint;
    quantity integer;
    seen bigint[] := '{}';
    v_price double precision;
    v_cost double precision;
    revision bigint;
begin
    if actor is null or p_request_id is null or p_billar_id is null
       or btrim(p_billar_id) = '' or p_product_id is null or p_product_id <= 0
       or (p_expected_revision is not null and p_expected_revision < 0)
       or jsonb_typeof(p_product) is distinct from 'object'
       or jsonb_typeof(p_components) is distinct from 'array' then
        raise exception 'Datos de promoción inválidos.' using errcode = '22023';
    end if;
    if jsonb_array_length(p_components) = 0
       or jsonb_typeof(p_product -> 'name') is distinct from 'string'
       or btrim(p_product ->> 'name') = ''
       or jsonb_typeof(p_product -> 'price') is distinct from 'number'
       or jsonb_typeof(p_product -> 'cost') is distinct from 'number'
       or jsonb_typeof(p_product -> 'is_active') is distinct from 'boolean' then
        raise exception 'Datos de promoción inválidos.' using errcode = '22023';
    end if;
    v_price := (p_product ->> 'price')::double precision;
    v_cost := (p_product ->> 'cost')::double precision;
    if (v_price >= 0 and v_price < 'Infinity'::double precision) is not true
       or (v_cost >= 0 and v_cost < 'Infinity'::double precision) is not true then
        raise exception 'Precio o costo inválido.' using errcode = '22023';
    end if;
    perform 1 from public.billar_settings settings
    join public.business_memberships membership
      on membership.user_id = settings.user_id
      and membership.billar_id = settings.billar_id
    where settings.user_id = actor and settings.billar_id = p_billar_id
      and membership.role = 'admin' and membership.is_active
      and not membership.must_change_password
    for share of settings, membership;
    if not found then
        raise exception 'Se requiere un administrador activo del billar.' using errcode = '42501';
    end if;

    payload := jsonb_build_object(
        'product_id', p_product_id, 'expected_revision', p_expected_revision,
        'product', p_product, 'components', p_components
    );
    insert into public.owner_promo_requests (request_id, actor_id, billar_id, request_payload)
    values (p_request_id, actor, p_billar_id, payload) on conflict do nothing;
    select * into strict request_row from public.owner_promo_requests
    where request_id = p_request_id for update;
    if request_row.actor_id <> actor or request_row.billar_id <> p_billar_id
       or request_row.request_payload <> payload then
        raise exception 'El identificador de promoción ya fue utilizado.' using errcode = '23505';
    end if;
    if request_row.completed then
        return request_row.result_revision;
    end if;

    select * into promo from public.products where id = p_product_id for update;
    if found then
        if promo.billar_id <> p_billar_id or promo.is_promo <> 1 or promo.parent_id is not null then
            raise exception 'La promoción no pertenece a este billar.' using errcode = '42501';
        end if;
        if promo.stock_revision is distinct from p_expected_revision then
            raise exception 'La promoción cambió en otro dispositivo.' using errcode = '40001';
        end if;
        update public.products set
            name = p_product ->> 'name', barcode = p_product ->> 'barcode',
            description = p_product ->> 'description', price = v_price, cost = v_cost,
            image_path = p_product ->> 'image_path', category = p_product ->> 'category',
            presentation = p_product ->> 'presentation',
            is_active = (p_product ->> 'is_active')::boolean,
            stock_revision = promo.stock_revision + 1
        where id = p_product_id returning stock_revision into revision;
    else
        if p_expected_revision is not null then
            raise exception 'La promoción ya no existe.' using errcode = '40001';
        end if;
        insert into public.products (
            id, billar_id, name, barcode, description, price, cost, stock,
            image_path, is_promo, parent_id, pieces_per_unit, category,
            presentation, is_active, stock_revision
        ) values (
            p_product_id, p_billar_id, p_product ->> 'name', p_product ->> 'barcode',
            p_product ->> 'description', v_price, v_cost, 0,
            p_product ->> 'image_path', 1, null, 1, p_product ->> 'category',
            p_product ->> 'presentation', (p_product ->> 'is_active')::boolean, 0
        ) returning stock_revision into revision;
    end if;

    delete from public.promo_items where parent_id = p_product_id;
    for component in
        select value from jsonb_array_elements(p_components)
        order by (value ->> 'product_id')::bigint
    loop
        if jsonb_typeof(component) is distinct from 'object'
           or jsonb_typeof(component -> 'product_id') is distinct from 'number'
           or jsonb_typeof(component -> 'quantity') is distinct from 'number'
           or (component ->> 'product_id')::numeric <> trunc((component ->> 'product_id')::numeric)
           or (component ->> 'quantity')::numeric <> trunc((component ->> 'quantity')::numeric) then
            raise exception 'Componente de promoción inválido.' using errcode = '22023';
        end if;
        component_id := (component ->> 'product_id')::bigint;
        quantity := (component ->> 'quantity')::integer;
        if component_id <= 0 or quantity <= 0 or component_id = any(seen) then
            raise exception 'Componente de promoción inválido.' using errcode = '22023';
        end if;
        seen := array_append(seen, component_id);
        perform 1 from public.products child
        where child.id = component_id and child.billar_id = p_billar_id
          and (child.is_active or not (p_product ->> 'is_active')::boolean)
          and child.parent_id is null and child.is_promo = 0
        for update;
        if not found then
            raise exception 'El componente no pertenece al billar o no está activo.'
                using errcode = '42501';
        end if;
        insert into public.promo_items (parent_id, child_id, quantity)
        values (p_product_id, component_id, quantity);
    end loop;
    update public.owner_promo_requests set completed = true, result_revision = revision
    where request_id = p_request_id;
    return revision;
end;
$$;
revoke all on function public.sync_owner_promo(uuid, text, bigint, bigint, jsonb, jsonb)
    from public, anon, authenticated;

create or replace function public.read_owner_promo_snapshot(
    p_billar_id text,
    p_product_id bigint
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
    result jsonb;
begin
    if p_billar_id is null or btrim(p_billar_id) = ''
       or p_product_id is null or p_product_id <= 0
       or not exists (
           select 1 from public.billar_settings settings
           join public.business_memberships membership
             on membership.user_id = settings.user_id
            and membership.billar_id = settings.billar_id
           where settings.user_id = auth.uid()
             and settings.billar_id = p_billar_id
             and membership.role = 'admin' and membership.is_active
             and not membership.must_change_password
       ) then
        raise exception 'Se requiere un administrador activo del billar.' using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.products promo
        where promo.id = p_product_id and promo.billar_id = p_billar_id
          and promo.is_promo = 1 and promo.parent_id is null
    ) then
        raise exception 'La promoción no existe en el billar.' using errcode = '22023';
    end if;

    if exists (
        select 1 from public.promo_items item
        left join public.products child on child.id = item.child_id
        where item.parent_id = p_product_id
          and (child.id is null or child.billar_id <> p_billar_id
            or child.is_promo <> 0 or child.parent_id is not null
            or item.quantity is null or item.quantity <= 0)
    ) or exists (
        select 1 from public.promo_items item
        where item.parent_id = p_product_id
        group by item.child_id having count(*) > 1
    ) then
        raise exception 'Los componentes de la promoción no son válidos.' using errcode = '22023';
    end if;

    select jsonb_build_object(
        'product', to_jsonb(promo),
        'components', coalesce((
            select jsonb_agg(jsonb_build_object(
                'child_id', item.child_id, 'quantity', item.quantity
            ) order by item.child_id)
            from public.promo_items item where item.parent_id = promo.id
        ), '[]'::jsonb)
    ) into result
    from public.products promo
    where promo.id = p_product_id and promo.billar_id = p_billar_id
      and promo.is_promo = 1 and promo.parent_id is null;
    if result is null or jsonb_array_length(result -> 'components') = 0 then
        raise exception 'La promoción no existe o no tiene componentes válidos.' using errcode = '22023';
    end if;
    return result;
end;
$$;
revoke all on function public.read_owner_promo_snapshot(text, bigint)
    from public, anon, authenticated;
commit;
