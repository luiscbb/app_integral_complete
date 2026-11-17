-- Partial preparation only. Do not deploy or enable staff accounts yet.
-- Staff writes remain blocked until purchases and provider changes are
-- attributed and audited through server-side operations.
-- Requires staff_module_guards_partial.sql and add_providers_and_tables.sql.
begin;

create or replace function public.guard_purchase_record_identity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if (to_jsonb(old)->tg_argv[0]) is distinct from (to_jsonb(new)->tg_argv[0]) then
        raise exception 'La identidad del registro no puede modificarse directamente.'
            using errcode = '42501';
    end if;
    return new;
end;
$$;
revoke all on function public.guard_purchase_record_identity() from public, anon, authenticated;

drop trigger if exists guard_purchase_business on public.purchases;
create trigger guard_purchase_business before update of billar_id on public.purchases
for each row execute function public.guard_purchase_record_identity('billar_id');
drop trigger if exists guard_purchase_detail_parent on public.purchase_details;
create trigger guard_purchase_detail_parent before update of purchase_id on public.purchase_details
for each row execute function public.guard_purchase_record_identity('purchase_id');
drop trigger if exists guard_provider_business on public.providers;
create trigger guard_provider_business before update of billar_id on public.providers
for each row execute function public.guard_purchase_record_identity('billar_id');
drop trigger if exists guard_provider_product_parent on public.provider_products;
create trigger guard_provider_product_parent before update of provider_id on public.provider_products
for each row execute function public.guard_purchase_record_identity('provider_id');

alter table public.purchases enable row level security;
drop policy if exists "business_admin_only" on public.purchases;
drop policy if exists "owner_business_scope" on public.purchases;
drop policy if exists "staff_purchases_permissive" on public.purchases;
create policy "staff_purchases_permissive" on public.purchases
for all to authenticated using (true) with check (true);

drop policy if exists "staff_purchases_select" on public.purchases;
create policy "staff_purchases_select" on public.purchases
as restrictive for select to authenticated using (
    public.has_staff_module_access(billar_id, 'purchases')
    or public.has_staff_module_access(billar_id, 'reports')
);
drop policy if exists "staff_purchases_insert" on public.purchases;
create policy "staff_purchases_insert" on public.purchases
as restrictive for insert to authenticated with check (
    public.has_billar_role(billar_id, array['admin']::text[])
    and (provider_id is null or exists (
        select 1 from public.providers provider
        where provider.id = purchases.provider_id
          and provider.billar_id = purchases.billar_id
    ))
);
drop policy if exists "staff_purchases_update" on public.purchases;
create policy "staff_purchases_update" on public.purchases
as restrictive for update to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]))
with check (
    public.has_billar_role(billar_id, array['admin']::text[])
    and (provider_id is null or exists (
        select 1 from public.providers provider
        where provider.id = purchases.provider_id
          and provider.billar_id = purchases.billar_id
    ))
);
drop policy if exists "staff_purchases_delete" on public.purchases;
create policy "staff_purchases_delete" on public.purchases
as restrictive for delete to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]));

alter table public.purchase_details enable row level security;
drop policy if exists "business_admin_only" on public.purchase_details;
drop policy if exists "owner_business_scope" on public.purchase_details;
drop policy if exists "staff_purchase_details_permissive" on public.purchase_details;
create policy "staff_purchase_details_permissive" on public.purchase_details
for all to authenticated using (true) with check (true);

drop policy if exists "staff_purchase_details_select" on public.purchase_details;
create policy "staff_purchase_details_select" on public.purchase_details
as restrictive for select to authenticated using (
    exists (
        select 1 from public.purchases purchase
        where purchase.id = purchase_details.purchase_id
          and (
              public.has_staff_module_access(purchase.billar_id, 'purchases')
              or public.has_staff_module_access(purchase.billar_id, 'reports')
          )
    )
);
drop policy if exists "staff_purchase_details_insert" on public.purchase_details;
create policy "staff_purchase_details_insert" on public.purchase_details
as restrictive for insert to authenticated with check (
    exists (
        select 1 from public.purchases purchase
        join public.products product
          on product.id = purchase_details.product_id
         and product.billar_id = purchase.billar_id
        where purchase.id = purchase_details.purchase_id
          and public.has_billar_role(purchase.billar_id, array['admin']::text[])
    )
);
drop policy if exists "staff_purchase_details_update" on public.purchase_details;
create policy "staff_purchase_details_update" on public.purchase_details
as restrictive for update to authenticated
using (
    exists (
        select 1 from public.purchases purchase
        where purchase.id = purchase_details.purchase_id
          and public.has_billar_role(purchase.billar_id, array['admin']::text[])
    )
)
with check (
    exists (
        select 1 from public.purchases purchase
        join public.products product
          on product.id = purchase_details.product_id
         and product.billar_id = purchase.billar_id
        where purchase.id = purchase_details.purchase_id
          and public.has_billar_role(purchase.billar_id, array['admin']::text[])
    )
);
drop policy if exists "staff_purchase_details_delete" on public.purchase_details;
create policy "staff_purchase_details_delete" on public.purchase_details
as restrictive for delete to authenticated using (
    exists (
        select 1 from public.purchases purchase
        where purchase.id = purchase_details.purchase_id
          and public.has_billar_role(purchase.billar_id, array['admin']::text[])
    )
);

alter table public.providers enable row level security;
drop policy if exists "business_admin_only" on public.providers;
drop policy if exists "owner_business_scope" on public.providers;
drop policy if exists "staff_providers_permissive" on public.providers;
create policy "staff_providers_permissive" on public.providers
for all to authenticated using (true) with check (true);

drop policy if exists "staff_providers_select" on public.providers;
create policy "staff_providers_select" on public.providers
as restrictive for select to authenticated using (
    public.has_staff_module_access(billar_id, 'purchases')
    or public.has_staff_module_access(billar_id, 'reports')
);
drop policy if exists "staff_providers_insert" on public.providers;
create policy "staff_providers_insert" on public.providers
as restrictive for insert to authenticated
with check (public.has_billar_role(billar_id, array['admin']::text[]));
drop policy if exists "staff_providers_update" on public.providers;
create policy "staff_providers_update" on public.providers
as restrictive for update to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]))
with check (public.has_billar_role(billar_id, array['admin']::text[]));
drop policy if exists "staff_providers_delete" on public.providers;
create policy "staff_providers_delete" on public.providers
as restrictive for delete to authenticated
using (public.has_billar_role(billar_id, array['admin']::text[]));

alter table public.provider_products enable row level security;
drop policy if exists "business_admin_only" on public.provider_products;
drop policy if exists "owner_business_scope" on public.provider_products;
drop policy if exists "staff_provider_products_permissive" on public.provider_products;
create policy "staff_provider_products_permissive" on public.provider_products
for all to authenticated using (true) with check (true);

drop policy if exists "staff_provider_products_select" on public.provider_products;
create policy "staff_provider_products_select" on public.provider_products
as restrictive for select to authenticated using (
    exists (
        select 1 from public.providers provider
        where provider.id = provider_products.provider_id
          and (
              public.has_staff_module_access(provider.billar_id, 'purchases')
              or public.has_staff_module_access(provider.billar_id, 'reports')
          )
    )
);
drop policy if exists "staff_provider_products_insert" on public.provider_products;
create policy "staff_provider_products_insert" on public.provider_products
as restrictive for insert to authenticated with check (
    exists (
        select 1 from public.providers provider
        join public.products product
          on product.id = provider_products.product_id
         and product.billar_id = provider.billar_id
        where provider.id = provider_products.provider_id
          and public.has_billar_role(provider.billar_id, array['admin']::text[])
    )
);
drop policy if exists "staff_provider_products_update" on public.provider_products;
create policy "staff_provider_products_update" on public.provider_products
as restrictive for update to authenticated
using (
    exists (
        select 1 from public.providers provider
        where provider.id = provider_products.provider_id
          and public.has_billar_role(provider.billar_id, array['admin']::text[])
    )
)
with check (
    exists (
        select 1 from public.providers provider
        join public.products product
          on product.id = provider_products.product_id
         and product.billar_id = provider.billar_id
        where provider.id = provider_products.provider_id
          and public.has_billar_role(provider.billar_id, array['admin']::text[])
    )
);
drop policy if exists "staff_provider_products_delete" on public.provider_products;
create policy "staff_provider_products_delete" on public.provider_products
as restrictive for delete to authenticated using (
    exists (
        select 1 from public.providers provider
        where provider.id = provider_products.provider_id
          and public.has_billar_role(provider.billar_id, array['admin']::text[])
    )
);

commit;
