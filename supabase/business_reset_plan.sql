-- PELIGRO: elimina los datos operativos indicados en el plan de pruebas.
-- Preparacion solamente: NO ejecutar sin autorizacion explicita.
-- Conserva Auth, membresias, configuracion, registro de identidad, Storage,
-- solicitudes idempotentes y auditorias. Verifica los conteos informados.
begin;

lock table public.billar_settings, public.business_identity_registry,
  public.billiard_tables, public.cash_outflow_concepts, public.cash_outflows,
  public.cashier_sessions, public.categories, public.inventory_movements,
  public.match_results, public.pending_sales, public.products, public.providers,
  public.purchases, public.sales_history, public.billar_tournaments,
  public.personal_clients, public.personal_customer_accounts, public.players,
  public.sale_details, public.purchase_details, public.promo_items,
  public.provider_products, public.owner_transaction_sync_requests,
  public.provider_archive_requests, public.product_stock_reconciliation_audit
in share row exclusive mode;

do $$
declare
  target text;
  item record;
  actual bigint;
  outside_scope boolean;
begin
  if (select count(*) from public.billar_settings) <> 1 then
    raise exception 'Se requiere una sola configuracion de billar.';
  end if;
  select billar_id into strict target from public.billar_settings;
  if target is null or btrim(target) = '' or not exists (
    select 1 from public.billar_settings s
    join public.business_identity_registry r
      on r.billar_id = s.billar_id and r.owner_user_id = s.user_id
    where s.billar_id = target
  ) then
    raise exception 'No se pudo verificar la identidad del billar.';
  end if;

  for item in select * from (values
    ('billiard_tables', 11), ('cash_outflow_concepts', 3), ('cash_outflows', 5),
    ('cashier_sessions', 0), ('categories', 2), ('inventory_movements', 52),
    ('match_results', 0), ('pending_sales', 0), ('products', 4), ('providers', 2),
    ('purchases', 4), ('sales_history', 34), ('billar_tournaments', 7),
    ('personal_clients', 1), ('personal_customer_accounts', 3), ('players', 3),
    ('owner_transaction_sync_requests', 0), ('provider_archive_requests', 0),
    ('product_stock_reconciliation_audit', 0)
  ) expected(name, total) loop
    execute format('select count(*) from public.%I where billar_id = $1', item.name)
      into actual using target;
    if actual <> item.total then
      raise exception 'Los registros de % cambiaron; revisar el plan.', item.name;
    end if;
    execute format('select exists (select 1 from public.%I where billar_id is distinct from $1)', item.name)
      into outside_scope using target;
    if outside_scope then
      raise exception 'Hay registros fuera del billar en %; revisar el plan.', item.name;
    end if;
  end loop;

  if (select count(*) from public.sale_details) <> 57
     or (select count(*) from public.sale_details d
         join public.sales_history s on s.id = d.sale_id
         where s.billar_id = target) <> 57
     or (select count(*) from public.purchase_details) <> 4
     or (select count(*) from public.purchase_details d
         join public.purchases p on p.id = d.purchase_id
         where p.billar_id = target) <> 4
     or (select count(*) from public.promo_items) <> 2
     or (select count(*) from public.promo_items d
         join public.products p on p.id = d.parent_id and p.billar_id = target
         join public.products c on c.id = d.child_id and c.billar_id = target) <> 2
     or (select count(*) from public.provider_products) <> 0 then
    raise exception 'Los detalles o relaciones cambiaron; revisar el plan.';
  end if;

  delete from public.sale_details d using public.sales_history s
    where d.sale_id = s.id and s.billar_id = target;
  delete from public.purchase_details d using public.purchases p
    where d.purchase_id = p.id and p.billar_id = target;
  delete from public.promo_items d using public.products p
    where d.parent_id = p.id and p.billar_id = target;
  delete from public.inventory_movements where billar_id = target;
  delete from public.match_results where billar_id = target;
  delete from public.billar_tournaments where billar_id = target;
  delete from public.pending_sales where billar_id = target;
  delete from public.personal_customer_accounts where billar_id = target;
  delete from public.personal_clients where billar_id = target;
  delete from public.sales_history where billar_id = target;
  delete from public.purchases where billar_id = target;
  delete from public.providers where billar_id = target;
  delete from public.products where billar_id = target;
  delete from public.players where billar_id = target;
  delete from public.billiard_tables where billar_id = target;
  delete from public.cash_outflows where billar_id = target;
  delete from public.cash_outflow_concepts where billar_id = target;
  delete from public.cashier_sessions where billar_id = target;
  delete from public.categories where billar_id = target;
end;
$$;

commit;
