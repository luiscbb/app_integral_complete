-- Partial preparation only. Do not deploy or enable staff accounts until
-- the POS client uses staff_sale_products and all workflows are audited.
-- Requires add_player_registration.sql and add_staff_account_fields.sql.
-- staff_sale_products.stock is saleable stock, not raw inventory. It does not
-- reserve stock; record_staff_sale must revalidate it at checkout.
-- The expanded RPC result is still an undeployed draft. Requires
-- product_stock_conflict_guard_partial.sql for stock_revision.
begin;

create or replace function public.can_access_inventory(
    requested_billar_id text,
    require_admin boolean
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1 from public.business_memberships membership
        where membership.user_id = auth.uid()
          and membership.billar_id = requested_billar_id
          and membership.is_active
          and not membership.must_change_password
          and (
              membership.role = 'admin'
              or (
                  not require_admin
                  and membership.role = 'manager'
                  and membership.username is not null
                  and membership.allowed_modules && array['inventory', 'purchases', 'reports']::text[]
              )
          )
    );
$$;
revoke all on function public.can_access_inventory(text, boolean) from public, anon, authenticated;
grant execute on function public.can_access_inventory(text, boolean) to authenticated;

create or replace function public.guard_product_business_identity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if new.id is distinct from old.id or new.billar_id is distinct from old.billar_id then
        raise exception 'La identidad del producto no puede modificarse.' using errcode = '42501';
    end if;
    return new;
end;
$$;
revoke all on function public.guard_product_business_identity() from public, anon, authenticated;
drop trigger if exists product_business_identity_guard on public.products;
create trigger product_business_identity_guard before update of id, billar_id on public.products
for each row execute function public.guard_product_business_identity();

alter table public.products enable row level security;
drop policy if exists business_admin_only on public.products;
drop policy if exists owner_business_scope on public.products;
drop policy if exists staff_products_permissive on public.products;
create policy staff_products_permissive on public.products
for all to authenticated using (true) with check (true);

drop policy if exists staff_products_select on public.products;
create policy staff_products_select on public.products
as restrictive for select to authenticated
using (public.can_access_inventory(billar_id, false));
drop policy if exists staff_products_insert on public.products;
create policy staff_products_insert on public.products
as restrictive for insert to authenticated
with check (public.can_access_inventory(billar_id, true));
drop policy if exists staff_products_update on public.products;
create policy staff_products_update on public.products
as restrictive for update to authenticated
using (public.can_access_inventory(billar_id, true))
with check (public.can_access_inventory(billar_id, true));
drop policy if exists staff_products_delete on public.products;
create policy staff_products_delete on public.products
as restrictive for delete to authenticated
using (public.can_access_inventory(billar_id, true));

drop function if exists public.staff_sale_products(text);
create function public.staff_sale_products(p_billar_id text)
returns table (
    id bigint,
    billar_id text,
    barcode text,
    name text,
    description text,
    price double precision,
    stock double precision,
    image_path text,
    is_promo integer,
    parent_id bigint,
    pieces_per_unit integer,
    category text,
    presentation text,
    inventory_stock double precision,
    stock_revision bigint,
    components jsonb
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if p_billar_id is null or btrim(p_billar_id) = '' or not exists (
        select 1 from public.business_memberships membership
        where membership.user_id = auth.uid()
          and membership.billar_id = p_billar_id
          and membership.is_active
          and not membership.must_change_password
          and membership.role = 'manager'
          and membership.username is not null
          and membership.allowed_modules && array[
              'quick_sale', 'billiard_tables', 'dine_in', 'personal_account'
          ]::text[]
    ) then
        raise exception 'No tienes permiso para consultar productos de venta.' using errcode = '42501';
    end if;
    return query
    select product.id, product.billar_id, product.barcode, product.name,
           product.description, product.price::double precision,
           case
               when product.parent_id is not null then coalesce((
                   select parent.stock::double precision / nullif(product.pieces_per_unit, 0)
                   from public.products parent
                   where parent.id = product.parent_id
                     and parent.billar_id = p_billar_id and parent.is_active
                     and parent.parent_id is null and parent.is_promo = 0
                     and product.pieces_per_unit > 0
               ), 0::double precision)
               when product.is_promo = 1 then promo.available_stock
               else product.stock::double precision
           end,
           product.image_path, product.is_promo,
           product.parent_id, product.pieces_per_unit, product.category, product.presentation,
           product.stock::double precision, product.stock_revision,
           coalesce(promo.components, '[]'::jsonb)
    from public.products product
    left join lateral (
        select
            case when bool_and(child.id is not null and grouped.valid_quantity)
                then greatest(0::double precision,
                    floor(min(child.stock::double precision / nullif(grouped.quantity, 0))))
                else 0::double precision end as available_stock,
            case when bool_and(child.id is not null and grouped.valid_quantity)
                then jsonb_agg(jsonb_build_object(
                    'product_id', grouped.child_id, 'quantity', grouped.quantity
                ) order by grouped.child_id)
                else '[]'::jsonb end as components
        from (
            select component.child_id, sum(component.quantity) as quantity,
                bool_and(component.quantity > 0) as valid_quantity
            from public.promo_items component
            where component.parent_id = product.id
            group by component.child_id
        ) grouped
        left join public.products child
          on child.id = grouped.child_id
            and child.billar_id = p_billar_id and child.is_active
            and child.parent_id is null and child.is_promo = 0
    ) promo on product.is_promo = 1
    where product.billar_id = p_billar_id and product.is_active
    order by product.id;
end;
$$;
revoke all on function public.staff_sale_products(text) from public, anon, authenticated;
grant execute on function public.staff_sale_products(text) to authenticated;
commit;
