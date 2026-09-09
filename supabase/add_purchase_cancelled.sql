-- Anulación de compras: columna cancelled en compras y sus detalles.
-- Ejecutar en Supabase (SQL Editor) una sola vez.
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS cancelled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE purchase_details ADD COLUMN IF NOT EXISTS cancelled BOOLEAN NOT NULL DEFAULT FALSE;
