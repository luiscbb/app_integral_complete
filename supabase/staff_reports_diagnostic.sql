-- Solo metadatos: no devuelve cuentas, movimientos ni importes.
select jsonb_build_object(
    'report_installed', to_regprocedure('public.staff_read_report(text,text,timestamptz,timestamptz,bigint)') is not null,
    'cash_installed', to_regprocedure('public.cash_shared_apply(text,uuid,text,jsonb)') is not null,
    'source_columns', (select jsonb_agg(jsonb_build_object(
        'table', table_name, 'column', column_name, 'type', data_type) order by table_name,column_name)
        from information_schema.columns where table_schema = 'public' and (
            (table_name = 'sales_history' and column_name in ('date','total','paid','payment_method','cancelled'))
            or (table_name = 'purchases' and column_name in ('date','total','paid_amount','cash_source','payment_method','payment_condition','cancelled'))
            or (table_name = 'sale_details' and column_name in ('sale_id','quantity','cost_at_sale','cost_available','cancelled'))
            or (table_name = 'inventory_movements' and column_name in ('created_at','quantity','product_id','movement_type'))
        )),
    'cash_unique_open', exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'cash_shared_one_open'),
    'new_tables_protected', (select count(*) = 3 from pg_class where oid in (
        to_regclass('public.cash_shared_sessions'),to_regclass('public.cash_shared_movements'),to_regclass('public.cash_shared_requests'))
        and relrowsecurity and not has_table_privilege('authenticated',oid,'INSERT')
        and not has_table_privilege('anon',oid,'SELECT')),
    'endpoints', (select jsonb_agg(jsonb_build_object(
        'name',proname,'security_definer',prosecdef,
        'anon_execute',has_function_privilege('anon',oid,'EXECUTE'),
        'authenticated_execute',has_function_privilege('authenticated',oid,'EXECUTE')) order by proname)
        from pg_proc where pronamespace = 'public'::regnamespace and proname in (
            'staff_read_report','cash_shared_summary','cash_shared_state','cash_shared_apply','cash_shared_request_status'))
) as diagnostic;
