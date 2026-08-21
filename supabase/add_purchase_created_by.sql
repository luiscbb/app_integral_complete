-- ============================================================
-- SUPABASE: Agregar columna created_by (usuario logueado) a compras
-- Ejecutar este script en Supabase SQL Editor.
-- Permite guardar y sincronizar qué usuario realizó cada compra,
-- útil para el detalle del historial y futuros cortes por turno/cajero.
-- ============================================================

-- 1. purchases
alter table public.purchases
    add column if not exists created_by text default '';

-- 2. purchase_details (por si se quiere guardar por línea también)
alter table public.purchase_details
    add column if not exists created_by text default '';

-- ============================================================
-- Nota: no hace falta política RLS nueva (ya hay `using (true)` en
-- purchases/purchase_details). Tampoco hace falta publicación Realtime
-- nueva (las tablas ya están en supabase_realtime).
-- ============================================================
