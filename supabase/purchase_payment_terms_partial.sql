-- Preparation only. No execution grants or historical payment backfill.
-- Credit creates a balance, not a cash movement. Future payments need their
-- own audited/idempotent operation before they can change these amounts.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

alter table public.purchases
    add column if not exists payment_condition text,
    add column if not exists payment_method text,
    add column if not exists credit_days integer,
    add column if not exists due_date date,
    add column if not exists paid_amount double precision,
    add column if not exists balance_due double precision;
alter table public.purchases alter column cash_source drop not null;

do $$
begin
    if not exists (select 1 from pg_constraint
        where conrelid = 'public.purchases'::regclass
          and conname = 'purchases_payment_terms_valid') then
        alter table public.purchases add constraint purchases_payment_terms_valid check ((
            (payment_condition is null and payment_method is null and credit_days is null
                and due_date is null and paid_amount is null and balance_due is null)
            or
            (payment_condition in ('contado', 'credito')
                and total >= 0 and total < 'Infinity'::double precision
                and paid_amount >= 0 and paid_amount < 'Infinity'::double precision
                and balance_due >= 0 and balance_due < 'Infinity'::double precision
                and paid_amount <= total and balance_due <= total
                and abs(paid_amount + balance_due - total) <= greatest(0.000001, abs(total) * 1e-10)
                and (
                    (payment_condition = 'contado' and credit_days is null and due_date is null
                        and balance_due = 0 and paid_amount = total
                        and ((payment_method = 'efectivo' and cash_source in ('caja', 'cajero'))
                            or (payment_method in ('tarjeta', 'transferencia') and cash_source = payment_method)))
                    or (payment_condition = 'credito' and provider_id is not null
                        and credit_days >= 0 and due_date is not null
                        and payment_method is null and cash_source is null)
                ))
        ) is true);
    end if;
end;
$$;
commit;
