-- ============================================================
-- HABILITAR RLS EN TODAS LAS TABLAS (corrige "UNRESTRICTED")
-- ============================================================
-- Ejecutar esto en Supabase SQL Editor
-- ============================================================

-- 1. Habilitar RLS en todas las tablas existentes
alter table public.players enable row level security;
alter table public.match_results enable row level security;
alter table public.products enable row level security;
alter table public.promo_items enable row level security;
alter table public.sales_history enable row level security;
alter table public.sale_details enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_details enable row level security;
alter table public.providers enable row level security;
alter table public.pending_sales enable row level security;
alter table public.billar_settings enable row level security;

-- ============================================================
-- 2. POLITICAS: drop if exists + create
-- ============================================================

-- players
drop policy if exists "players_select" on public.players;
drop policy if exists "players_insert" on public.players;
drop policy if exists "players_update" on public.players;
drop policy if exists "players_delete" on public.players;
create policy "players_select" on public.players for select to authenticated using (true);
create policy "players_insert" on public.players for insert to authenticated with check (true);
create policy "players_update" on public.players for update to authenticated using (true) with check (true);
create policy "players_delete" on public.players for delete to authenticated using (true);

-- match_results
drop policy if exists "match_select" on public.match_results;
drop policy if exists "match_insert" on public.match_results;
drop policy if exists "match_update" on public.match_results;
drop policy if exists "match_delete" on public.match_results;
create policy "match_select" on public.match_results for select to authenticated using (true);
create policy "match_insert" on public.match_results for insert to authenticated with check (true);
create policy "match_update" on public.match_results for update to authenticated using (true) with check (true);
create policy "match_delete" on public.match_results for delete to authenticated using (true);

-- products
drop policy if exists "products_select" on public.products;
drop policy if exists "products_insert" on public.products;
drop policy if exists "products_update" on public.products;
drop policy if exists "products_delete" on public.products;
create policy "products_select" on public.products for select to authenticated using (true);
create policy "products_insert" on public.products for insert to authenticated with check (true);
create policy "products_update" on public.products for update to authenticated using (true) with check (true);
create policy "products_delete" on public.products for delete to authenticated using (true);

-- promo_items
drop policy if exists "promo_items_select" on public.promo_items;
drop policy if exists "promo_items_insert" on public.promo_items;
drop policy if exists "promo_items_delete" on public.promo_items;
create policy "promo_items_select" on public.promo_items for select to authenticated using (true);
create policy "promo_items_insert" on public.promo_items for insert to authenticated with check (true);
create policy "promo_items_delete" on public.promo_items for delete to authenticated using (true);

-- sales_history
drop policy if exists "sales_select" on public.sales_history;
drop policy if exists "sales_insert" on public.sales_history;
drop policy if exists "sales_update" on public.sales_history;
drop policy if exists "sales_delete" on public.sales_history;
create policy "sales_select" on public.sales_history for select to authenticated using (true);
create policy "sales_insert" on public.sales_history for insert to authenticated with check (true);
create policy "sales_update" on public.sales_history for update to authenticated using (true) with check (true);
create policy "sales_delete" on public.sales_history for delete to authenticated using (true);

-- sale_details
drop policy if exists "sale_details_select" on public.sale_details;
drop policy if exists "sale_details_insert" on public.sale_details;
drop policy if exists "sale_details_delete" on public.sale_details;
create policy "sale_details_select" on public.sale_details for select to authenticated using (true);
create policy "sale_details_insert" on public.sale_details for insert to authenticated with check (true);
create policy "sale_details_delete" on public.sale_details for delete to authenticated using (true);

-- purchases
drop policy if exists "purchases_select" on public.purchases;
drop policy if exists "purchases_insert" on public.purchases;
drop policy if exists "purchases_update" on public.purchases;
drop policy if exists "purchases_delete" on public.purchases;
create policy "purchases_select" on public.purchases for select to authenticated using (true);
create policy "purchases_insert" on public.purchases for insert to authenticated with check (true);
create policy "purchases_update" on public.purchases for update to authenticated using (true) with check (true);
create policy "purchases_delete" on public.purchases for delete to authenticated using (true);

-- purchase_details
drop policy if exists "purchase_details_select" on public.purchase_details;
drop policy if exists "purchase_details_insert" on public.purchase_details;
drop policy if exists "purchase_details_delete" on public.purchase_details;
create policy "purchase_details_select" on public.purchase_details for select to authenticated using (true);
create policy "purchase_details_insert" on public.purchase_details for insert to authenticated with check (true);
create policy "purchase_details_delete" on public.purchase_details for delete to authenticated using (true);

-- providers
drop policy if exists "providers_select" on public.providers;
drop policy if exists "providers_insert" on public.providers;
drop policy if exists "providers_update" on public.providers;
drop policy if exists "providers_delete" on public.providers;
create policy "providers_select" on public.providers for select to authenticated using (true);
create policy "providers_insert" on public.providers for insert to authenticated with check (true);
create policy "providers_update" on public.providers for update to authenticated using (true) with check (true);
create policy "providers_delete" on public.providers for delete to authenticated using (true);

-- pending_sales
drop policy if exists "pending_sales_select" on public.pending_sales;
drop policy if exists "pending_sales_insert" on public.pending_sales;
create policy "pending_sales_select" on public.pending_sales for select to authenticated using (true);
create policy "pending_sales_insert" on public.pending_sales for insert to authenticated with check (true);

-- billar_settings (solo el propietario)
drop policy if exists "billar_settings_select" on public.billar_settings;
drop policy if exists "billar_settings_insert" on public.billar_settings;
drop policy if exists "billar_settings_update" on public.billar_settings;
drop policy if exists "billar_settings_delete" on public.billar_settings;
create policy "billar_settings_select" on public.billar_settings for select to authenticated using (user_id = auth.uid());
create policy "billar_settings_insert" on public.billar_settings for insert to authenticated with check (user_id = auth.uid());
create policy "billar_settings_update" on public.billar_settings for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "billar_settings_delete" on public.billar_settings for delete to authenticated using (user_id = auth.uid());
