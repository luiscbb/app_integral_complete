-- ============================================================
-- Fix: la tabla categories tenia UNIQUE global en "name",
-- lo que impide que dos negocios (billar_id distinto) tengan
-- una categoria con el mismo nombre (ej. "BEBIDAS").
-- Ejecutar en Supabase -> SQL Editor
-- ============================================================

ALTER TABLE public.categories
  DROP CONSTRAINT IF EXISTS categories_name_unique;

ALTER TABLE public.categories
  ADD CONSTRAINT categories_billar_name_unique UNIQUE (billar_id, name);
