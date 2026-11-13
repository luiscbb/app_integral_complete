-- Stable client-generated ID prevents duplicate quick sales when a retry
-- follows a lost/failed network response.
ALTER TABLE public.pending_sales
ADD COLUMN IF NOT EXISTS client_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS pending_sales_client_id_key
ON public.pending_sales (client_id);
