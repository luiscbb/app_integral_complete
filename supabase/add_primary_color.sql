-- ============================================================
-- MIGRACION: Agregar primary_color a billar_settings
-- ============================================================

-- El valor 0xFFE53935 = 4294967295 es mayor que INTEGER max (2147483647)
-- Usamos un valor valido: rojo = 15040515 (0xFFE53935 sin alpha) o directo 16777215

ALTER TABLE public.billar_settings 
ADD COLUMN IF NOT EXISTS primary_color integer DEFAULT 15040515;

-- Verificar
SELECT column_name, data_type, column_default 
FROM information_schema.columns 
WHERE table_name = 'billar_settings' AND column_name = 'primary_color';
