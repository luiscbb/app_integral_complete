-- ============================================================
-- CREACION DE BUCKETS DE STORAGE EN SUPABASE
-- ============================================================
-- Ejecutar en SQL Editor de Supabase (New Query)

-- 1) Crear buckets (si no existen)
INSERT INTO storage.buckets (id, name, public)
VALUES
  ('product_images', 'product_images', true),
  ('promo_images', 'promo_images', true),
  ('player_avatars', 'player_avatars', true)
ON CONFLICT (id) DO NOTHING;

-- 2) Policies para product_images
DROP POLICY IF EXISTS "product_images_select" ON storage.objects;
CREATE POLICY "product_images_select"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'product_images');

DROP POLICY IF EXISTS "product_images_insert" ON storage.objects;
CREATE POLICY "product_images_insert"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'product_images' AND auth.role() = 'authenticated');

DROP POLICY IF EXISTS "product_images_update" ON storage.objects;
CREATE POLICY "product_images_update"
  ON storage.objects FOR UPDATE
  USING (bucket_id = 'product_images' AND auth.role() = 'authenticated');

DROP POLICY IF EXISTS "product_images_delete" ON storage.objects;
CREATE POLICY "product_images_delete"
  ON storage.objects FOR DELETE
  USING (bucket_id = 'product_images' AND auth.role() = 'authenticated');

-- 3) Policies para promo_images
DROP POLICY IF EXISTS "promo_images_select" ON storage.objects;
CREATE POLICY "promo_images_select"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'promo_images');

DROP POLICY IF EXISTS "promo_images_insert" ON storage.objects;
CREATE POLICY "promo_images_insert"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'promo_images' AND auth.role() = 'authenticated');

DROP POLICY IF EXISTS "promo_images_update" ON storage.objects;
CREATE POLICY "promo_images_update"
  ON storage.objects FOR UPDATE
  USING (bucket_id = 'promo_images' AND auth.role() = 'authenticated');

DROP POLICY IF EXISTS "promo_images_delete" ON storage.objects;
CREATE POLICY "promo_images_delete"
  ON storage.objects FOR DELETE
  USING (bucket_id = 'promo_images' AND auth.role() = 'authenticated');

-- 4) Policies para player_avatars
DROP POLICY IF EXISTS "player_avatars_select" ON storage.objects;
CREATE POLICY "player_avatars_select"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'player_avatars');

DROP POLICY IF EXISTS "player_avatars_insert" ON storage.objects;
CREATE POLICY "player_avatars_insert"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'player_avatars' AND auth.role() = 'authenticated');

DROP POLICY IF EXISTS "player_avatars_update" ON storage.objects;
CREATE POLICY "player_avatars_update"
  ON storage.objects FOR UPDATE
  USING (bucket_id = 'player_avatars' AND auth.role() = 'authenticated');

DROP POLICY IF EXISTS "player_avatars_delete" ON storage.objects;
CREATE POLICY "player_avatars_delete"
  ON storage.objects FOR DELETE
  USING (bucket_id = 'player_avatars' AND auth.role() = 'authenticated');

-- Verificar buckets creados
SELECT id, name, public FROM storage.buckets WHERE id IN ('product_images', 'promo_images', 'player_avatars');
