# App Integral POS

**App Integral POS** — Punto de venta para billar y comida: ventas rápidas, mesas de billar con cobro por tiempo, inventario, promociones, compras/proveedores y estadísticas. Funciona **offline-first** (SQLite local) con sincronización a **Supabase**.

> `version: 2.0.0+1` · SDK Dart `^3.7.2`

---

## Características

- **Venta rápida (PV)**: carrito con descuento de stock en tiempo real (incluye componentes de promos).
- **Mesas de billar**: cobro por tiempo (tarifa por hora) + consumo, con ticket PDF.
- **Inventario**: productos con categorías, costo/precio por pieza y por caja, foto.
- **Promociones**: se arman con varios productos; costo automático = suma de piezas; crear/editar/eliminar con foto.
- **Tickets PDF** dinámicos según ancho de papel (58 mm / 80 mm), con cajero, precio unitario e importe.
- **Sincronización Supabase** offline-first (productos, ventas, configuración, jugadores).
- **Tema personalizable**: el color primario se guarda en `billar_settings` y se restaura al reinstalar.

---

## Requisitos

- Flutter SDK compatible con Dart `^3.7.2`.
- Una cuenta y proyecto en [Supabase](https://supabase.com).

---

## Configuración inicial

### 1. Clonar e instalar dependencias

```bash
git clone https://github.com/luiscbb/app_integral_complete.git
cd app_integral_complete
flutter pub get
```

### 2. Credenciales de Supabase (`.env`)

Las credenciales **no están** en el código. Crea un archivo `.env` en la raíz (usa `.env.example` como plantilla):

```env
SUPABASE_URL=https://TU_PROYECTO.supabase.co
SUPABASE_ANON_KEY=tu_anon_o_publishable_key_aqui
```

Obtén estos valores en: **Supabase Dashboard → Project Settings → API**.

> El `.env` está en `.gitignore` y nunca se sube al repositorio.
> Alternativa para CI/builds: pasar las variables con `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`.

### 3. Esquema y Storage en Supabase

En **Supabase → SQL Editor**, ejecuta los scripts de la carpeta `supabase/` (en este orden la primera vez):

| Script | Para qué sirve |
|--------|----------------|
| `migrate_supabase.sql` | Tablas base (productos, ventas, settings…) |
| `add_primary_color.sql` | Columna `primary_color` en `billar_settings` (tema) |
| `add_categories_and_promo_items.sql` | Categorías de producto + componentes de promo |
| `create_storage_buckets.sql` | Buckets de imágenes (`product_images`, `promo_images`, `player_avatars`) + policies |
| `schema_players.sql` | Tablas de jugadores/partidas |
| `fix_rls.sql` | Ajustes de Row Level Security |
| `add_player_registration.sql` | Membresías y cuentas de jugadores |
| `add_staff_account_fields.sql` | Campos preparatorios de personal; no habilita cuentas |
| `add_sales_origin.sql` | Campo de origen de cada venta; ejecutar antes de actualizar la app |

Las ventas anteriores conservan el origen vacío. Este campo prepara la
separación por módulos, pero no concede ni restringe permisos por sí solo.

Los archivos SQL cuyo nombre termina en `_partial.sql` son borradores y no
deben ejecutarse en Supabase todavía. En particular, el control de revisiones
de inventario bloquearía los cambios de stock de las aplicaciones actuales:
primero es necesario integrarlo en todos los clientes y permitir al
administrador resolver los conflictos conservando los cambios pendientes.
El borrador de cuentas también bloquea las escrituras directas de membresías;
las operaciones de usuarios deben realizarse mediante funciones de servidor.
El borrador de compras limita la lectura por billar y módulo, y reserva las
escrituras directas al administrador; todavía falta integrar y auditar las
operaciones del personal.
El borrador `owner_transaction_sync_partial.sql` prepara operaciones atómicas
con solicitudes idempotentes para ventas y compras del administrador. El
cliente modificado ya depende de estas funciones, pero el borrador aún no está
validado ni desplegado: no debe ejecutarse ni distribuirse el cliente todavía.
Sin las funciones, las ventas y compras quedan pendientes de sincronización.
Las consultas `owner_sync_schema_diagnostic.sql` y
`account_isolation_diagnostic.sql` son de solo lectura.
`remote_security_diagnostic.sql` también es de solo lectura y muestra metadatos
de RLS, permisos anónimos, funciones privilegiadas y buckets de imágenes.
El diagnóstico del proyecto actual mostró políticas permisivas sin restricción
por billar en varias tablas y una restricción que comprueba si la cuenta es
administradora de algún billar, no necesariamente del billar de cada fila.
Un administrador activo podría acceder a datos de otro negocio. El borrador
`owner_business_scope_partial.sql` añade restricciones por billar a tablas
principales; por sí solo no protege todas las tablas, las cuentas ni Storage,
y no debe aplicarse por separado. Es necesario completar y probar las políticas
antes de usar cuentas separadas.
El borrador activa RLS y restringe las operaciones anónimas en las tablas que
abarca. Las ventas y compras preparadas rechazan productos de otro billar o
ausentes en el servidor; esas operaciones quedan pendientes hasta que el
producto correspondiente se sincronice.
La gestión de jugadores preparada requiere una membresía activa y sin cambio
de contraseña pendiente; para acciones de administrador también verifica la
configuración del propietario. Estos cambios de Edge aún no están desplegados.
Los tres buckets de imágenes actuales son públicos. El borrador
`private_image_storage_partial.sql` prepara su aislamiento, pero **no debe
ejecutarse**: el cliente aún usa URLs públicas y debe adaptarse antes.
Los borradores de personal para inventario, ventas y compras sustituyen la
restricción de propietario en sus tablas por controles por billar y módulo.
El borrador de propietario rechaza ejecutarse después de esas políticas para
evitar volver a bloquear al personal. Todos siguen siendo parciales.
El borrador de inventario restringe el acceso directo a productos por billar
y módulo, reserva las escrituras directas al administrador y prepara una
consulta de productos para venta sin costos. El cliente de personal todavía no
está conectado a esa consulta; no aplicar el borrador por separado.
La edición preparada registra los valores anteriores y nuevos y rechaza
versiones obsoletas, evitando sobrescribir cambios de otro administrador.
El borrador de identidad de negocio rechaza identificadores duplicados o
membresías sin propietario, y conserva la reserva del identificador aunque
se elimine la configuración. Tampoco reactiva automáticamente una membresía
al guardar la configuración. Es necesario revisar esos casos antes de aplicarlo.
La resolución de acceso y la descarga de configuración fijan el token de
la sesión inicial y descartan resultados si cambia la cuenta o el token.
Un error de descarga ya no se interpreta como una configuración inexistente:
en el inicio se conserva la sesión y se permite reintentar. Después de una
vinculación verificada, el propietario puede abrir sin conexión su base local
existente; la primera vinculación requiere conexión.
Cada SQLite aislado registra su cuenta y billar y se comprueba antes de abrirlo,
para impedir que una colisión de nombres en Windows abra datos de otro ámbito.
Una base existente sin identidad local ni propietario anterior verificado se
conserva, pero se rechaza hasta revisarla; no se asigna automáticamente.
Al iniciar sesión o abrir la aplicación, si existe la tabla de membresías se
requiere una membresía administradora activa y visible para el negocio del
propietario. La ausencia de una fila visible no permite recuperar el acceso
solo por tener configuración. Si la tabla no existe, se conserva la
compatibilidad anterior. Antes de actualizar una instalación, hay que
comprobar que la membresía del propietario sea activa y visible con su sesión.
La sección Personal de Configuración ya conecta los formularios de creación,
recuperación, edición y activación con el repositorio, pero permanece bloqueada.
Estos flujos se probaron con servicios simulados, no con Supabase Auth real.
La creación y el acceso de personal no deben habilitarse hasta completar los
permisos, el aislamiento de la sincronización y las pruebas reales. El
repositorio conserva las solicitudes por administrador y billar, comprueba la
sesión antes de entregar el resultado y no guarda la contraseña. Una solicitud
solo debe retirarse después de confirmar la entrega del resultado.
Las ventas, jugadores, retiros y movimientos pendientes se filtran por billar; el ciclo
automático se detiene si cambia la sesión, y las subidas de ventas y compras
conservan el token con el que comenzaron. Si cambia la sesión durante la
subida, el registro local permanece pendiente. La cola preparada conserva la
solicitud tras una respuesta perdida y evita importar su copia remota antes del
reintento. Los envíos antiguos con resultado incierto no se pueden identificar
automáticamente. Esta preparación no sustituye el aislamiento de todos los
datos locales y pendientes por cuenta.
Las operaciones que usan `SyncSessionGuard` también rechazan un cambio de
billar A→B→A o una nueva sesión de la misma cuenta, aunque coincida el token.
Esta protección no está conectada a todas las operaciones de la aplicación.
Los informes locales de ventas, detalles de venta, movimientos de inventario
y retiros filtran por billar; también lo hacen las consultas y anulaciones
locales del historial de ventas. El historial, informes y sincronización de
compras solo incluyen las identificadas con el billar actual. Las compras
locales antiguas sin billar se conservan en SQLite, pero se omiten de los
informes, saldos y sincronización y no se asignan automáticamente.
Las consultas y operaciones locales de mesas comprueban el billar. La creación
evita reemplazar mesas existentes y la clave local combina el billar y el
identificador, igual que en Supabase. La migración conserva mesas abiertas y
pedidos.
Las reservas se filtran por el billar del producto relacionado, incluso las
antiguas; las filas cuyo producto no existe se conservan sin utilizar.
Las consultas y modificaciones de reservas y las operaciones de mesas del
repositorio de ventas comprueban la cuenta y el billar durante la operación. Esto
no identifica al autor ni sustituye el aislamiento por cuenta. La anulación
local agrupa stock, movimientos y marcas de cancelación en una transacción;
si falta un producto o componente, se rechaza sin cambios parciales. El cierre
de venta guarda historial, detalles, movimientos y liberación de reservas en
una transacción y rechaza cambios de cuenta o billar durante ella. El descuento
de stock y la sincronización siguen fuera de esa transacción.
Al restaurar el carrito de venta rápida solo se incluyen sus propias reservas,
no las reservas de cuentas personales.
La cola local antigua `pending_sales` solo sincroniza filas identificadas con
la cuenta y billar originales. Las filas anteriores sin identidad se
conservan sin sincronizar y no se asignan al vincular la base.
Al iniciar se conserva una copia local del identificador y la configuración
del negocio antes de modificarlos; no se copia el PIN. La vinculación preparada
exige que el billar coincida con esa copia. Esto no recupera valores que ya se
hubieran sobrescrito.
El inicio selecciona preferencias y bases separadas por cuenta y billar,
con rechazo de transacciones cuando cambia el ámbito. Tras cerrar sesión debe
cerrarse y abrirse la aplicación antes de acceder con otra cuenta. La copia de la
base anterior conserva el archivo original y exige un propietario ya vinculado.
La migración de preferencias comprueba el propietario, conserva los
valores existentes y no sobrescribe cambios ya realizados en el nuevo ámbito.
El arranque integrado se ha probado con servicios simulados en Windows; falta
validarlo en Android y con Supabase real. La base aislada aún no soporta cursores.
La vinculación requiere verificar en línea al administrador y rechaza datos de
otros billares o solicitudes pendientes de otras cuentas. Tras la confirmación,
asigna al billar original los registros de negocio sin identificador; las
compras y ventas rápidas antiguas sin identidad siguen sin sincronizarse.
La sincronización de movimientos de inventario fija el token y billar del
ciclo; si cambia la sesión, conserva pendientes y descarta la página recibida.
Las descargas de compras, ventas y retiros conservan el token inicial y
descartan la transacción local si cambia la cuenta o el billar, o si reciben
registros de otro billar.
La descarga de mesas conserva las filas locales ausentes en una respuesta
parcial; las eliminaciones se propagan mediante su marca de borrado. Las
descargas y subidas de mesas fijan la sesión inicial y no envían mesas de otro
billar; si cambia la sesión, los cambios locales permanecen pendientes.
La descarga de productos tampoco elimina registros ausentes en una respuesta
parcial: los archivados se propagan mediante `is_active`. Un borrado físico
antiguo en la nube no se propaga automáticamente a otros dispositivos.
El catálogo local y las colas de productos se filtran por billar. Las subidas
fijan la sesión y conservan cambios pendientes si esta cambia; la cola de
archivado solo se retira cuando el servidor confirma el producto. Las colas
antiguas de productos aún no identifican a la cuenta que originó cada cambio.
La descarga de proveedores limita las relaciones al billar consultado y no
borra relaciones ausentes de una respuesta parcial. Por ahora, eliminar una
relación en otro dispositivo no la elimina automáticamente de la caché local.
Las comprobaciones de proveedores en el cliente no sustituyen las políticas
del servidor; la sustitución de relaciones en la nube aún no es transaccional.
Los cambios nuevos de proveedores y sus relaciones se guardan en una cola
local con el usuario y billar originales y se reintentan con esa misma cuenta.
Los cambios anteriores a esta cola no pueden identificarse automáticamente.
Los proveedores se archivan localmente, sin borrar compras ni relaciones. El
borrador `provider_delete_idempotent_partial.sql` prepara el archivado
idempotente en la nube y todavía no debe desplegarse. Sin esa función, la
operación queda pendiente: nunca se recurre al borrado físico. Los borrados
antiguos en cola reciben un identificador; si el proveedor ya fue borrado
físicamente en la nube, quedan pendientes para revisión.
El cliente preparado de Compras de personal usa una cola separada
`staff_provider_operations` (SQLite 53) para altas, ediciones y archivados
auditados mediante la RPC
[`apply_staff_provider_operation`](supabase/staff_provider_operations_partial.sql).
Persiste UUID, ID de proveedor, condiciones de pago y relaciones antes de
enviar; una respuesta perdida o inválida conserva la misma solicitud para
recuperarla. No escribe en la caché ni en la cola del propietario. Compras está
conectado al portal y a su ruta solo bajo integración explícita y permiso
`purchases`; el acceso normal de personal permanece deshabilitado.
La acción de verificar cierre requiere confirmación y la RPC preparada en
[`staff_purchase_resolution_partial.sql`](supabase/staff_purchase_resolution_partial.sql),
que debe instalarse después de las RPC de compras y proveedores. Si la operación
ya se aplicó, recupera su comprobante sin cancelarla. Si no, inserta/bloquea la
misma fila de solicitud y sella su UUID para impedir peticiones tardías. Solo un
cierre validado y confirmado en SQLite libera el pendiente; no se borra el
payload ni se interpreta un error de red como rechazo definitivo. SQLite sigue
en 53. El SQL preparado no se despliega ni se habilitan permisos con estos cambios.
Para el proyecto diagnosticado sin cuentas de personal, el archivo completo
[`staff_rollout_install.sql`](supabase/staff_rollout_install.sql) agrupa la
preparación de base de datos en una transacción y devuelve el diagnóstico.
Antes de ejecutarlo en SQL Editor, cerrar la app en los dispositivos.
No ejecutar los borradores por separado: el lote valida prerrequisitos y
mantiene cerrados los endpoints de personal; no activa Edge ni el cliente.
Se regenera con `node supabase\build_staff_rollout.cjs` y se valida con
`node --test test\staff_rollout_install_test.cjs`.
La creación recuperable usa un secreto de servidor: rotarlo con solicitudes
pendientes impide recuperarlas y requiere un procedimiento de resolución antes
de habilitar la función. No compartas ese secreto por chat ni lo guardes en la app.

#### Activación del piloto de personal

Solo después de confirmar el diagnóstico de instalación:

1. En **Edge Functions > Secrets** del mismo proyecto, configurar
   `STAFF_PILOT_ENABLED=true` y, si aún no existe, `STAFF_CREATION_HMAC_KEY`
   con 32 bytes aleatorios criptográficos codificados como 64 caracteres
   hexadecimales. No rotar una clave existente ni compartir su valor.
   Si falta, generar el valor localmente y copiarlo solo al campo del secreto:

   ```powershell
   node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
   ```

   No pegar la salida en el chat ni guardarla en archivos del repositorio.
2. Desde la raíz del repositorio, autenticar la CLI y desplegar los seis archivos
   de la función mediante sus imports, sin Docker:

   ```powershell
   npx supabase login
   npx supabase functions deploy player-admin --remote=TU_PROJECT_REF --use-api
   ```

   Sustituir `TU_PROJECT_REF` por la referencia del proyecto del diagnóstico.
   No usar `--prune` ni desactivar la verificación JWT.
3. Confirmado el despliegue, ejecutar completo
   [`staff_pilot_activation.sql`](supabase/staff_pilot_activation.sql) en SQL
   Editor y revisar `pilot_permissions`. Los endpoints de creación/cambio de
   cuentas solo deben permitir ejecución al servicio; ningún endpoint del
   piloto debe permitir `anon`.
4. Compilar el cliente autorizado con:

   ```powershell
   flutter build apk --debug --no-pub --dart-define=STAFF_PILOT_ENABLED=true
   ```

   Instalar únicamente como actualización autorizada, sin desinstalar ni
   borrar datos. Sin el flag, la gestión y el acceso de personal siguen cerrados.
   En VS Code, el perfil **App Integral (Supabase)** de
   [launch.json](.vscode/launch.json) incluye el flag del piloto. Después de
   cambiar ese argumento hay que detener la ejecución y arrancar de nuevo
   con F5; hot reload/restart conserva los argumentos de la sesión anterior.
   Para depurar los dos teléfonos conectados, elegir **Ambos telefonos (piloto)**:
   inicia **Personal - M2004J19C** y **Administrador - A60L**, cada uno con
   destino explícito y el flag del piloto. En **Consola de depuración**, usar
   **Sesión de depuración** para cambiar los registros visibles.
   Los nombres no cambian la cuenta iniciada en cada teléfono.
   Detener una sesión del compuesto detiene ambas; también pueden iniciarse
   individualmente con sus respectivos perfiles.

El piloto permite Venta rápida, Inventario de consulta y Compras/proveedores.
El inicio de personal comparte el encabezado y las cards del administrador,
pero muestra solo los módulos asignados e integrados, junto con el usuario
conectado y el nombre, logo privado y color del negocio. Conserva sus rutas
protegidas: ver las mismas cards no concede permisos administrativos.
Para actualizar un piloto existente, ejecutar únicamente
[staff_business_profile.sql](supabase/staff_business_profile.sql) antes de
actualizar la app. Esta función solo devuelve identidad visual del billar de
la membresía activa; no abre la tabla de configuración ni sus escrituras.
La instalación agrupada ya incluye esta función para proyectos nuevos.
**No volver a ejecutar la instalación agrupada con cuentas de personal existentes.**
La API rechaza asignar otros módulos incluso si se omite el formulario.
Las pruebas con cuentas autorizadas, revocación y operaciones reales siguen
siendo necesarias antes de distribuir la app.

El borrador `operational_audit_partial.sql` prepara un registro transaccional
de cambios en ventas, compras, productos, movimientos, retiros y configuración,
visible solo para administradores activos del billar. Registra la cuenta que
envió el cambio, que no demuestra quién realizó una operación offline antigua;
las operaciones de servicio sin identidad autenticada quedan sin actor. No
desplegarlo ni considerarlo auditoría completa hasta resolver la procedencia,
los permisos y las demás operaciones.

### 4. Ejecutar

```bash
flutter run
```

Si la app muestra *"Faltan credenciales de Supabase"*, revisa que el archivo `.env` exista y tenga los valores correctos.

---

## Estructura del proyecto

```
lib/
├── core/                # servicios, tema, base de datos, widgets compartidos
│   ├── database/        # SQLite (database_helper.dart) y migraciones
│   ├── services/        # sincronización y repos remotos (Supabase)
│   └── storage/         # preferencias locales
├── features/            # módulos por dominio
│   ├── sales/           # mesas de billar, promos, tickets PDF
│   ├── quick_sale/      # venta rápida (PV)
│   ├── inventory/       # productos y categorías
│   ├── purchases/       # compras y proveedores
│   ├── players/         # jugadores y partidas
│   └── stats/           # historial y estadísticas
└── main.dart            # arranque: carga .env + inicializa Supabase
supabase/                # scripts SQL de esquema y storage
```

---

## Notas

- **Offline-first**: la app guarda en SQLite y sincroniza a Supabase cuando hay conexión. La base local migra sola al abrir (versión de esquema en `database_helper.dart`).
- **Íconos de la app**: generados con `flutter_launcher_icons` desde `assets/baumar_8_personal-sf.png` (`dart run flutter_launcher_icons`).
- **Seguridad**: nunca subas el `.env`. Si una key se filtra, rótala en el panel de Supabase.

### Pruebas SQL locales

Las pruebas aisladas de migraciones y permisos requieren Node.js 22.12 o
posterior y `@electric-sql/pglite` 0.5.16. Después de instalarlo localmente,
ejecuta:

```powershell
node --experimental-strip-types --test test\business_owner_guard_test.cjs test\operational_audit_test.cjs test\product_stock_conflict_guard_test.cjs test\product_stock_conflict_resolution_test.cjs test\provider_delete_idempotent_test.cjs test\staff_account_creation_test.cjs test\staff_module_rls_test.cjs test\staff_inventory_rls_test.cjs test\staff_purchases_rls_test.cjs test\staff_sales_rls_test.cjs test\staff_sale_recording_test.cjs test\sales_origin_schema_test.cjs test\player_admin_permissions_test.ts test\staff_identity_test.ts test\staff_creation_key_test.ts test\staff_creation_workflow_test.ts
```
