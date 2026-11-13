-- Existing installs constrain outflow_type to a fixed list, but the app stores
-- the user's selected cash-outflow concept (which may be custom).
alter table public.cash_outflows
    drop constraint if exists cash_outflows_outflow_type_check;
