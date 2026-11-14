ALTER TABLE public.billar_settings
  ADD COLUMN IF NOT EXISTS allow_negative_stock_sales boolean NOT NULL DEFAULT false;

ALTER TABLE public.sales_history
  ADD COLUMN IF NOT EXISTS customer_key text;

ALTER TABLE public.billar_tournaments
  ADD COLUMN IF NOT EXISTS is_cancelled boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.personal_clients (
  billar_id text NOT NULL,
  client_id text NOT NULL,
  name text NOT NULL,
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  notes text NOT NULL DEFAULT '',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (billar_id, client_id)
);

CREATE TABLE IF NOT EXISTS public.personal_customer_accounts (
  billar_id text NOT NULL,
  client_key text NOT NULL,
  client_name text NOT NULL,
  items jsonb NOT NULL DEFAULT '[]'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (billar_id, client_key)
);

ALTER TABLE public.personal_clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personal_customer_accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "personal_clients_business_members" ON public.personal_clients;
CREATE POLICY "personal_clients_business_members"
ON public.personal_clients
FOR ALL
TO authenticated
USING (public.has_billar_role(billar_id, ARRAY['admin', 'manager']::text[]))
WITH CHECK (public.has_billar_role(billar_id, ARRAY['admin', 'manager']::text[]));

DROP POLICY IF EXISTS "personal_customer_accounts_business_members"
ON public.personal_customer_accounts;
CREATE POLICY "personal_customer_accounts_business_members"
ON public.personal_customer_accounts
FOR ALL
TO authenticated
USING (public.has_billar_role(billar_id, ARRAY['admin', 'manager']::text[]))
WITH CHECK (public.has_billar_role(billar_id, ARRAY['admin', 'manager']::text[]));

CREATE INDEX IF NOT EXISTS idx_personal_clients_business
  ON public.personal_clients (billar_id, is_active, name);

CREATE INDEX IF NOT EXISTS idx_personal_customer_accounts_business
  ON public.personal_customer_accounts (billar_id, updated_at DESC);
