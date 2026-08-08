# Estado de la sesión (para retomar)

> Generado automáticamente para poder revisar avances mientras se recargan créditos.
> Todo lo listado abajo ya está en el código (working tree), sin commitear.

## Verificación de estado actual

```
dart analyze .
```
Resultado: **0 errores**. 6 avisos de estilo (`info`), no bloqueantes:
- `lib/features/reports/data/repositories/reports_repository.dart:156,159,162` → llaves faltantes en `for` de una línea (estilo).
- `lib/features/reports/presentation/pages/reports_page.dart:243,455` → `value` deprecado en un `DropdownButtonFormField` (usar `initialValue`).
- `lib/features/reports/presentation/pages/sales_history_page.dart:117` → uso de `BuildContext` tras un `await` sin verificar `mounted`.

Ninguno impide compilar. El proyecto queda **funcional** en el estado actual.

---

## 1. Migración SQLite Windows (resuelto y verificado con build)
- `pubspec.yaml`: se reemplazó el hook `sqlite3: source: system` por `sqlite3_flutter_libs: ^0.5.32`.
- Verificado con `flutter build windows --release` → build exitoso, `sqlite3.dll` se empaqueta junto al `.exe`.
- Pendiente opcional: si vuelve a aparecer el warning "Not used anymore, update to version 3.x of package:sqlite3", revisar la versión transitiva de `sqlite3` en `pubspec.lock`.

## 2. Módulo "Informes" (antes "Estadísticas")
- Rutas: `AppRoutes.stats` → `AppRoutes.reports` (`lib/core/routes/app_routes.dart`, `app_router.dart`).
- Home: tarjeta "ESTADÍSTICAS" → "INFORMES" (`lib/features/home/presentation/pages/home_page.dart`).
- Nueva carpeta `lib/features/reports/` con:
  - `presentation/pages/reports_page.dart` (4 pestañas: Ventas, Compras, Caja, Kardex).
  - `presentation/pages/sales_history_page.dart`.
  - `data/repositories/reports_repository.dart` (ventas, compras, kardex, flujo de caja, retiros, sesiones de caja).
- Archivos viejos `lib/features/stats/...` quedaron eliminados (`git status` muestra `D`).

## 3. Unificación de stock (Venta Rápida ↔ Mesas de Billar)
- Nuevo servicio `lib/features/sales/data/repositories/stock_reservation_service.dart` con tabla `temp_reservations` (SQLite local).
- `sales_repository.dart`: `getReservedQuantities()` ahora suma reservas de mesas y de venta rápida; `saveTableOrder`/`freeTable` actualizan la reserva de la mesa.
- `quick_sale_page.dart`: cada cambio en el carrito persiste la reserva (`_persistReservation()`), se restaura al recargar y se limpia al cobrar.
- **Pendiente de tu parte:** probar en runtime que el stock se ve igual desde ambos módulos sin cerrar la venta.

## 4. Informes de compras, kardex y flujo de caja
- `reports_repository.dart` registra automáticamente movimientos de inventario (`inventory_movements`) al vender (`sales_repository.dart → saveSale`) y al comprar (`purchases_repository.dart → savePurchase`).
- Cálculo de flujo de caja: `ventas - compras - retiros`, con diálogo para registrar retiros/gastos (`_addOutflow`).
- Base para corte de caja (parcial/total) ya modelada en `cashier_sessions`, pero **la pantalla de UI de corte parcial/total con ticket aún no se construyó** (quedó pendiente de confirmación).

## 5. Script SQL para Supabase — ⚠️ ACCIÓN REQUERIDA
Archivo: `supabase/add_reports_and_cashflow.sql`
**Debes ejecutarlo manualmente en el SQL Editor de Supabase** para crear:
- Tablas `inventory_movements`, `cash_outflows`, `cashier_sessions`.
- Columnas nuevas en `purchases`: `provider_id`, `reference`.
- Funciones `get_total_sales`, `get_total_purchases`, `get_total_outflows`, `get_cash_flow`.
- Policies RLS simples (`using (true)` / `with check (true)`, filtrado real se hace desde la app por `billar_id`).
- Índices de rendimiento.

Sin este paso, el módulo de Informes (compras/caja/kardex) no tendrá tablas en la nube para sincronizar (localmente sí funciona con SQLite).

**Fix aplicado tras error real de ejecución:** al correrlo por primera vez, Supabase devolvió:
```
ERROR: 42883: operator does not exist: text >= timestamp with time zone
LINE 133: and date between p_start and p_end;
```
Causa: `sales_history.date` y `purchases.date` son `text` (ISO8601 guardado desde Flutter), no `timestamptz` (confirmado en `recovery_full_schema.sql:244,298`). Se corrigió `get_total_sales` y `get_total_purchases` en `add_reports_and_cashflow.sql` agregando el cast `date::timestamptz` antes de comparar. `get_total_outflows` no necesitó cambio porque `cash_outflows.created_at` ya es `timestamptz`. **Vuelve a ejecutar el script completo en Supabase con esta versión corregida.**

## 6. Limpieza de imágenes huérfanas en Supabase Storage
- `lib/features/inventory/data/repositories/product_repository.dart`:
  - `update()` ahora borra la imagen anterior del bucket `product_images` si cambia o se elimina.
  - `delete()` borra la imagen del producto (y de sus hijos de promo) antes de borrar el registro.
  - Nuevo helper privado `_deleteImageIfCloud()`.
- **Reutilización de imágenes en apps nuevas:** ya se guarda la URL pública completa en `image_path`; cualquier app nueva que use el mismo proyecto Supabase puede leerlas directamente sin volver a subirlas.
- **No resuelto (fuera de alcance de esta sesión):** el bucket `player_avatars` (`lib/core/services/sync_service.dart:230`) tiene el mismo patrón de subida sin limpieza, pero no se encontró un flujo de borrado de jugadores en el código para enlazar el fix. Revisar si se agrega esa función.

## 7. Mesas de billar — segunda forma de iniciar el tiempo
- `lib/features/sales/presentation/pages/billiard_tables_page.dart`:
  - Se mantiene el diálogo inicial (una sola vez) para preguntar si se inicia el cronómetro.
  - Se añadió un banner persistente y tocable "Cronómetro no iniciado · Toca aquí para cobrar tiempo" en el cuerpo de la pantalla de mesa (visible siempre que la mesa esté ocupada sin cronómetro y haya tarifa configurada), además del botón ya existente en el AppBar ("INICIAR TIEMPO").
  - **Corrección:** el diálogo inicial ahora no se cierra al tocar fuera, no tiene opción "Solo consumo" y solo se cierra al presionar "INICIAR TIEMPO". Esto evita que por error se quede la mesa sin cronómetro y sin forma de volver a iniciarlo.
- **Pendiente de tu parte:** probar en runtime/exe que el banner aparece, que el diálogo no cierra con tocar fuera y que solo inicia tiempo al confirmar.

## 8. Sincronización de configuración entre dispositivos
- Se agregó suscripción a Supabase Realtime en `billar_settings` filtrado por `user_id` en `lib/features/home/presentation/pages/home_page.dart`.
- `splash_page.dart` sincroniza `billar_settings` cada vez que la app inicia con sesión activa.
- **Importante:** ambos dispositivos deben usar el mismo usuario de Supabase. Si el `.exe` no pide login, borra las carpetas de datos locales listadas abajo y vuelve a iniciar sesión.

## 9. Botón GUARDAR flotante en Configuración
- `lib/features/config/presentation/pages/config_page.dart`:
  - El botón `GUARDAR` de las secciones **Negocio** e **Impresión** ahora flota siempre visible en la parte inferior derecha del panel de contenido **solo en pantallas grandes** (`width > 900`), usando `Stack` + `Positioned`.
  - En pantallas pequeñas (móvil/tablet) el botón vuelve al final del scroll dentro de la sección, como estaba originalmente.
  - Se usan `GlobalKey<_NegocioSectionState>` y `GlobalKey<_ImpresionSectionState>` para invocar `_save()` desde el botón flotante común.
  - Se eliminaron los botones `GUARDAR` duplicados al final del contenido de cada sección.
- **Pendiente de tu parte:** probar en pantallas grandes que el botón flota y guarda; en móvil, que aparece al final del scroll y guarda.

## 10. Logo del negocio: soporte y sincronización en tiempo real

**Problemas encontrados:**
1. `HomeHeader` en modo escritorio (`isDesktop`) no mostraba el logo configurado.
2. `SplashPage` usaba una imagen fija (`assets/baumar_8_personal-sf.png`) en lugar del logo guardado en `logoUrl` / `logoPath`.
3. No existía mecanismo para reflejar cambios de configuración (incluido el logo) mientras la app está abierta en otro dispositivo.
4. **Los tickets/PDF solo leían `logoPath` (archivo local)**, por lo que en el celular no se veía el logo cargado desde el `.exe` aunque `logoUrl` llegara bien.

**Cambios realizados:**
- `lib/features/home/presentation/widgets/home_header.dart`: en modo escritorio se muestra el logo circular al inicio del header cuando existe `logoUrl` o `logoPath`.
- `lib/features/home/presentation/pages/splash_page.dart`:
  - Se carga el logo desde `logoUrl` (usando `CachedNetworkImageProvider`) o `logoPath` si existe.
  - Si no hay logo configurado, se mantiene la imagen por defecto.
  - Se extrajo `_applyRemoteSettings()` para reutilizar la lógica de aplicar config remota.
- `lib/features/home/presentation/pages/home_page.dart`:
  - Se agregó suscripción a Supabase Realtime en `billar_settings` filtrado por `user_id`.
  - Al recibir un cambio remoto se actualizan: nombre del negocio, `billar_id`, número de mesas, tarifa, color primario y **logo**.
  - Esto permite que, si cambias el logo/config en un dispositivo, el otro lo refleje sin necesidad de reiniciar la app.
- `lib/features/sales/presentation/services/ticket_service.dart`:
  - Se agregó `_loadLogoBytes()` que intenta primero `logoPath` local y, si no existe, descarga `logoUrl` remoto con `HttpClient`.
  - Tanto la impresión Bluetooth como el PDF de ventas ahora usan ese helper.
- `lib/features/purchases/presentation/pages/purchases_page.dart`:
  - Se agregó `_loadLogoBytes()` con la misma lógica (local → remoto).
  - El PDF de compras ya muestra el logo sincronizado por URL cuando no hay archivo local.

**Nota importante sobre la imagen del billar (logo):**
- El bucket usado para el logo es el mismo que para imágenes de productos: `product_images`.
- Al guardar el logo en `ConfigPage`, se sube a `product_images/logos/logo_<timestamp>.jpg` y se guarda la URL pública en `logo_url` de `billar_settings`.
- El `SplashPage`, `HomeHeader`, tickets de venta y PDF de compras usan esa URL pública como fallback, por lo que cualquier dispositivo conectado al mismo proyecto Supabase puede mostrarla sin volver a subirla.

**Pendiente de tu parte:**
1. Asegurarte de que el `.exe` y el celular inicien sesión con el **mismo usuario** de Supabase.
2. Modificar el logo en un dispositivo y verificar que, en el otro, el logo cambia en el header, splash y PDF/tickets.
3. Si el logo sigue sin verse, revisar en Supabase Storage → bucket `product_images` → carpeta `logos` que la imagen exista y sea pública.

**Código relevante:**
- `lib/features/config/presentation/pages/config_page.dart` (subida del logo).
- `lib/features/home/presentation/widgets/home_header.dart`.
- `lib/features/home/presentation/pages/splash_page.dart`.
- `lib/features/home/presentation/pages/home_page.dart` (Realtime).
- `lib/features/sales/presentation/services/ticket_service.dart`.
- `lib/features/purchases/presentation/pages/purchases_page.dart`.

## 11. Fix deprecado `anonKey` en `main.dart`
- `lib/main.dart`: se reemplazó `anonKey: supabaseAnonKey` por `publishableKey: supabaseAnonKey` en `Supabase.initialize`.
- Esto elimina el aviso de deprecado y evita que falle en futuras versiones de `supabase_flutter`.

---

## Resumen: hecho / pendiente

### Hecho en esta sesión
- [x] Botón `GUARDAR` flotante en Configuración **solo en pantallas grandes**; en móvil vuelve al final del scroll (`config_page.dart`).
- [x] Banner/diálogo de iniciar tiempo en Mesas de Billar corregido: no cierra al tocar fuera, sin opción "Solo consumo", solo inicia al confirmar (`billiard_tables_page.dart`).
- [x] Logo visible en `HomeHeader` escritorio.
- [x] `SplashPage` usa el logo configurado si existe.
- [x] Sincronización en tiempo real de `billar_settings` mediante Supabase Realtime (`home_page.dart`).
- [x] Logo también visible en tickets de venta y PDF de compras desde URL remota.
- [x] Fix `anonKey` deprecado → `publishableKey` en `main.dart`.
- [x] `flutter analyze`: 0 errores, 6 avisos de estilo preexistentes.
- [x] `ESTADO_SESION.md` actualizado como respaldo.

### Pendiente para esta sesión (por orden)
1. **Investigar y corregir flujo del logo/imagen:**
   - El logo no se muestra ni en el dispositivo donde se selecciona ni en el otro dispositivo.
   - Revisar subida a Supabase Storage, URL pública, permisos del bucket y carga en widgets.
   - Agregar logs temporales para diagnóstico.
2. **Investigar "app no responde" en celular al inicio.**
3. Probar botón GUARDAR flotante en pantallas grandes y móvil.
4. Probar banner de iniciar tiempo corregido.
5. Probar consistencia de stock entre Venta Rápida y Mesas de Billar.
6. Probar módulo de Informes.
7. Decidir si se construye pantalla de Corte Parcial/Total de Caja.
8. Documentar/planear botón para limpiar base local.
9. Opcional: limpiar 6 avisos de lint restantes.

### Nota importante
- `supabase/add_reports_and_cashflow.sql` ya fue ejecutado correctamente en Supabase.
- El punto E (botón limpiar base) queda como feature futuro, a planear después de las pruebas.

### Plan de pruebas para logo/config (runtime)
1. Dejar el teléfono corriendo con sesión iniciada y logo/config guardados.
2. En Windows, cerrar el exe y borrar las carpetas de datos locales listadas abajo.
3. Compilar e instalar el exe desde cero (`flutter build windows --release`).
4. Abrir el exe e iniciar sesión con el **mismo usuario** del teléfono.
5. Verificar que el exe cargue el logo, nombre, color y tarifa del teléfono.
6. Con ambas apps abiertas, cambiar el logo/config en un dispositivo y verificar que se refleje en el otro en pocos segundos.
7. Si no se refleja, revisar:
   - Mismo `user_id` en ambos dispositivos.
   - Bucket `product_images/logos` en Supabase Storage tenga la imagen y sea pública.
   - Logs de red/consola en el dispositivo que no recibe el cambio.

---

## Cómo probar el `.exe` y el celular con estos cambios

### Paso 1: compilar el `.exe` de Windows
```bash
flutter build windows --release
```
El ejecutable queda en:
```
build\windows\x64\runner\Release\app_integral_complete.exe
```

### Paso 2: limpiar datos locales del `.exe` si antes usaba otro usuario
Si el `.exe` no pide login, es porque tiene una sesión vieja guardada. Cierra la app y borra estas carpetas (reemplaza `TU_USUARIO`):
```
C:\Users\TU_USUARIO\Documents\BaumarSolutions
C:\Users\TU_USUARIO\AppData\Roaming\com.example\app_integral_complete
C:\Users\TU_USUARIO\AppData\Local\com.example\app_integral_complete
```
Luego abre el `.exe` e inicia sesión con el **mismo correo/usuario** del celular.

### Paso 3: configurar desde un solo dispositivo
- Abre la app en el celular y entra a **Configuración**.
- En la sección **Negocio** sube el logo, cambia el nombre, color, etc., y presiona el botón **GUARDAR** flotante.
- Espera unos segundos a que se suba la imagen y se guarde en `billar_settings`.

### Paso 4: verificar en el otro dispositivo
- En el `.exe` (o en el celular, según dónde hayas hecho el cambio), estando en la pantalla **Home**, deberías ver:
  - El nombre del negocio actualizado.
  - El color primario actualizado.
  - El logo actualizado en el header.
- **No es necesario reiniciar** gracias al listener de Supabase Realtime.
- Para probar tickets/PDF: realiza una venta o compra y revisa que el logo aparezca en el documento.

### Si no se refleja:
1. Revisa que ambos dispositivos usen el mismo `user_id` (puedo agregar logs temporalmente en la siguiente sesión si lo necesitas).
2. En Supabase, verifica que el bucket `product_images` tenga permisos públicos y la carpeta `logos` contenga la imagen.
3. Revisa que no haya error de red en la consola del dispositivo.

### Nota sobre el "app no responde" en celular
- Puede ser la primera carga pesada de SQLite + imagen de splash grande. Si persiste, en la siguiente sesión puedo agregar logs de inicio y/o precargar la imagen del logo de forma asíncrona para no bloquear el splash.

### Resultado de prueba inicial (celular + exe)
- **Celular:** al iniciar la app mostró "app no responde" brevemente, luego entró. **Pendiente investigar y corregir.**
- **Windows exe:**
  - Solicitó login correctamente.
  - Inició sesión con el mismo usuario del celular.
  - Tema y tarifa se descargaron correctamente desde `billar_settings`.
  - **Logo no se cargó** en el header del Home ni en el splash.
- **Cambio de logo en Windows tampoco se refleja:** el usuario confirma que si cambia la imagen en el exe, tampoco se ve el logo actualizado en los lugares correspondientes (header, splash, tickets, PDFs).
- **Conclusión parcial:** la sincronización de `billar_settings` funciona para texto (nombre, tarifa, color), pero **el flujo de la imagen/logo está roto tanto local como remoto**. No es solo un problema de sincronización entre dispositivos; la imagen no se muestra ni en el mismo dispositivo donde se seleccionó.

### Posibles causas del logo no mostrándose
1. `_uploadLogoToStorage` puede estar fallando silenciosamente en `config_page.dart` y `_logoUrl` queda null.
2. `_save()` en `config_page.dart` solo setea `logoUrl` si `_logoPath != null`. Si el usuario no cambia el logo, no se reenvía la URL anterior a Supabase.
3. `logo_url` no se guardó correctamente en `billar_settings` desde el celular.
4. El bucket `product_images/logos` no es público o la imagen no existe.
5. La URL pública de Supabase Storage requiere token adicional o no está habilitada.
6. `CachedNetworkImageProvider` no maneja bien errores de carga ni muestra fallback.
7. `HomeHeader` / `SplashPage` leen `logoUrl` de preferencias, pero puede estar vacío o no actualizarse después del guardado.
8. En Windows, `File(_logoPath!).existsSync()` puede fallar por permisos o ruta, y si `_logoUrl` también es null/vacío, no muestra nada.

### Plan de diagnóstico y corrección para la siguiente sesión
1. **Logs temporales:** agregar `debugPrint` en `_uploadLogoToStorage`, `_save`, `HomeHeader.build`, `SplashPage._loadSplashLogo` y `home_page.dart` Realtime callback para ver el valor real de `logoUrl`/`logoPath`.
2. **Error visible:** agregar `errorBuilder` y placeholder en todas las cargas de logo (`Image.network`, `CachedNetworkImageProvider`, `Image.file`) para detectar si falla la carga.
3. **Verificar Supabase Storage:**
   - Ir a Storage → bucket `product_images` → carpeta `logos`.
   - Confirmar que la imagen subida existe.
   - Confirmar que el bucket es público (Policies → permisos de lectura para `anon` y `authenticated`).
   - Copiar la URL pública y probarla en navegador.
4. **Revisar `config_remote_repository.dart`:** confirmar que `logoUrl` se envía en el payload y que `upsertSettings` no lo está omitiendo.
5. **Corregir `_save()`:** asegurar que si ya existe `logoUrl` local y no se cambió la imagen, se siga enviando a Supabase.
6. **Corregir el flujo del logo** según el hallazgo real.
7. Investigar el "app no responde" del celular.

### Mensaje de cierre de sesión
- Se escucharon todas las dudas y observaciones del usuario.
- Se documentó que el problema del logo es **tanto local como remoto**: no se ve ni en el dispositivo donde se selecciona.
- Se dejó un plan de diagnóstico concreto para la siguiente sesión.
- Se mantiene la línea de trabajo: primero estabilizar logo y arranque del celular, luego seguir con stock, mesas, informes y features adicionales.

---

## Resumen final del día (guardar para mañana)

### Implementado hoy (con solución aplicada)
1. **Banner/diálogo iniciar tiempo en Mesas de Billar** — `billiard_tables_page.dart`
   - Solución: `barrierDismissible: false`, sin opción "Solo consumo", solo cierra con "INICIAR TIEMPO".
2. **Botón GUARDAR flotante responsivo en Configuración** — `config_page.dart`
   - Solución: flotante en pantallas grandes (`width > 900`), al final del scroll en pantallas pequeñas.
3. **Fix `anonKey` → `publishableKey`** — `main.dart`
   - Solución: parámetro actualizado en `Supabase.initialize`.
4. **Soporte de logo remoto en tickets/PDFs** — `ticket_service.dart`, `purchases_page.dart`
   - Solución: helper `_loadLogoBytes()` que descarga `logoUrl` cuando no hay `logoPath` local.

### Implementado en sesiones anteriores (pendiente de validar)
5. **Logo en HomeHeader escritorio** — `home_header.dart`
6. **Logo en SplashPage** — `splash_page.dart`
7. **Sincronización Realtime de `billar_settings`** — `home_page.dart`

### No resuelto (requiere diagnóstico mañana)
8. **Logo/imagen del negocio no se muestra ni local ni remoto.**
   - Se implementó el flujo, pero en la prueba de runtime no funcionó.
   - Requiere logs + revisión de Supabase Storage + corrección según hallazgo.
9. **"App no responde" al abrir en celular.**
   - Requiere logs de inicio y optimización de carga inicial.
10. **Stock unificado, Informes, Corte de caja, Botón limpiar base** — pendientes de prueba o decisión.

### Archivos clave para revisar mañana
- `lib/features/config/presentation/pages/config_page.dart` (subida y guardado del logo)
- `lib/features/home/presentation/pages/splash_page.dart` (carga del logo)
- `lib/features/home/presentation/widgets/home_header.dart` (logo en header)
- `lib/features/home/presentation/pages/home_page.dart` (Realtime)
- `lib/features/sales/presentation/services/ticket_service.dart` (logo en tickets)
- `lib/features/purchases/presentation/pages/purchases_page.dart` (logo en PDF compras)

### Primer paso mañana
1. Agregar logs temporales en el flujo del logo.
2. Ejecutar app en Windows con `flutter run -d windows` para ver logs en consola.
3. Verificar en Supabase Storage si la imagen existe y es pública.
4. Corregir según la evidencia real.

### Acción de hoy (logs agregados + ajuste de splash)
- Se agregaron logs temporales en:
  - `lib/features/config/presentation/pages/config_page.dart` (subida y guardado del logo).
  - `lib/features/home/presentation/pages/splash_page.dart` (carga del logo).
  - `lib/features/home/presentation/widgets/home_header.dart` (carga del logo + `onBackgroundImageError`).
  - `lib/features/home/presentation/pages/home_page.dart` (Realtime callback).
- Se agregó `onBackgroundImageError` en `CircleAvatar` del `HomeHeader` para detectar errores de carga de imagen.
- Se corrigió `onBackgroundImageError` para no lanzar excepción cuando no hay logo.
- **Ajuste de filosofía:** el splash ahora SIEMPRE usa la imagen por defecto de la app (`assets/baumar_8_personal-sf.png`). El logo del cliente solo se muestra dentro de la app (header, config, tickets, PDFs).
- `flutter analyze`: 0 errores, 6 avisos preexistentes.

### Resultado de prueba de hoy
- **Logo del cliente SÍ se sincroniza correctamente vía Supabase.**
- La URL pública llega al celular y se ve en el header del Home.
- **ANR en celular persiste:** la app muestra "no responde" brevemente al inicio, pero luego funciona si se presiona "esperar". Requiere optimización del arranque en otra sesión.
- **Stock unificado:** se identificó y corrigió doble descuento de reservas entre `billiard_tables.orders` y `temp_reservations`. Ahora las mesas usan `billiard_tables.orders` como fuente de verdad y Venta Rápida usa `temp_reservations`.
- **Productos con presentación caja:** `piecesPerUnit` ahora default 0. El stock de cajas se calcula siempre desde el stock de piezas del padre. Al vender una caja se descuentan `piecesPerUnit` piezas del padre.
- **ProductSaleCard:** ahora muestra stock en formato cajas/piezas y respeta el stock disponible.
- **Botón GUARDAR en Configuración:** ya aparece en Negocio e Impresión en celular y Windows.
- **Banner de iniciar tiempo:** funciona correctamente.
- **Realtime de mesas:** queda como feature futuro documentado.

### Instrucciones para probar ahora
1. **Compilar e instalar el APK en el celular:**
   ```bash
   flutter build apk --release
   ```
   El APK queda en:
   ```
   build\app\outputs\flutter-apk\app-release.apk
   ```
   Pásalo al celular e instálalo.

2. **Borrar datos locales del exe** (si no pide login):
   ```cmd
   rmdir /s /q "%USERPROFILE%\Documents\BaumarSolutions"
   rmdir /s /q "%USERPROFILE%\AppData\Roaming\com.example\app_integral_complete"
   rmdir /s /q "%USERPROFILE%\AppData\Local\com.example\app_integral_complete"
   ```

3. **Compilar el exe:**
   ```bash
   flutter build windows --release
   ```

4. **Abrir celular primero:**
   - Inicia sesión.
   - Ve a Configuración → Negocio.
   - Selecciona una imagen de logo.
   - Presiona GUARDAR.
   - Observa si aparece el logo en el header al volver al Home.

5. **Abrir el exe:**
   - Inicia sesión con el mismo usuario.
   - Observa si el logo aparece en el header del Home (NO en el splash, ese es de la app principal).

6. **Cambiar logo en un dispositivo y verificar en el otro:**
   - Con ambas apps abiertas, cambia el logo en el celular y guarda.
   - Revisa que en el exe se actualice el header en pocos segundos (Realtime).
   - Si no se actualiza, copia los logs de ambas apps.

### Qué esperamos ver en los logs
- `[ConfigPage] Logo subido. URL: https://...` — confirma que la imagen subió.
- `[ConfigPage] Guardado logoUrl: https://...` — confirma que se guardó local y remoto.
- `[HomeHeader] logoUrl: "https://..."` — confirma que el header recibe la URL.
- `[HomeHeader] Error cargando imagen de logo: ...` — si falla la carga.
- `[HomePage] Realtime cambio en billar_settings: {...}` — si llega el cambio en tiempo real.

### Si los logs muestran que la URL está vacía
- Revisar en Supabase Storage → bucket `product_images` → carpeta `logos`.
- Verificar que el bucket sea público.
- Probar la URL en navegador.

### Nota de cierre de sesión
- Código subido a Git en commit `a22e8f2`.
- La app queda en estado funcional. Los cambios de hoy corrigen flujos críticos (stock, logo, guardar, banner).
- La línea de trabajo de aquí en adelante es **seguir hacia adelante**, no regresar a rehacer lo mismo.
- Próxima sesión: continuar con pruebas de stock y avanzar a módulo de Informes una vez validado.

### Palabra clave para retomar mañana
**"RETOMAMOS STOCK"**

---

## Sesión 2026-08-08 — Fix stock fantasma en Mesas de Billar

### Problema reportado
Producto con 10 pz, sin presentación caja:
1. Al abrir una mesa de billar, el stock se mostraba como 9 pz sin haber agregado nada.
2. Al ir a Venta Rápida, agregar 2 pz (sin cobrar) y volver a la mesa, el stock marcaba 7 pz.

### Causa raíz
`SaleItemEntity.quantity` tiene valor por defecto `1`. En `_TableDetailPage` se usaba `orElse: () => SaleItemEntity(productName: '', price: 0)` sin forzar `quantity: 0`, por lo que al consultar "¿cuántas piezas de este producto hay en la orden actual?" siempre devolvía 1 para productos que no estaban en la orden.

### Corrección aplicada
Archivo: `lib/features/sales/presentation/pages/billiard_tables_page.dart`
- Se agregó helper `_quantityInOrder(int? productId)` que devuelve 0 cuando el producto no está en la orden.
- Se reemplazaron los tres `firstWhere` manuales por el helper en:
  - `_addProduct` (validación de stock).
  - Filtro de productos visibles.
  - Cálculo de `displayStock` para el badge de stock.

### Verificación
```
dart analyze .
```
Resultado: 0 errores, 0 warnings visibles.

### Pendiente de validación en runtime
- [ ] Producto 10 pz → abrir mesa → debe mostrar 10 pz.
- [ ] Venta Rápida 2 pz sin cobrar → volver a mesa → debe mostrar 8 pz.
- [ ] Agregar 3 pz en mesa → debe reflejar stock disponible correcto para otras mesas/venta rápida.

### Palabra clave para retomar mañana
**"STOCK FANTASMA CORREGIDO"**

---

## Sesión 2026-08-08 — Fix stock fantasma en Mesas de Billar

### Problema reportado
Producto con 10 pz, sin presentación caja:
1. Al abrir una mesa de billar, el stock se mostraba como 9 pz sin haber agregado nada.
2. Al ir a Venta Rápida, agregar 2 pz (sin cobrar) y volver a la mesa, el stock marcaba 7 pz.

### Causa raíz
`SaleItemEntity.quantity` tiene valor por defecto `1`. En `_TableDetailPage` se usaba `orElse: () => SaleItemEntity(productName: '', price: 0)` sin forzar `quantity: 0`, por lo que al consultar "¿cuántas piezas de este producto hay en la orden actual?" siempre devolvía 1 para productos que no estaban en la orden.

### Corrección aplicada
Archivo: `lib/features/sales/presentation/pages/billiard_tables_page.dart`
- Se agregó helper `_quantityInOrder(int? productId)` que devuelve 0 cuando el producto no está en la orden.
- Se reemplazaron los tres `firstWhere` manuales por el helper en:
  - `_addProduct` (validación de stock).
  - Filtro de productos visibles.
  - Cálculo de `displayStock` para el badge de stock.

### Verificación
```
dart analyze .
```
Resultado: 0 errores, 0 warnings visibles.

### Pendiente de validación en runtime
- [ ] Producto 10 pz → abrir mesa → debe mostrar 10 pz.
- [ ] Venta Rápida 2 pz sin cobrar → volver a mesa → debe mostrar 8 pz.
- [ ] Agregar 3 pz en mesa → debe reflejar stock disponible correcto para otras mesas/venta rápida.

### Palabra clave para retomar mañana
**"STOCK FANTASMA CORREGIDO"**

---

## Sesión actual — Stock unificado: doble descuento y botones +/-

### Paso a paso reportado por el usuario
1. Artículo PruebaZ con 10 pz.
2. Mesa 1: selecciona 3 pz.
3. Venta Rápida: ve 7 pz (correcto).
4. VR: selecciona 3 pz → disponible 4 pz (correcto).
5. Sin cobrar, regresa a Mesa: ve 4 pz disponibles. Agrega 2 más → stock disponible muestra 2 pz.
6. Sin cobrar, regresa a VR: **debería tener 2 pz disponibles**, pero el producto desaparece (como si fuera 0).
7. Al cerrar la venta de la Mesa con 5 pz, VR pierde las 3 pz seleccionadas y muestra 5 pz disponibles.

### Causas raíz identificadas
1. **Doble descuento del carrito de VR:** `_salesRepo.getReservedQuantities()` ya incluye las reservas de `temp_reservations` (quick_sale). En `quick_sale_page.dart` se guardaban en `_tableReserved` y luego `_reservedFor()` restaba el carrito otra vez.
2. **Cobro de mesa borra carrito de VR:** `SalesRepository.saveSale()` llamaba `clearQuickSaleReservation()` indiscriminadamente, sin importar si la venta era de mesa o de VR.
3. **Faltan botones +/- en las tarjetas:** `ProductSaleCard.showButtons` estaba en `false`; solo se podía agregar tocando la tarjeta y solo en VR se podía quitar desde el BottomSheet de cobro.

### Correcciones aplicadas
- `lib/features/sales/data/repositories/sales_repository.dart`:
  - `getReservedQuantities()` ahora acepta `excludeSource` y lo reenvía a `StockReservationService`.
  - `saveSale()` solo limpia la reserva de VR cuando `saleType == 'Venta Rápida'`.
- `lib/features/quick_sale/presentation/pages/quick_sale_page.dart`:
  - `_load()` llama `getReservedQuantities(excludeSource: 'quick_sale')` para no contar dos veces el carrito de VR.
  - `ProductSaleCard` se usa con `showButtons: true`.
- `lib/features/sales/presentation/pages/billiard_tables_page.dart`:
  - `ProductSaleCard` se usa con `showButtons: true`.

### Verificación
```
dart analyze .
```
Resultado: 0 errores, 0 warnings visibles.

### Commits
- Commit local: `64b87a1` fix: stock unificado VR/mesas, botones +/- en tarjetas, UI cards.
- **Push a GitHub pendiente:** no hay remoto `origin` configurado en este entorno. El usuario debe proporcionar la URL del repo o configurar el remoto localmente para hacer push.

### Pendiente de validación en runtime
Repetir el paso a paso:
- [ ] Mesa 3 pz → VR muestra 7 pz.
- [ ] VR 3 pz → VR muestra 4 pz disponibles.
- [ ] Mesa +2 pz → VR debe mostrar 2 pz disponibles (producto visible).
- [ ] Cobrar mesa (5 pz) → VR mantiene las 3 pz seleccionadas y muestra 2 pz disponibles.
- [ ] Botones +/- visibles y funcionales en tarjetas de VR y Mesas.
- [ ] Cards de Mesas no se desbordan.
- [ ] Tema rojo: botón más aparece en verde; botón menos en rojo siempre.

### Palabra clave para retomar
**"STOCK UNIFICADO BOTONES"**

---

*Este archivo es solo un resumen de trabajo, no forma parte de la app. Puedes borrarlo cuando termines de revisar.*
