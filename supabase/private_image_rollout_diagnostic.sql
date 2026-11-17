-- Solo lectura. Ejecutar como administrador; no devuelve rutas ni datos personales.
-- Los conteos de rutas no verifican host, URL-encoding, acceso por API o caché.
-- No autorizan por sí solos cambiar la privacidad de los buckets.
with
    targets (id) as (
        values ('product_images'),
            ('promo_images'),
            ('player_avatars')
    ),
    objects_info as (
        select o.bucket_id, o.name, o.name ~ '(^|/)\.emptyFolderPlaceholder$' as placeholder, exists (
                select 1
                from public.billar_settings s
                where
                    s.billar_id = split_part(o.name, '/', 1)
                    and position('/' in o.name) > 1
            ) as scoped
        from storage.objects o
            join targets t on t.id = o.bucket_id
    ),
    buckets_info as (
        select
            t.id,
            b.id is not null as installed,
            b.public,
            count(o.name) filter (
                where
                    not o.placeholder
            ) as image_objects,
            count(o.name) filter (
                where
                    o.placeholder
            ) as placeholders,
            count(o.name) filter (
                where
                    not o.placeholder
                    and not o.scoped
            ) as objects_without_known_business
        from
            targets t
            left join storage.buckets b on b.id = t.id
            left join objects_info o on o.bucket_id = t.id
        group by
            t.id,
            b.id,
            b.public
    ),
    image_references as (
        select 'logos' as kind, billar_id, to_jsonb(s) ->> 'logo_url' as value
        from public.billar_settings s
        union all
        select 'products', billar_id, to_jsonb(p) ->> 'image_path'
        from public.products p
        union all
        select 'avatars', billar_id, to_jsonb(p) ->> 'avatar_url'
        from public.players p
        union all
        select 'avatars_legacy', billar_id, to_jsonb(p) ->> 'avatar'
        from public.players p
    ),
    parsed as (
        select kind, billar_id, regexp_match(
                value, '/storage/v1/object/(?:public|authenticated|sign)/(product_images|promo_images|player_avatars)/([^?#]+)'
            ) as parts
        from image_references
        where
            nullif(btrim(value), '') is not null
    ),
    references_info as (
        select
            kind,
            count(*) as total,
            count(*) filter (
                where
                    parts is null
            ) as noncanonical_or_external_references,
            count(*) filter (
                where
                    parts is not null
                    and (
                        nullif(btrim(billar_id), '') is null
                        or left(
                            parts[2],
                            length(billar_id) + 1
                        ) <> billar_id || '/'
                    )
            ) as paths_outside_row_business,
            count(*) filter (
                where
                    parts is not null
                    and not exists (
                        select 1
                        from storage.objects o
                        where
                            o.bucket_id = parts[1]
                            and o.name = parts[2]
                    )
            ) as unresolved_object_paths
        from parsed
        group by
            kind
    )
select jsonb_build_object(
        'buckets', (
            select jsonb_agg(
                    to_jsonb(b)
                    order by id
                )
            from buckets_info b
        ), 'references', coalesce(
            (
                select jsonb_agg(
                        to_jsonb(r)
                        order by kind
                    )
                from references_info r
            ), '[]'::jsonb
        ), 'authenticated_api_and_offline_tests_still_required', true
    ) as diagnostic;