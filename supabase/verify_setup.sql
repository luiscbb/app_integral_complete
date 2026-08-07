-- ============================================================
-- VERIFICACIÓN GENERAL DE SUPABASE - Baumar POS
-- Ejecutar este script en Supabase SQL Editor
-- ============================================================

-- 1. Listar tablas públicas
select table_name 
from information_schema.tables 
where table_schema = 'public' 
order by table_name;

-- 2. Ver estructura de providers
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'providers'
order by ordinal_position;

-- 3. Ver estructura de provider_products
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'provider_products'
order by ordinal_position;

-- 4. Ver estructura de billiard_tables
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'billiard_tables'
order by ordinal_position;

-- 5. Ver políticas RLS activas
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
order by tablename, policyname;

-- 6. Ver triggers de updated_at
select trigger_name, event_object_table, action_statement
from information_schema.triggers
where trigger_schema = 'public'
order by event_object_table;

-- 7. Ver secuencias
select sequencename, start_value
from pg_sequences
where schemaname = 'public';

-- 8. Ver índices de las tablas clave
select tablename, indexname
from pg_indexes
where schemaname = 'public'
and tablename in ('providers', 'provider_products', 'billiard_tables', 'billar_settings', 'sales_history', 'purchases')
order by tablename, indexname;

-- 9. Contar registros en tablas clave
select 'providers' as tabla, count(*) as registros from public.providers
union all
select 'provider_products', count(*) from public.provider_products
union all
select 'billiard_tables', count(*) from public.billiard_tables
union all
select 'billar_settings', count(*) from public.billar_settings
union all
select 'products', count(*) from public.products;

-- 10. Verificar que RLS esté activado en tablas clave
select relname as tabla, relrowsecurity as rls_activo
from pg_class
where relname in ('providers', 'provider_products', 'billiard_tables', 'billar_settings', 'products', 'sales_history', 'purchases')
order by relname;
