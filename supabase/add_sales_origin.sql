-- Preparation for module-specific sale permissions. Apply before deploying
-- an app version that sends source_module. Existing sales remain unclassified.
begin;

alter table public.sales_history
    add column if not exists source_module text;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.sales_history'::regclass
          and conname = 'sales_history_source_module_valid'
    ) then
        alter table public.sales_history
            add constraint sales_history_source_module_valid
            check (
                source_module is null
                or source_module in (
                    'quick_sale', 'billiard_tables', 'dine_in', 'personal_account'
                )
            );
    end if;
end;
$$;

commit;
