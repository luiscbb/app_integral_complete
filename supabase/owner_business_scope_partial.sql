-- Preparation only: this does not protect all tables, storage or account
-- creation. Do not deploy independently. Requires the business identity guard.
begin;

do $$
begin
  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and (
        (tablename = 'products' and policyname = 'staff_products_select')
        or (tablename = 'sales_history' and policyname = 'staff_sales_select')
        or (tablename = 'sale_details' and policyname = 'staff_sale_details_select')
        or (tablename = 'purchases' and policyname = 'staff_purchases_select')
        or (tablename = 'purchase_details' and policyname = 'staff_purchase_details_select')
        or (tablename = 'providers' and policyname = 'staff_providers_select')
        or (tablename = 'provider_products' and policyname = 'staff_provider_products_select')
      )
  ) then
    raise exception 'Las políticas de personal ya están instaladas; no aplicar este borrador después de ellas.'
      using errcode = '55000';
  end if;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'billar_settings', 'business_memberships', 'billiard_tables', 'cash_outflow_concepts', 'cash_outflows',
    'cashier_sessions', 'categories', 'inventory_movements', 'match_results',
    'pending_sales', 'products', 'providers', 'purchases', 'sales_history',
    'billar_tournaments', 'personal_clients', 'personal_customer_accounts',
    'players', 'sale_details', 'purchase_details', 'promo_items', 'provider_products'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format('drop policy if exists owner_no_anon on public.%I', table_name);
    execute format(
      'create policy owner_no_anon on public.%I as restrictive for all to anon '
      'using (false) with check (false)', table_name
    );
  end loop;
end;
$$;

drop policy if exists owner_membership_select on public.business_memberships;
create policy owner_membership_select on public.business_memberships
as restrictive for select to authenticated using (
  user_id = auth.uid()
  or public.has_billar_role(billar_id, array['admin']::text[])
);
drop policy if exists owner_membership_no_insert on public.business_memberships;
create policy owner_membership_no_insert on public.business_memberships
as restrictive for insert to authenticated with check (false);
drop policy if exists owner_membership_no_update on public.business_memberships;
create policy owner_membership_no_update on public.business_memberships
as restrictive for update to authenticated using (false) with check (false);
drop policy if exists owner_membership_no_delete on public.business_memberships;
create policy owner_membership_no_delete on public.business_memberships
as restrictive for delete to authenticated using (false);

-- A newly registered owner needs to create their own settings before their
-- administrator membership exists. The identity guard must be installed first
-- to prevent claiming another business identifier.
drop policy if exists business_admin_only on public.billar_settings;
drop policy if exists business_scope_select on public.billar_settings;
create policy business_scope_select on public.billar_settings as restrictive
for select to authenticated using (
  user_id = auth.uid()
  or public.has_billar_role(billar_id, array['admin', 'manager']::text[])
);
drop policy if exists business_scope_insert on public.billar_settings;
create policy business_scope_insert on public.billar_settings as restrictive
for insert to authenticated with check (user_id = auth.uid());
drop policy if exists business_scope_update on public.billar_settings;
create policy business_scope_update on public.billar_settings as restrictive
for update to authenticated using (user_id = auth.uid())
with check (user_id = auth.uid());
drop policy if exists business_scope_delete on public.billar_settings;
create policy business_scope_delete on public.billar_settings as restrictive
for delete to authenticated using (user_id = auth.uid());

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'billiard_tables', 'cash_outflow_concepts', 'cash_outflows', 'cashier_sessions', 'categories',
    'inventory_movements', 'match_results', 'pending_sales', 'products',
    'providers', 'purchases', 'sales_history'
  ] loop
    execute format(
      'drop policy if exists owner_business_scope on public.%I', table_name
    );
    execute format(
      'create policy owner_business_scope on public.%I as restrictive for all to authenticated '
      'using (public.has_billar_role(billar_id, array[''admin'']::text[])) '
      'with check (public.has_billar_role(billar_id, array[''admin'']::text[]))',
      table_name
    );
  end loop;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'billar_tournaments', 'personal_clients', 'personal_customer_accounts'
  ] loop
    execute format(
      'drop policy if exists business_scope on public.%I', table_name
    );
    execute format(
      'create policy business_scope on public.%I as restrictive for all to authenticated '
      'using (public.has_billar_role(billar_id, array[''admin'', ''manager'']::text[])) '
      'with check (public.has_billar_role(billar_id, array[''admin'', ''manager'']::text[]))',
      table_name
    );
  end loop;
end;
$$;

drop policy if exists business_scope_select on public.players;
create policy business_scope_select on public.players as restrictive for select
to authenticated using (
  auth_user_id = auth.uid()
  or public.has_billar_role(billar_id, array['admin', 'manager']::text[])
);
drop policy if exists business_scope_insert on public.players;
create policy business_scope_insert on public.players as restrictive for insert
to authenticated with check (
  public.has_billar_role(billar_id, array['admin', 'manager']::text[])
);
drop policy if exists business_scope_update on public.players;
create policy business_scope_update on public.players as restrictive for update
to authenticated
using (public.has_billar_role(billar_id, array['admin', 'manager']::text[]))
with check (public.has_billar_role(billar_id, array['admin', 'manager']::text[]));
drop policy if exists business_scope_delete on public.players;
create policy business_scope_delete on public.players as restrictive for delete
to authenticated using (
  public.has_billar_role(billar_id, array['admin', 'manager']::text[])
);

drop policy if exists owner_business_scope on public.sale_details;
create policy owner_business_scope on public.sale_details
as restrictive for all to authenticated
using (exists (
  select 1 from public.sales_history s
  where s.id = sale_details.sale_id
    and public.has_billar_role(s.billar_id, array['admin']::text[])
))
with check (exists (
  select 1 from public.sales_history s
  where s.id = sale_details.sale_id
    and public.has_billar_role(s.billar_id, array['admin']::text[])
    and (sale_details.product_id is null or exists (
      select 1 from public.products product
      where product.id = sale_details.product_id and product.billar_id = s.billar_id
    ))
));

drop policy if exists owner_business_scope on public.purchase_details;
create policy owner_business_scope on public.purchase_details
as restrictive for all to authenticated
using (exists (
  select 1 from public.purchases p
  where p.id = purchase_details.purchase_id
    and public.has_billar_role(p.billar_id, array['admin']::text[])
))
with check (exists (
  select 1 from public.purchases p
  where p.id = purchase_details.purchase_id
    and public.has_billar_role(p.billar_id, array['admin']::text[])
    and exists (
      select 1 from public.products product
      where product.id = purchase_details.product_id and product.billar_id = p.billar_id
    )
));

drop policy if exists owner_business_scope on public.promo_items;
create policy owner_business_scope on public.promo_items
as restrictive for all to authenticated
using (exists (
  select 1 from public.products parent
  where parent.id = promo_items.parent_id
    and public.has_billar_role(parent.billar_id, array['admin']::text[])
))
with check (exists (
  select 1 from public.products parent
  join public.products child on child.id = promo_items.child_id
    and child.billar_id = parent.billar_id
  where parent.id = promo_items.parent_id
    and public.has_billar_role(parent.billar_id, array['admin']::text[])
));

drop policy if exists owner_business_scope on public.provider_products;
create policy owner_business_scope on public.provider_products
as restrictive for all to authenticated
using (exists (
  select 1 from public.providers provider
  where provider.id = provider_products.provider_id
    and public.has_billar_role(provider.billar_id, array['admin']::text[])
))
with check (exists (
  select 1 from public.providers provider
  join public.products product on product.id = provider_products.product_id
    and product.billar_id = provider.billar_id
  where provider.id = provider_products.provider_id
    and public.has_billar_role(provider.billar_id, array['admin']::text[])
));

commit;
