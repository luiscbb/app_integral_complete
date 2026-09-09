-- ============================================================
-- Migración: anulación lógica de ventas (Etapa 3)
-- Ejecutar en Supabase → SQL Editor
-- ============================================================

-- Marca de anulación (1 = venta anulada). Anulación lógica: la fila NO se
-- borra, así el pull entre dispositivos no vuelve a insertar la venta.
ALTER TABLE public.sales_history
  ADD COLUMN IF NOT EXISTS cancelled boolean NOT NULL DEFAULT false;

-- Detalle de la venta anulado junto con la venta.
ALTER TABLE public.sale_details
  ADD COLUMN IF NOT EXISTS cancelled boolean NOT NULL DEFAULT false;

-- ============================================================
-- Realtime: propagar UPDATE de sales_history (cancel/clear) al otro
-- dispositivo. (INSERT ya estaba habilitado por la publicación existente;
-- esto asegura que el evento UPDATE se emita con la nueva fila completa.)
-- ============================================================
ALTER TABLE public.sales_history REPLICA IDENTITY FULL;
