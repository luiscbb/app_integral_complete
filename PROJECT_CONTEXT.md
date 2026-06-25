# Baumar POS - Estado del Proyecto
# Ultima actualizacion: 2026-06-23
# Proposito: Este archivo guarda el contexto de trabajo para evitar
# perder el hilo entre sesiones. NUNCA borrar.

## PROBLEMA PRINCIPAL EN CURSO (RESUELTO EN CODIGO)
- El flag `isFirstRun` solo existia en SharedPreferences (local).
- Al reinstalar la app en Android/desktop, se perdia y volvia a pedir setup.
- SOLUCION: Tabla `billar_settings` en Supabase + logica en SplashPage para recuperar config.

## SOLUCION IMPLEMENTADA (listo para probar)
1. **Nueva tabla Supabase:** `billar_settings` (user_id, billar_id, business_name, table_count, hourly_rate)
2. **Nuevo repositorio Flutter:** `lib/core/services/config_remote_repository.dart`
3. **SplashPage modificado:** Si `isFirstRun=true` + sesion activa + config remota existe, restaura local y salta al Home.
4. **LoginPage modificado:** Al hacer login, descarga config remota, guarda local, recrea mesas, salta setup.
5. **InitialSetupPage modificado:** Al finalizar setup, sube config a Supabase si hay sesion.
6. **ConfigPage modificado:** Al guardar datos del negocio y config de billar, sincroniza con Supabase.

## SCHEMA SUPABASE - ESTADO VERIFICADO (2026-06-23)
### Tablas existentes y RLS activo:
- `billar_settings`   - UUID PK. RLS activo. Policies por user_id.
- `players`            - UUID PK. RLS activo.
- `match_results`      - UUID PK. FK a players. RLS activo.
- `products`           - BIGINT PK (id local). RLS activo.
- `promo_items`        - BIGINT PK (identity). FK a products. RLS activo.
- `providers`          - BIGINT PK (id local). RLS activo.
- `sales_history`      - BIGINT PK (id local). Tiene columna `paid`. RLS activo.
- `sale_details`       - BIGINT PK (identity). FK a sales_history. RLS activo.
- `purchases`          - BIGINT PK (id local). Tiene `billar_id`, `synced`, `cloud_id`. RLS activo.
- `purchase_details`   - BIGINT PK (identity). FK a purchases. RLS activo.
- `pending_sales`      - UUID PK. RLS activo.

### Tablas ELIMINADAS de Supabase:
- `sales` (tabla vieja, reemplazada por sales_history + sale_details)

### Tablas EXCLUSIVAMENTE LOCALES (no en Supabase):
- `billiard_tables` (se regeneran dinamicamente desde table_count)

### Buckets Storage existentes:
- `product_images`  (usado por ProductRepository._uploadImage)
- `player_avatars`  (usado por SyncService.pushPlayerToCloud)

## MIGRACIONES APLICADAS EN SUPABASE (2026-06-23)
1. `billar_settings` creada.
2. Columna `paid` agregada a `sales_history`.
3. Secuencia para `sales_history.id` configurada.
4. Columnas `billar_id`, `synced`, `cloud_id` agregadas a `purchases`.
5. Tabla `pending_sales` creada.
6. RLS activado en TODAS las tablas public.
7. Policies creadas/actualizadas en todas las tablas.

## MODULOS DE LA APP Y ESTADO DE SINCRONIZACION
| Modulo         | Tabla Supabase           | Estado Sync                  | Notas |
|----------------|--------------------------|------------------------------|-------|
| Config         | billar_settings          | Bidireccional                | Fetch en splash/login. Upsert en setup/config. |
| Inventario     | products, promo_items    | Bidireccional                | Descarga al abrir, sube al crear/editar. Stock sync al vender/comprar. |
| Proveedores    | providers                | Bidireccional                | Push inmediato, delete immediato. |
| Ventas         | sales_history, details   | Subida (push) + pull         | Ventas locales se suben con SyncService.schedulePendingSync(). |
| Compras        | purchases, details       | Subida (push) + pull         | Ventas locales se suben con SyncService.schedulePendingSync(). |
| Quick Sale     | pending_sales            | Subida inmediata             | Insert directo a Supabase. |
| Jugadores      | players                  | Subida inmediata             | Push desde PlayerRepository.insert(). |
| Partidas       | match_results            | NO IMPLEMENTADO              | Se crean localmente pero NO se sincronizan a Supabase. |
| Mesas billar   | (solo local)             | N/A                          | Se regeneran desde table_count. |
| Dine In        | (solo local)             | N/A                          | No usa Supabase actualmente. |
| Games          | (solo local)             | N/A                          | No usa Supabase actualmente. |
| Torneos        | (solo local)             | N/A                          | No usa Supabase actualmente. |
| Estadisticas   | (solo lectura local)     | N/A                          | Consume datos locales. |
| Cliente Especial| (solo local)            | N/A                          | No usa Supabase actualmente. |
| Personal Stats | (solo local)             | N/A                          | No usa Supabase actualmente. |

## ARCHIVOS SQL SUPABASE (todos en carpeta `supabase/`)
- `schema_players.sql`    - Schema completo actual (refleja realidad de Supabase). En desuso por separacion.
- `migrate_supabase.sql`  - Script de migracion incremental (ya ejecutado con exito). 
- `fix_rls.sql`           - Habilita RLS y policies en todas las tablas (ya ejecutado con exito).

## ARCHIVOS FLUTTER MODIFICADOS (esta sesion)
- `lib/core/services/config_remote_repository.dart` - **NUEVO**
- `lib/features/home/presentation/pages/splash_page.dart` - **MODIFICADO** (recupera config remota)
- `lib/features/auth/presentation/pages/login_page.dart` - **MODIFICADO** (descarga config al login)
- `lib/features/config/presentation/pages/initial_setup_page.dart` - **MODIFICADO** (sube config al setup)
- `lib/features/config/presentation/pages/config_page.dart` - **MODIFICADO** (sync al guardar)

## ARCHIVOS FLUTTER EXISTENTES (no modificados en esta sesion pero relevantes)
- `lib/core/services/sync_service.dart` - Maneja sync de ventas, compras y jugadores.
- `lib/features/inventory/data/repositories/product_repository.dart` - Sync bidireccional de productos.
- `lib/features/purchases/data/repositories/purchases_repository.dart` - Sync de compras y stock.
- `lib/features/players/data/repositories/player_repository.dart` - Sync de jugadores.

## PROXIMO PASO (PENDIENTE)
**Probar flujo completo desde cero en dispositivo/emulador limpio:**
1. Supabase truncado (tablas vacias).
2. App desinstalada / datos borrados.
3. Abrir app -> SplashPage detecta sesion activa? -> Si hay sesion + config remota -> Home.
4. Si no hay sesion -> LoginPage.
5. Si hay sesion pero NO hay config remota -> LoginPage (o InitialSetupPage).
6. Hacer login -> descarga config? -> crea mesas? -> Home.
7. Ir a Config -> guardar datos del negocio -> verificar que aparece en `billar_settings`.
8. Usar cada modulo y verificar que escribe en la tabla Supabase correcta.

## NOTAS PARA LA PROXIMA SESION
- Si la proxima vez el asistente no recuerda, mostrale este archivo.
- El objetivo actual es probar la sincronizacion modulo por modulo.
- Ya se resolvio el flujo de reinstalacion (codigo listo).
- No instalar version desktop hasta validar la logica en movil/emulador.
