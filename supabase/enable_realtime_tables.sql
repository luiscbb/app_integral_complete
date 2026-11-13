-- ============================================================
-- HABILITAR REALTIME EN TABLAS (sincronizacion en tiempo real)
-- ============================================================
-- Ejecutar esto en Supabase SQL Editor
-- ============================================================
-- Permite que dos dispositivos (celular <-> exe) vean en tiempo
-- real los cambios en las mesas de billar sin duplicar informacion.

-- 1. Agregar billiard_tables a la publicacion de Realtime (idempotente)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'billiard_tables'
  ) then
    alter publication supabase_realtime add table public.billiard_tables;
  end if;
end $$;

-- 2. Garantizar que billar_settings tambien este en Realtime (por si falta)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'billar_settings'
  ) then
    alter publication supabase_realtime add table public.billar_settings;
  end if;
end $$;

-- 2b. Habilitar Realtime en proveedores (sync celular <-> exe)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'providers'
  ) then
    alter publication supabase_realtime add table public.providers;
  end if;
end $$;

-- 2c. Habilitar Realtime en compras (sync celular <-> exe)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'purchases'
  ) then
    alter publication supabase_realtime add table public.purchases;
  end if;
end $$;

-- 2d. Habilitar Realtime de productos/inventario.
-- FULL replica identity incluye billar_id en eventos DELETE para poder
-- filtrar correctamente los cambios entre negocios en el cliente.
alter table public.products replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'products'
  ) then
    alter publication supabase_realtime add table public.products;
  end if;
end $$;

-- 2e. Permitir que clientes autenticados eliminen productos y sus relaciones
-- de promo cuando vacian la cola local de borrados pendientes.
alter table public.products enable row level security;
alter table public.promo_items enable row level security;

do $$
begin
    if not exists (
      select 1 from pg_policies
      where schemaname = 'public'
        and tablename = 'products'
        and policyname = 'products_delete'
    ) then
      execute 'create policy "products_delete" on public.products for delete to authenticated using (true)';
    end if;

    if not exists (
      select 1 from pg_policies
      where schemaname = 'public'
        and tablename = 'promo_items'
        and policyname = 'promo_items_delete'
    ) then
      execute 'create policy "promo_items_delete" on public.promo_items for delete to authenticated using (true)';
    end if;
end $$;

-- 3. Confirmar que las tablas estan habilitadas
select schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
order by tablename;
