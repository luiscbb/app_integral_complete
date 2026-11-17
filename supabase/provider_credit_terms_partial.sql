-- Preparation only. Apply before clients start synchronizing these fields.
-- Existing providers remain unknown (NULL); no historical payments are inferred.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

alter table public.providers
    add column if not exists credit_days integer,
    add column if not exists preferred_payment_method text;

do $$
begin
    if not exists (select 1 from pg_constraint
        where conrelid = 'public.providers'::regclass
          and conname = 'providers_credit_days_valid') then
        alter table public.providers add constraint providers_credit_days_valid
            check (credit_days >= 0);
    end if;
    if not exists (select 1 from pg_constraint
        where conrelid = 'public.providers'::regclass
          and conname = 'providers_preferred_payment_method_valid') then
        alter table public.providers add constraint providers_preferred_payment_method_valid
            check (preferred_payment_method in ('efectivo', 'tarjeta', 'transferencia', 'credito'));
    end if;
end;
$$;
commit;
