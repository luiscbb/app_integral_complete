-- Read-only preflight. Returns metadata and aggregate counts, never account rows.
-- Run against the current project before applying any staff rollout script.
with required_columns(name) as (
    values ('username'), ('full_name'), ('job_title'), ('allowed_modules'),
           ('must_change_password'), ('staff_revision')
),
required_tables(name) as (
    values ('business_memberships'), ('staff_account_requests'),
           ('staff_account_audit'), ('staff_sale_requests'),
           ('staff_sale_stock_products'), ('staff_sale_audit'),
           ('staff_provider_requests'), ('staff_provider_audit'),
           ('staff_purchase_requests'), ('staff_purchase_audit')
),
required_payment_columns(table_name, name) as (
    values ('providers', 'credit_days'), ('providers', 'preferred_payment_method'),
           ('purchases', 'payment_condition'), ('purchases', 'payment_method'),
           ('purchases', 'credit_days'), ('purchases', 'due_date'),
           ('purchases', 'paid_amount'), ('purchases', 'balance_due')
),
payment_column_info as (
    select required.table_name, required.name, attribute.attnum is not null as installed,
           format_type(attribute.atttypid, attribute.atttypmod) as data_type
    from required_payment_columns required
    left join pg_attribute attribute
      on attribute.attrelid = to_regclass('public.' || required.table_name)
     and attribute.attname = required.name and attribute.attnum > 0
     and not attribute.attisdropped
),
required_functions(name) as (
    values ('has_staff_module_access'), ('has_staff_pos_module_access'),
           ('can_access_inventory'), ('staff_sale_products'),
           ('record_staff_sale'), ('get_staff_sale_reconciliation'),
           ('reserve_staff_account'), ('find_staff_creation_auth_user'),
           ('finalize_staff_account'), ('stop_staff_password_recovery'),
           ('complete_staff_password_change'), ('list_staff_accounts'),
           ('update_staff_account'), ('apply_staff_provider_operation'),
           ('record_staff_purchase'), ('resolve_staff_purchase_request'),
           ('staff_business_profile'), ('staff_purchase_report'), ('staff_read_report'),
           ('cash_shared_state'), ('cash_shared_apply'), ('cash_shared_request_status')
),
allowed_modules(id) as (
    values ('quick_sale'), ('billiard_tables'), ('dine_in'),
           ('billiard_tables_open'), ('billiard_tables_consume'),
           ('billiard_tables_charge'), ('billiard_tables_view_all'),
           ('dine_in_open'), ('dine_in_consume'),
           ('dine_in_charge'), ('dine_in_view_all'),
           ('personal_account'), ('inventory'), ('purchases'),
           ('reports'), ('reports_purchases'), ('reports_sales'), ('reports_cash_flow'),
           ('reports_kardex'), ('reports_profit'), ('players'), ('settings')
),
membership_rows as (
    select to_jsonb(membership) as data
    from public.business_memberships membership
),
staff_rows as (
    select data from membership_rows where data ->> 'username' is not null
),
column_info as (
    select required.name, attribute.attnum is not null as installed,
           format_type(attribute.atttypid, attribute.atttypmod) as data_type,
           attribute.attnotnull as not_null,
           pg_get_expr(defaults.adbin, defaults.adrelid) as default_expression
    from required_columns required
    left join pg_attribute attribute
      on attribute.attrelid = to_regclass('public.business_memberships')
     and attribute.attname = required.name and attribute.attnum > 0
     and not attribute.attisdropped
    left join pg_attrdef defaults
      on defaults.adrelid = attribute.attrelid
     and defaults.adnum = attribute.attnum
),
table_info as (
    select required.name, relation.oid is not null as installed,
           relation.relrowsecurity as rls_enabled,
           has_table_privilege('anon', relation.oid, 'SELECT') as anon_select,
           has_table_privilege('authenticated', relation.oid, 'SELECT') as authenticated_select
    from required_tables required
    left join pg_class relation
      on relation.oid = to_regclass('public.' || required.name)
),
function_info as (
    select required.name, procedure.oid is not null as installed,
           pg_get_function_identity_arguments(procedure.oid) as arguments,
           pg_get_function_result(procedure.oid) as result_type,
           procedure.prosecdef as security_definer,
           has_function_privilege('anon', procedure.oid, 'EXECUTE') as anon_execute,
           has_function_privilege('authenticated', procedure.oid, 'EXECUTE') as authenticated_execute,
           has_function_privilege('service_role', procedure.oid, 'EXECUTE') as service_role_execute
    from required_functions required
    left join pg_proc procedure
      on procedure.pronamespace = to_regnamespace('public')
     and procedure.proname = required.name
),
membership_checks as (
    select count(*) as staff_rows,
           count(*) filter (
               where data ->> 'username' !~ '^[a-z0-9][a-z0-9._-]{2,31}$'
           ) as invalid_usernames,
           count(*) filter (
               where data ->> 'role' is distinct from 'manager'
           ) as non_manager_staff,
           count(*) filter (
               where length(btrim(coalesce(data ->> 'full_name', ''))) not between 1 and 120
                  or length(btrim(coalesce(data ->> 'job_title', ''))) not between 1 and 80
           ) as invalid_names_or_jobs,
           count(*) filter (
               where case when jsonb_typeof(data -> 'allowed_modules') = 'array' then
                   jsonb_array_length(data -> 'allowed_modules') = 0
                   or exists (
                       select 1 from jsonb_array_elements(data -> 'allowed_modules') module
                       where jsonb_typeof(module) is distinct from 'string'
                          or module #>> '{}' not in (select id from allowed_modules)
                   )
                   or (select count(distinct module)
                       from jsonb_array_elements(data -> 'allowed_modules') module)
                      <> jsonb_array_length(data -> 'allowed_modules')
               else true end
           ) as invalid_modules
    from staff_rows
)
select jsonb_build_object(
    'purchase_payment_columns', (select jsonb_agg(to_jsonb(c) order by table_name, name) from payment_column_info c),
    'membership_columns', (select jsonb_agg(to_jsonb(c) order by name) from column_info c),
    'staff_tables', (select jsonb_agg(to_jsonb(t) order by name) from table_info t),
    'staff_functions', (select jsonb_agg(to_jsonb(f) order by name, arguments) from function_info f),
    'membership_checks', (
        select to_jsonb(checks) || jsonb_build_object(
            'normalized_username_duplicate_groups', (
                select count(*) from (
                    select lower(btrim(data ->> 'username'))
                    from staff_rows
                    group by lower(btrim(data ->> 'username'))
                    having count(*) > 1
                ) duplicates
            )
        ) from membership_checks checks
    ),
    'membership_constraints', coalesce((
        select jsonb_agg(jsonb_build_object(
            'name', conname, 'validated', convalidated,
            'definition', pg_get_constraintdef(oid)
        ) order by conname)
        from pg_constraint
        where conrelid = to_regclass('public.business_memberships')
          and conname in ('business_memberships_username_format',
                          'business_memberships_allowed_modules_valid')
    ), '[]'::jsonb),
    'username_indexes', coalesce((
        select jsonb_agg(jsonb_build_object('name', indexname, 'definition', indexdef) order by indexname)
        from pg_indexes
        where schemaname = 'public' and tablename = 'business_memberships'
          and indexname = 'business_memberships_username_unique'
    ), '[]'::jsonb),
    'membership_policies', coalesce((
        select jsonb_agg(jsonb_build_object(
            'name', policyname, 'permissive', permissive, 'roles', roles,
            'command', cmd, 'using', qual, 'check', with_check
        ) order by policyname)
        from pg_policies
        where schemaname = 'public' and tablename = 'business_memberships'
    ), '[]'::jsonb)
) as diagnostic;
