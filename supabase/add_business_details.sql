-- ============================================================
-- MIGRACION: Agregar datos extendidos del negocio a billar_settings
-- ============================================================

ALTER TABLE public.billar_settings
ADD COLUMN IF NOT EXISTS business_address TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_street TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_ext_number TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_int_number TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_colony TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_zip_code TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_city TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_state TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_phone TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_whatsapp TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_slogan TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS business_website TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS ticket_farewell TEXT DEFAULT 'GRACIAS POR SU COMPRA',
ADD COLUMN IF NOT EXISTS ticket_counter INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS social_networks TEXT DEFAULT '{}';

-- Verificar
SELECT column_name, data_type
FROM information_schema.columns
WHERE
    table_name = 'billar_settings'
    AND column_name IN (
        'business_address',
        'business_street',
        'business_ext_number',
        'business_int_number',
        'business_colony',
        'business_zip_code',
        'business_city',
        'business_state',
        'business_phone',
        'business_whatsapp',
        'business_slogan',
        'business_website',
        'ticket_farewell',
        'ticket_counter',
        'social_networks'
    );