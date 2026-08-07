-- ============================================================
-- ACTUALIZAR TIPOS DE MESA: valores permitidos Billar / Comanda
-- Ejecutar en Supabase SQL Editor
-- ============================================================

-- Actualizar mesas existentes con tipos antiguos a 'Billar'
UPDATE public.billiard_tables
SET table_type = 'Billar'
WHERE table_type NOT IN ('Billar', 'Comanda');

-- (Opcional) Si quieres limpiar todas las mesas y empezar desde cero:
-- truncate table public.billiard_tables cascade;
