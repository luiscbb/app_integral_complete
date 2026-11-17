-- Solo lectura. Devuelve conteos y dependencias, sin datos personales.
-- Requiere exactamente una configuracion en el proyecto.
with target as (
  select min(billar_id) as billar_id
  from public.billar_settings
  having count(*) = 1
),
counts as (
  select item.name, item.total
  from target b
  cross join lateral (values
    ('billiard_tables', (select count(*) from public.billiard_tables t where t.billar_id = b.billar_id)),
    ('cash_outflow_concepts', (select count(*) from public.cash_outflow_concepts t where t.billar_id = b.billar_id)),
    ('cash_outflows', (select count(*) from public.cash_outflows t where t.billar_id = b.billar_id)),
    ('cashier_sessions', (select count(*) from public.cashier_sessions t where t.billar_id = b.billar_id)),
    ('categories', (select count(*) from public.categories t where t.billar_id = b.billar_id)),
    ('inventory_movements', (select count(*) from public.inventory_movements t where t.billar_id = b.billar_id)),
    ('match_results', (select count(*) from public.match_results t where t.billar_id = b.billar_id)),
    ('pending_sales', (select count(*) from public.pending_sales t where t.billar_id = b.billar_id)),
    ('products', (select count(*) from public.products t where t.billar_id = b.billar_id)),
    ('providers', (select count(*) from public.providers t where t.billar_id = b.billar_id)),
    ('purchases', (select count(*) from public.purchases t where t.billar_id = b.billar_id)),
    ('sales_history', (select count(*) from public.sales_history t where t.billar_id = b.billar_id)),
    ('billar_tournaments', (select count(*) from public.billar_tournaments t where t.billar_id = b.billar_id)),
    ('personal_clients', (select count(*) from public.personal_clients t where t.billar_id = b.billar_id)),
    ('personal_customer_accounts', (select count(*) from public.personal_customer_accounts t where t.billar_id = b.billar_id)),
    ('players', (select count(*) from public.players t where t.billar_id = b.billar_id)),
    ('sale_details', (select count(*) from public.sale_details d join public.sales_history s on s.id = d.sale_id where s.billar_id = b.billar_id)),
    ('purchase_details', (select count(*) from public.purchase_details d join public.purchases p on p.id = d.purchase_id where p.billar_id = b.billar_id)),
    ('sale_details_producto_ajeno_o_ausente', (select count(*) from public.sale_details d join public.sales_history s on s.id = d.sale_id where s.billar_id = b.billar_id and d.product_id is not null and not exists (select 1 from public.products p where p.id = d.product_id and p.billar_id = b.billar_id))),
    ('purchase_details_producto_ajeno_o_ausente', (select count(*) from public.purchase_details d join public.purchases p on p.id = d.purchase_id where p.billar_id = b.billar_id and not exists (select 1 from public.products t where t.id = d.product_id and t.billar_id = b.billar_id))),
    ('promo_items_relacionados', (select count(*) from public.promo_items d where exists (select 1 from public.products p where p.billar_id = b.billar_id and p.id in (d.parent_id, d.child_id)))),
    ('provider_products_relacionados', (select count(*) from public.provider_products d where exists (select 1 from public.providers p where p.billar_id = b.billar_id and p.id = d.provider_id) or exists (select 1 from public.products p where p.billar_id = b.billar_id and p.id = d.product_id))),
    ('promo_items_fuera_de_ambito', (select count(*) from public.promo_items d where exists (select 1 from public.products p where p.billar_id = b.billar_id and p.id in (d.parent_id, d.child_id)) and (not exists (select 1 from public.products p where p.id = d.parent_id and p.billar_id = b.billar_id) or not exists (select 1 from public.products p where p.id = d.child_id and p.billar_id = b.billar_id)))),
    ('provider_products_fuera_de_ambito', (select count(*) from public.provider_products d where (exists (select 1 from public.providers p where p.billar_id = b.billar_id and p.id = d.provider_id) or exists (select 1 from public.products p where p.billar_id = b.billar_id and p.id = d.product_id)) and (not exists (select 1 from public.providers p where p.id = d.provider_id and p.billar_id = b.billar_id) or not exists (select 1 from public.products p where p.id = d.product_id and p.billar_id = b.billar_id)))),
    ('owner_transaction_sync_requests', (select count(*) from public.owner_transaction_sync_requests t where t.billar_id = b.billar_id)),
    ('provider_archive_requests', (select count(*) from public.provider_archive_requests t where t.billar_id = b.billar_id)),
    ('product_stock_reconciliation_audit', (select count(*) from public.product_stock_reconciliation_audit t where t.billar_id = b.billar_id))
  ) item(name, total)
),
dependencies as (
  select source_ns.nspname as esquema_origen, source.relname as tabla_origen,
         target_table.relname as tabla_destino,
         c.conname as nombre, pg_get_constraintdef(c.oid) as definicion
  from pg_constraint c
  join pg_class source on source.oid = c.conrelid
  join pg_namespace source_ns on source_ns.oid = source.relnamespace
  join pg_class target_table on target_table.oid = c.confrelid
  join pg_namespace target_ns on target_ns.oid = target_table.relnamespace
  where c.contype = 'f' and target_ns.nspname = 'public'
    and target_table.relname in (
      'billiard_tables', 'cash_outflow_concepts', 'cash_outflows',
      'cashier_sessions', 'categories', 'inventory_movements', 'match_results',
      'pending_sales', 'products', 'providers', 'purchases', 'sales_history',
      'billar_tournaments', 'personal_clients', 'personal_customer_accounts',
      'players', 'sale_details', 'purchase_details', 'promo_items', 'provider_products'
    )
)
select jsonb_build_object(
  'configuraciones', (select count(*) from public.billar_settings),
  'billar_unico', exists (select 1 from target),
  'conteos', (select coalesce(jsonb_object_agg(name, total), '{}'::jsonb) from counts),
  'dependencias', (select coalesce(jsonb_agg(to_jsonb(d) order by tabla_origen, nombre), '[]'::jsonb) from dependencies d)
) as diagnostico;
