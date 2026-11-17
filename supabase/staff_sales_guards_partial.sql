-- Partial preparation only. Do not apply or enable staff accounts until
-- POS dependencies, online-only operation and audit have been verified.
-- Staff writes remain blocked until an atomic, audited sale endpoint exists.
-- Requires add_staff_account_fields.sql, add_sales_origin.sql and
-- add_player_registration.sql.
begin;

create or replace function public.has_staff_pos_module_access(
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
          and membership.role = 'manager'
          and not membership.must_change_password
          and membership.username is not null
          and requested_module = any (membership.allowed_modules)
    );
$$;

revoke all on function public.has_staff_pos_module_access(text, text) from public, anon, authenticated;
grant execute on function public.has_staff_pos_module_access(text, text) to authenticated;

alter table public.sales_history enable row level security;
drop policy if exists "business_admin_only" on public.sales_history;
drop policy if exists "owner_business_scope" on public.sales_history;
drop policy if exists "staff_sales_permissive" on public.sales_history;
create policy "staff_sales_permissive" on public.sales_history
for all to authenticated using (true) with check (true);

drop policy if exists "staff_sales_select" on public.sales_history;
create policy "staff_sales_select" on public.sales_history
as restrictive for select to authenticated
using (
    public.has_billar_role(billar_id, array['admin']::text[])
    or public.has_staff_pos_module_access(billar_id, 'reports')
    or public.has_staff_pos_module_access(billar_id, source_module)
);

drop policy if exists "staff_sales_insert" on public.sales_history;
create policy "staff_sales_insert" on public.sales_history
as restrictive for insert to authenticated
with check (
    public.has_billar_role(billar_id, array['admin']::text[])
);

drop policy if exists "staff_sales_update" on public.sales_history;
create policy "staff_sales_update" on public.sales_history
as restrictive for update to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]))
with check (public.has_billar_role(billar_id, array['admin']::text[]));

drop policy if exists "staff_sales_delete" on public.sales_history;
create policy "staff_sales_delete" on public.sales_history
as restrictive for delete to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]));

alter table public.sale_details enable row level security;
drop policy if exists "business_admin_only" on public.sale_details;
drop policy if exists "owner_business_scope" on public.sale_details;
drop policy if exists "staff_sale_details_permissive" on public.sale_details;
create policy "staff_sale_details_permissive" on public.sale_details
for all to authenticated using (true) with check (true);

drop policy if exists "staff_sale_details_select" on public.sale_details;
create policy "staff_sale_details_select" on public.sale_details
as restrictive for select to authenticated
using (
    exists (
        select 1 from public.sales_history sale
        where sale.id = sale_details.sale_id
          and (
              public.has_billar_role(sale.billar_id, array['admin']::text[])
              or public.has_staff_pos_module_access(sale.billar_id, 'reports')
          )
    )
);

drop policy if exists "staff_sale_details_insert" on public.sale_details;
create policy "staff_sale_details_insert" on public.sale_details
as restrictive for insert to authenticated
with check (
    exists (
        select 1 from public.sales_history sale
        where sale.id = sale_details.sale_id
          and public.has_billar_role(sale.billar_id, array['admin']::text[])
          and (sale_details.product_id is null or exists (
              select 1 from public.products product
              where product.id = sale_details.product_id
                and product.billar_id = sale.billar_id
          ))
    )
);

drop policy if exists "staff_sale_details_update" on public.sale_details;
create policy "staff_sale_details_update" on public.sale_details
as restrictive for update to authenticated
using (
    exists (
        select 1 from public.sales_history sale
        where sale.id = sale_details.sale_id
          and public.has_billar_role(sale.billar_id, array['admin']::text[])
    )
)
with check (
    exists (
        select 1 from public.sales_history sale
        where sale.id = sale_details.sale_id
          and public.has_billar_role(sale.billar_id, array['admin']::text[])
          and (sale_details.product_id is null or exists (
              select 1 from public.products product
              where product.id = sale_details.product_id
                and product.billar_id = sale.billar_id
          ))
    )
);

drop policy if exists "staff_sale_details_delete" on public.sale_details;
create policy "staff_sale_details_delete" on public.sale_details
as restrictive for delete to authenticated
using (
    exists (
        select 1 from public.sales_history sale
        where sale.id = sale_details.sale_id
          and public.has_billar_role(sale.billar_id, array['admin']::text[])
    )
);

commit;
