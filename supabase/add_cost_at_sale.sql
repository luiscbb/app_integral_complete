-- ============================================================
-- Migración: Informe de UTILIDAD (Etapa 4)
-- Ejecutar en Supabase → SQL Editor
-- ============================================================

-- Costo unitario del producto al momento de vender, guardado junto al
-- detalle de la venta. Permite calcular el "costo de lo vendido" con el
-- costo histórico real (aunque el costo del producto cambie después).
ALTER TABLE public.sale_details
ADD COLUMN IF NOT EXISTS cost_at_sale numeric NOT NULL DEFAULT 0;