-- Solo metadatos: no lee cuentas, compras, solicitudes ni secretos.
select jsonb_build_object(
    'report_installed',
        to_regprocedure('public.staff_purchase_report(text,timestamptz,timestamptz,bigint)') is not null,
    'report_authenticated_execute', coalesce(has_function_privilege(
        'authenticated', to_regprocedure('public.staff_purchase_report(text,timestamptz,timestamptz,bigint)'),
        'EXECUTE'), false),
    'report_anon_execute', coalesce(has_function_privilege(
        'anon', to_regprocedure('public.staff_purchase_report(text,timestamptz,timestamptz,bigint)'),
        'EXECUTE'), false),
    'report_security_definer', coalesce((
        select prosecdef from pg_proc where oid =
            to_regprocedure('public.staff_purchase_report(text,timestamptz,timestamptz,bigint)')
    ), false),
    'membership_constraint_supports_report', exists (
        select 1 from pg_constraint
        where conrelid = 'public.business_memberships'::regclass
          and conname = 'business_memberships_allowed_modules_valid'
          and position('reports_purchases' in pg_get_constraintdef(oid)) > 0
    ),
    'report_only_added_to_direct_purchase_policies', exists (
        select 1 from pg_policies
        where schemaname = 'public' and tablename in ('purchases', 'purchase_details', 'providers')
          and (position('reports_purchases' in coalesce(qual, '')) > 0
               or position('reports_purchases' in coalesce(with_check, '')) > 0)
    ),
    'account_mutations_service_only', (
        select count(*) = 2 and bool_and(
            not has_function_privilege('authenticated', oid, 'EXECUTE')
            and not has_function_privilege('anon', oid, 'EXECUTE')
            and has_function_privilege('service_role', oid, 'EXECUTE')
        )
        from pg_proc where pronamespace = 'public'::regnamespace
          and proname in ('reserve_staff_account', 'update_staff_account')
    )
) as diagnostic;
