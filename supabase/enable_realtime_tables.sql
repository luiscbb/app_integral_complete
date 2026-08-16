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

-- 3. Confirmar que las tablas estan habilitadas
select schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
order by tablename;
