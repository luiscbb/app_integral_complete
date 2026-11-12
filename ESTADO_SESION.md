# Estado de la sesión (para retomar)

## Tipo de juego, cierre Round Robin y vista de posiciones (12/11/26)
- La creación de torneos permite elegir Bola 8, Bola 9 o Bola 10. En Bola 8, el marcador incluye «Bola 8 anticipada del rival» como método de victoria por falta.
- En Round Robin se puede decidir al campeón por la tabla o clasificar solo a los 8 mejores para un sorteo de cuartos de final a eliminación directa; esta fase incluye partida por el tercer lugar.
- La migración remota actualiza a 8 los torneos antiguos que aún no tienen partidas sorteadas y conserva intactos los cuadros ya iniciados.
- La tabla Round Robin tiene vista previa PDF imprimible/compartible, con logo y nombre del billar, nombre del torneo, posiciones, juegos y marcadores por jornada.
- Los importes se presentan en pesos mexicanos (MXN). SQLite migra a v33. La migración de `game_type` y `playoff_qualifiers` se ejecuta independientemente de la de finanzas, corrigiendo bases locales previas sin esas columnas.
- Hay que volver a ejecutar completo `supabase/add_tournaments.sql` para aplicar los campos y restricciones remotos de juego y clasificación, además de las migraciones anteriores.
- Validación: `dart analyze` dirigido sin problemas; pruebas de torneo, certificado, PDF de posiciones y widget aprobadas.
- Si Supabase responde que no existe `game_type`, la migración remota no está aplicada o PostgREST conserva su caché. El script termina solicitando recargar el esquema; volver a ejecutarlo en SQL Editor y esperar a que termine sin error.
- Los campos de bolsa, inscripción, tiempo y premios fijos indican pesos mexicanos con prefijo `$` y sufijo `MXN`; al tocarlos, seleccionan el valor predeterminado completo para reemplazarlo fácilmente.

## Retas y finanzas de torneo (12/11/26)
- PARTIDAS tiene una sola entrada «RETAS / TRAINING». Dentro se elige Training o Reta (1 vs 1), el tipo de juego y se confirma con Iniciar.
- El portal al iniciar sesión como jugador muestra su ficha, acceso a sus partidas y sus estadísticas; no presenta los módulos administrativos.
- Al crear un torneo se puede configurar bolsa garantizada, inscripción por jugador, costo fijo de tiempo por enfrentamiento completado y premios para lugares específicos en porcentaje o monto. La bolsa total suma la garantizada más todas las inscripciones; el porcentaje global no puede pasar de 100%.
- El detalle calcula el total de inscripciones, bolsa, premio estimado por lugar y costo acumulado del tiempo. El tiempo es un cálculo del torneo, no un cargo/venta que se registre en caja.
- SQLite migra a v32. Hay que volver a ejecutar `supabase/add_tournaments.sql` para aplicar los campos financieros y de configuración remotos antes de crear torneos con esta versión.

## Formatos de torneo, marcador y ajuste móvil
- La pestaña Torneos jugados usa tarjetas adaptables y métricas con salto de línea; se corrigió el overflow de 15 px reportado en Android.
- El marcador muestra por separado `SETS 1-0` y `JUEGOS 3-2`, además del conteo individual de cada jugador. Break & Run aparece una sola vez; se sigue leyendo `run_out` guardado anteriormente.
- Se habilitaron calendario Round Robin (cada jornada se identifica como semana) y tabla por victorias, diferencia de juegos y enfrentamiento directo; grupos equilibrados de hasta cuatro (clasifican los dos primeros); rondas suizas automáticas evitando revancha; y doble eliminación con llave de ganadores/perdedores y una sola final, sin reinicio, como eligió el usuario.
- Las jornadas, fases, grupo, sets, partidas y métodos se conservan en el arreglo `matches` ya existente como JSONB en Supabase y JSON en SQLite; cada resultado se guarda al registrarse y se recupera al reabrir el torneo. No se agrega ni modifica una columna SQL, así que no requiere una migración nueva; sigue siendo necesario haber aplicado previamente `supabase/add_tournaments.sql`.
- Pruebas añadidas para calendario Round Robin persistente, clasificación de grupos, emparejamientos suizos sin revancha y doble eliminación con final única.

## Mejora del certificado y estadísticas del jugador
- El certificado del campeón ahora tiene una copa vectorial, marco decorativo, podio, datos del formato, partidas por set y fecha. Usa tipografía Lato con licencia OFL para conservar acentos en español y nombres; se sigue compartiendo como PDF desde la hoja del sistema (incluye WhatsApp si está disponible).
- Las estadísticas suman las partidas individuales puntuadas en torneos: un resultado 3–1 y otro 3–2 representa 9 partidas, 6 victorias y 3 derrotas (66.7% de win rate), no dos enfrentamientos.
- Se muestran los métodos del marcador: juego normal, Golden Break, Break & Run (incluido el valor histórico `run_out`), combinación y por faltas. Se eliminó el tiempo jugado del resumen y se agregó un bloque de win rate junto con foto y handicap en estrellas.
- Validación: análisis dirigido y pruebas de torneo aprobados; se agregó prueba que genera el PDF y verifica su firma. Para que las partidas de torneos persistan/sincronicen en Supabase todavía hace falta ejecutar `supabase/add_tournaments.sql`.

> **12/11/26 — Sets, estadísticas e historial de torneos**

- Los enfrentamientos ahora se configuran como partidas por set (3, 9, 11, 13, 15 o manual) y sets por mayoría (1, 3, 5 o manual impar; predeterminado 1). Ambas opciones quedan bloqueadas al sortear.
- El marcador lleva juegos por set y sets ganados, conserva el método de cada juego y solo permite deshacer el último juego registrado.
- Se añadió el PDF compartible del campeón, listado de torneos finalizados y consulta de torneos/estadísticas del jugador. Las estadísticas del perfil suman los resultados de torneos a las partidas ya guardadas, sin reescribir los datos originales.
- La lista y el detalle del torneo muestran foto, nickname y handicap con estrellas. El término se normalizó a **Break & Run** (limpia la mesa después del saque); la lectura también reconoce el valor histórico `run_out`.
- Migración local SQLite v30: `sets_to_play`. **Pendiente aplicar `supabase/add_tournaments.sql` en Supabase** antes de usar la puntuación nueva; el script no elimina torneos ni inscripciones.
- Validación: `flutter analyze` sin problemas y `flutter test test/tournament_entity_test.dart` aprobado. Windows recibió hot restart; el APK debug se compiló, instaló y abrió en Android (M2004J19C), aunque Android no aparece conectado al Dart Tooling Daemon.
- Actualización posterior: todos los formatos ahora tienen calendario y marcador; Round Robin guarda jornadas semanales, además de tablas para liga y grupos. El certificado se comparte desde la hoja del sistema, donde se puede elegir WhatsApp.

> **12/11/26 — última actualización (cuadro y marcador de eliminación simple implementados; SQL pendiente)**

> Generado automáticamente para poder revisar avances mientras se recargan créditos.
> Todo lo listado abajo ya está en el código (working tree), sin commitear salvo que se indique lo contrario.

## Ajustes de Torneos y Jugadores (12/11/26)
- Torneos: el botón **INSCRIBIR JUGADOR** ahora es la acción principal y ocupa todo el ancho; la inscripción de jugadores de paso también queda explícita.
- Se aclaran los formatos: **Doble eliminación (ronda de perdedores)** y **Round Robin (todos contra todos)**. Round Robin ya existía como Liga; conserva el valor remoto `liga`, sin migración de formato.
- La lista de inscritos muestra el handicap con estrellas en vez de un número. Los jugadores de paso siguen pudiendo seleccionar su handicap visualmente con estrellas.
- Nombres y nicknames de jugadores, nombres de encargados, jugadores de paso y torneos se normalizan a MAYÚSCULAS. Los correos se conservan en minúsculas.
- No se modificaron ni eliminaron datos del negocio. La migración `supabase/add_tournaments.sql` sigue pendiente de ejecutar por separado en Supabase para habilitar persistencia remota.
- Validación técnica: `dart analyze` sobre los archivos Dart modificados no reportó problemas; `flutter test test/tournament_entity_test.dart test/widget_test.dart` pasó; `git diff --check` pasó.
- Se hizo hot restart de las aplicaciones Windows y Android. Android quedó en primer plano. Falta validar visualmente el botón/inscripciones en la pantalla y ejecutar la migración remota antes de probar persistencia con Supabase.

## Cuadro aleatorio y marcador de Torneos (12/11/26)
- El torneo ahora define cuántas partidas ganadas necesita cada jugador: 3, 9, 11, 13, 15 o una cantidad manual de 1 a 99. Se puede ajustar el torneo existente antes de sortear; tras generar el cuadro, el formato y los inscritos quedan bloqueados para protegerlo.
- Al abrir un torneo de eliminación simple se sortea una sola vez el cuadro aleatorio. Se muestran rondas y pases automáticos si hay un número de inscritos que no completa el cuadro; los ganadores avanzan al siguiente enfrentamiento y aparece el campeón al terminar.
- El marcador suma o deshace partidas ganadas individualmente. Cada punto puede registrarse como juego ganado, golden break, run out, combinación o victoria por faltas. Se muestran foto disponible, nickname, handicap en estrellas, contador del enfrentamiento y enfrentamientos ganados en el torneo.
- El sorteo y sus resultados se guardan en la fila del torneo, sincronizados en Supabase y en caché SQLite. SQLite migra de v28 a v29 automáticamente.
- **Acción pendiente en Supabase:** volver a ejecutar `supabase/add_tournaments.sql` para agregar `race_to` y `matches` a `billar_tournaments`. Es idempotente, preserva los torneos e inscripciones existentes y deja el sorteo vacío hasta abrir cada torneo.
- Se confirmó en el dispositivo que la columna remota `matches` aún no existe (`PGRST204`). La pantalla ahora presenta instrucciones para aplicar la migración en vez de dejar el error sin explicar.
- Estado histórico de esa entrega: el cuadro interactivo aplicaba solo a eliminación simple; el alcance fue ampliado en la sección actual de arriba.
- Validación técnica: `dart analyze` sin problemas, pruebas de cuadro aleatorio de 8/pases automáticos aprobadas y `git diff --check` correcto. Windows recibió hot restart y Android recompiló/instaló el APK debug nuevo y quedó en primer plano.
- Pendiente la migración remota y la validación visual/funcional con el torneo de 8 jugadores. No se modificaron ni borraron datos del negocio.

## PRUEBAS DEL MÓDULO DE COMANDAS — LISTO PARA INICIAR (10/11/26)

La pantalla **Comandas** reutiliza las mesas configuradas con tipo `Comanda` y el flujo de productos, reservas, venta y ticket de Mesas de Billar. No cobra tiempo.

### Antes de probar
1. Ejecutar `supabase/add_comandas.sql` en Supabase SQL Editor. Este script prepara `billiard_tables`, sus políticas y Realtime. No borrar ni reiniciar datos existentes.
2. Confirmar en **Ajustes → Billar/Comanda** que haya al menos una mesa de tipo **Comanda**. Crear una si hace falta.
3. Usar una comanda y un producto de prueba de bajo costo con existencia conocida. Abrir la app normalmente en los dispositivos que se van a probar; el hot reload no sustituye la instalación de una migración remota.

### Checklist funcional
- [ ] **Listado:** abrir Comandas y confirmar que aparecen todas las mesas tipo `Comanda` (libres y ocupadas), sin mezclar mesas tipo Billar.
- [ ] **Sin cronómetro:** abrir una comanda libre; confirmar que no aparece ni se solicita iniciar tiempo.
- [ ] **Pedido y apartado local:** agregar productos y cantidades. Confirmar que el pedido y su total quedan guardados al salir y volver a abrir la comanda.
- [ ] **Inventario disponible:** comprobar que Inventario muestra la existencia física menos lo apartado, con la cantidad apartada identificada. La existencia física no se descuenta todavía.
- [ ] **Otros módulos:** intentar agregar ese mismo producto en Venta Rápida o en una mesa; confirmar que el apartado reduce lo disponible y evita exceder existencias.
- [ ] **Edición del pedido:** quitar unidades/productos de la comanda y confirmar que se libera el apartado correspondiente.
- [ ] **Vista previa:** abrir `VER TICKET` antes de cobrar y confirmar productos, cantidades, precios y total.
- [ ] **Cierre y ticket:** cobrar la comanda. Confirmar la vista previa del ticket posterior al cierre, el registro en Historial/Informes, el descuento físico de stock una sola vez y que la comanda quede libre.
- [ ] **Tiempo real (dos dispositivos):** con el SQL ejecutado y ambos dispositivos conectados, abrir/modificar una comanda en uno. Confirmar que el otro refleja el pedido/ocupación y que Inventario/Venta Rápida actualizan sus apartados sin refresco manual.
- [ ] **Sin conexión (opcional):** guardar cambios del pedido sin red; confirmar que permanecen localmente y que se propagan al reconectar. No usar la sincronización offline como prueba de tiempo real.

### Al reportar resultados
Indicar dispositivo (Windows/Android), paso, resultado esperado/obtenido y mensajes relevantes de consola. Si un paso falla, conservar la comanda y los datos de prueba para investigar; no limpiar tablas ni ejecutar scripts de truncado.

### Aclaración de SQL y corrección de carga de configuración (10/11/26)
- Comandas **no crea otra tabla**: comparte `public.billiard_tables` con Billar, usando `table_type = 'Comanda'` y `orders` para el pedido abierto. `supabase/add_comandas.sql` es una migración idempotente para asegurar columnas, políticas e inclusión en Realtime; si eso ya está cubierto por el esquema y `enable_realtime_tables.sql`, no hace falta duplicar tablas.
- Diagnóstico de configuración EXE: los logs de inicio muestran `fetchSettings end, tieneSettings=true` y un `business_name` remoto, así que Windows sí leyó la fila de `billar_settings`. Se encontró que Splash no copiaba a preferencias locales la dirección, teléfonos, eslogan, despedida y redes; por eso podían seguir vacíos/desactualizados al iniciar con sesión ya guardada.
- Corregido en `lib/features/home/presentation/pages/splash_page.dart`: el inicio sincroniza también esos campos y actualiza el contador del ticket si el remoto es mayor. `flutter test --no-pub` pasó. Falta validar en Windows con reinicio completo y comparar Configuración y ticket contra el celular.
- **Corrección de carga de Comandas (10/11/26):** la consulta del listado esperaba el pull de Supabase antes de leer SQLite, dejando el indicador cargando si la red tardaba. Ahora primero muestra las mesas guardadas localmente; el pull remoto corre en segundo plano con límite de 8 segundos. Se evita una carga duplicada al abrir la pantalla y se muestra aviso/reintento si falla la lectura local o la sincronización. `flutter test --no-pub` pasó y `flutter analyze --no-pub` no reportó errores (quedan avisos `info` preexistentes). Validar en el dispositivo donde se creó la comanda y en el otro dispositivo.
- **Logo anterior en ticket del EXE (10/11/26):** causa confirmada en `TicketService`: el PDF/ticket leía primero `logoPath` local y solo usaba `logoUrl` remoto como fallback, al contrario del encabezado, que prioriza la URL compartida. Ahora el ticket descarga primero la URL remota y usa el archivo local solo sin acceso a la URL. Validar imprimiendo/abriendo una vista previa de ticket en EXE tras cambiar el logo desde cualquier dispositivo.
- **Logo anterior en Configuración del EXE (10/11/26):** la vista priorizaba el archivo local aunque ya tuviera una URL remota nueva, y cualquier guardado podía volver a subir ese archivo antiguo. Ahora muestra primero el logo remoto y solo sube el archivo local si el usuario seleccionó uno nuevo. Falta validar en Windows tras un reinicio completo, tanto al abrir Configuración como al guardar otros datos sin cambiar el logo.
- **Seguimiento por logs de Windows:** el arranque sí recibió la URL del logo nuevo, pero después Realtime aplicó un registro con `logo_url` vacío. La causa es que otros guardados de configuración (por ejemplo, tarifa o mesas) omitían el parámetro y el repositorio reemplazaba la URL por una cadena vacía. Ahora una URL omitida no modifica la columna; además, Splash y Realtime conservan la URL local si reciben un campo vacío. La fila remota ya apareció vacía en esos logs, así que, si la copia local también fue sobrescrita, será necesario volver a seleccionar/subir el logo una vez para restaurar la URL compartida.
- **Mesas que reaparecen/no se reflejan al eliminar (10/11/26):** la eliminación física no se podía reintentar sin conexión y el pull nunca quitaba filas locales que ya no existían en Supabase; además, el realtime ignoraba eventos DELETE (sin `newRecord`) y el inicio rellenaba huecos de IDs. La eliminación ahora se propaga como tombstone `is_deleted`, sincroniza entre dispositivos y no reutiliza IDs; el pull también limpia filas locales sincronizadas ausentes de la nube. La base local migra automáticamente a v25. Ejecutar/volver a ejecutar `supabase/add_comandas.sql` en Supabase para agregar `is_deleted` antes de probar. Validar eliminar en Windows y comprobar celular, luego repetir a la inversa y probar reinicio/sin conexión.

## SEGUIMIENTO FASES 0-1 (16/10/26)

### Fase 0 — entorno verificado
- Windows y Android tienen sesión Supabase válida y corresponden al mismo usuario.
- El `billar_id` local de ambos coincide con la única configuración remota: `BILLAR_20261016_103057`.
- DNS y autenticación de Supabase responden. Android está conectado por ADB.

### Fase 1 — cambios locales implementados y validación reportada como completa
- Sync pendiente ahora se programa al arrancar, reanudar la app, iniciar sesión y al recuperar conectividad; quedan reintentos temporizados cuando aún hay registros locales pendientes.
- Las anulaciones de venta y compra usan la cola normal. El push de compras incluye `cancelled`.
- Los productos marcados como pendientes se reintentan; si falta subir una imagen local, el producto permanece pendiente.
- Los retiros refrescan el informe una vez concluido el pull, sin bloquear la carga inicial.
- Venta Rápida usa un `client_id` UUID estable para reintentar sin duplicar filas.
- Migración Supabase `add_pending_sales_client_id.sql` y pasos de validación de Fase 1: el usuario confirma el 16/10 que ya fueron completados.
- SQLite sube a versión 20 para añadir el `client_id` local. La migración se aplica al abrir cada instalación.
- Compilan `flutter build windows --debug` y `flutter build apk --debug`; el test placeholder existente pasa. `flutter analyze lib` no encuentra errores, pero reporta 8 avisos informativos.
- **Validación funcional reportada completa por el usuario:** pruebas solicitadas de colas, anulaciones y reconexión realizadas en ambos dispositivos.
- El producto creado originalmente en Windows que se observó con stock 37 en EXE y 38 en Android ya aparece actualizado correctamente según confirma el usuario el 16/10. No se hizo ajuste manual.

---

## 🟢 ETAPA 4 — INFORME DE UTILIDAD — FIX SYNC RETIROS + FIX OPERACIONES OFFLINE (12/09/26)

### CÓMO RETOMAR
1. Di la palabra clave: **"RETOMAMOS UTILIDAD"**.
2. Leer primero la sección **"🔴 Pendientes de validación"** (abajo). EXE + celular ya deben quedar levantados con `flutter run` al retomar.
3. NO desviarse a otra cosa hasta cerrar la Etapa 4.

### ✅ Validado por el usuario (11/09) — con el código ANTES del fix de sync de retiros
1. **Punto 1 OK:** vender producto → Informes → Utilidad: Ventas, Costo de lo vendido y Utilidad Neta correctos **en ambos dispositivos**.
2. **Punto 4 OK (cross-device de ventas):** vender en un dispositivo → la venta (con su costo) aparece en el otro tras el pull.

### 🔁 Reintentado el 12/09 (con el fix de sync de retiros ya puesto) — SIGUIÓ FALLANDO
3. Retiro registrado en EXE → utilidad de EXE descontó bien, pero **no llegó al celular**.
4. Retiro registrado en celular → **no apareció en EXE**.
5. Caso venta 18 / gasto 8 / anular venta → sigue sin quedar igual en ambos dispositivos (mismo síntoma: el retiro no propaga).

**Diagnóstico de por qué el fix de ayer no fue suficiente:** `pushOutflowToCloud`/`pullOutflowsFromCloud` sí quedaron implementados y enganchados en el ciclo automático de sync (`_syncAllPending`) y en `getCashOutflows`, pero **guardar un retiro nunca disparaba el sync inmediato** (`addCashOutflow` en reports_page.dart no llamaba a `SyncService().schedulePendingSync()`, a diferencia de ventas/compras que sí lo hacen al guardar). El retiro quedaba local esperando el próximo ciclo automático, que no siempre corre a tiempo entre las pruebas.

### 🔧 FIX APLICADO (12/09, working tree, sin commitear) — parte 1: disparo inmediato de sync en retiros
- **`reports_page.dart`** (donde se guarda el retiro con `_reportsRepo.addCashOutflow(...)`): se agregó `SyncService().schedulePendingSync();` justo después de guardar, igual que hacen ventas y compras. Import de `sync_service.dart` agregado.

### ❓ Pendiente de confirmar mañana
- Si con este disparo inmediato el retiro sí sincroniza entre dispositivos. Si sigue sin llegar, revisar en consola (`flutter run` con logs visibles) las líneas `[SyncService] pushOutflowToCloud` / `pullOutflowsFromCloud` para ver el error real de Supabase (puede ser RLS/policy de la tabla `cash_outflows`, o el `billar_id` no coincidiendo entre dispositivos).

### 🔧 FIX APLICADO (12/09, working tree, sin commitear) — parte 2: operaciones no deben trabarse sin conexión
El usuario pidió revisar si guardar/anular puede trabarse sin internet. Se encontraron 3 puntos donde una operación esperaba (`await`) una llamada de red **antes de terminar y devolver el control al usuario**, lo que sin conexión puede demorar la respuesta varios segundos (timeout por defecto del cliente HTTP/Supabase) en vez de fallar rápido:

1. **`purchases_repository.dart` `savePurchase`:** el loop que sincroniza el stock de cada producto a la nube (`_syncProductStockToCloud`) pasó de `await` (bloqueante) a `unawaited(...)` (fire-and-forget). Guardar la compra ya no espera la red.
2. **`purchases_repository.dart` `cancelPurchase`:** mismo cambio en el loop de `_syncProductStockToCloud`, y el `update` de anulación a Supabase también pasó a fire-and-forget (antes estaba en `try/await/catch`, ahora no bloquea la respuesta al usuario; si falla, `schedulePendingSync()` reintenta luego).
3. **`sales_repository.dart` `cancelSale`:** el push de la anulación a Supabase (`_sync.pushSaleToCloud`) pasó de `await` a fire-and-forget con `catchError`. Anular una venta ya no espera la red para devolver el control a la UI.

**Ya estaban bien (no se tocaron):**
- `saveSale` (ventas): guarda local primero, sync es fire-and-forget vía `Timer` (`schedulePendingSync`).
- `addCashOutflow` (retiros): es un `insert` local puro, sin ninguna llamada de red.
- Todos los `pull*FromCloud` en `sync_service.dart`: ya verifican `isOnline` antes de intentar red y no bloquean el flujo del usuario (se llaman con `unawaited(...)` desde las páginas).

`dart analyze lib` → **0 errores** (solo 8 avisos de estilo preexistentes, no relacionados).

**Nota:** `ConnectivityService.isOnline` solo verifica si hay un adaptador de red activo (WiFi/datos), no si hay internet real. Si el WiFi está conectado pero sin salida a internet, las llamadas fire-and-forget de arriba pueden demorar más (timeout del SDK) antes de fallar en el catch — pero como ya no son bloqueantes, esto no traba al usuario, solo tarda en el background.

### 🔴 PENDIENTES DE VALIDACIÓN (mañana, con reinicio COMPLETO en ambos, no hot reload)
1. **Retiro EXE → celular:** registrar retiro/gasto en EXE → abrir Utilidad en el celular → debe aparecer en el desglose por concepto y bajar la utilidad.
2. **Retiro celular → EXE:** registrar retiro en el celular → verificar en EXE (Utilidad y Caja).
3. **Anulación consistente:** repetir el caso: venta 18, gasto 8, anular venta → utilidad debe quedar **igual en ambos dispositivos**.
4. **Offline — guardar compra:** con WiFi apagado en un dispositivo, registrar una compra → debe guardarse de inmediato sin demora perceptible; al reconectar, el stock debe subir solo a la nube.
5. **Offline — anular venta/compra:** con WiFi apagado, anular una venta o compra → debe responder de inmediato (sin esperar varios segundos); al reconectar, la anulación debe llegar al otro dispositivo.
6. **Offline — PDF/ticket:** con WiFi apagado, generar cualquier ticket/PDF con logo → debe salir en segundos sin logo (no trabarse).
7. Si todo pasa → commit + cierre de Etapa 4.

### ⚠️ Limitación conocida (avisar al usuario al validar)
- Las ventas hechas **antes** de esta migración tienen `cost_at_sale = 0` → no aportan costo histórico (su utilidad individual sale inflada). Solo ventas nuevas desde hoy guardan costo. **Opcional futuro:** retro-llenar costos viejos con el costo actual del producto (estimación).

### ▶️ AGENDADO DESPUÉS DE ETAPA 4 (en orden, no desviarse antes)
1. **Realtime de `products`** (o pull periódico) para stock en vivo entre dispositivos — detalle en la sección de la Etapa 3 (canal `public:products` filtrado por `billar_id` + recarga en Inventario/Venta Rápida/Mesas; el patrón ya existe en home_page/billiard_tables_page).
2. **Fase 3 — Kardex sincronizado a Supabase:** implementación y builds release listos; falta ejecutar `supabase/sync_inventory_movements.sql` y validar online/offline en ambos dispositivos.
3. Reversión automática de mesas anuladas — mejora futura documentada.

### Estado Git
- Etapa 3 cerrada y commiteada (`cf3fff2`).
- **Working tree actual SIN commitear:** toda la Etapa 4 (database_helper, sales_repository, sync_service, reports_repository, reports_page, purchases_repository, sales_history_page, ticket_service, purchases_page) + fix sync de retiros + fix operaciones offline + `supabase/add_cost_at_sale.sql` (ya ejecutado en la nube) + este `ESTADO_SESION.md`.

### Sesión 12/09 — apps levantadas
- **EXE (Windows)** y **celular (0118caba0507)** relanzados con `flutter run` con TODOS los fixes de hoy cargados (reinicio completo). Sesión activa y Realtime suscrito en ambos. Listos para validar mañana.

### Palabra clave para retomar
**"RETOMAMOS UTILIDAD"**

---

## 🚀 ETAPA 3 — CERRADA (referencia histórica)

1. Al volver, di la **palabra clave**: `"RETOMAMOS ANULACIONES"`.
2. El asistente debe leer **primero** la sección **"🔴 ETAPA 3 — PENDIENTES (continuar aquí)"** (abajo) y continuar EXACTAMENTE donde quedó, sin desviarse hasta que el usuario lo confirme (regla de no desvío).
3. Después leer **"ESTADO ACTUAL — RESUMEN CLARO"** solo para confirmar lo ya validado.
4. **NO** re-revisar ni re-hacer nada de lo que ya dice "COMMITEADO", "hecho" o "VALIDADO".

---

## 🟡 ETAPA 3 — ANULACIONES CON PIN (06/09/26) — ESTADO Y PENDIENTES

### ✅ Implementado y VALIDADO en runtime (no re-hacer)
1. **PIN de autorización en Configuración** (4 dígitos + RESET). Guardado verificado por log (`[ConfigPage] PIN guardado en prefs: (configurado)`). Reglas de autorización validadas por el usuario: Administrador anula sin PIN; otro usuario CON PIN debe ingresarlo; SIN PIN se permite con aviso.
2. **Fix botón GUARDAR de Configuración:** el botón grande fijo de abajo llamaba `_save` vía GlobalKey y fallaba en silencio → se eliminó; queda el botón de disquete de la sección Negocio.
3. **Anular VENTA + ticket en Historial** (`sales_history_page.dart`): botón rojo + ticket "VENTA ANULADA" (formato caja, vista previa, imprimir/compartir). Detalle cambiado a diálogo centrado (el bottom sheet se cortaba con la ventana del EXE fuera de pantalla).
4. **Anular VENTA + ticket en Informes→Ventas** (`reports_page.dart`: `_cancelSaleFromReports` + `_showCancelSalePdf`).
5. **Anular COMPRA en Historial de compras** (`purchases_page.dart` `_cancelPurchase`): descuenta stock que la compra sumó (inversa de cajas/paquetes, sin stock negativo), kardex 'cancel', anulación lógica (`cancelled=1` en compras y detalles, DB v18), push a Supabase por cloud_id. **Validado por el usuario en ambos dispositivos.**
6. **Ticket COMPRA ANULADA en EXE:** validado. Ticket "VENTA ANULADA" en EXE: validado.
7. **Compras anuladas excluidas** de Informes/Caja (`getHistory`, `getPurchasesByDateRange`, `getPurchasesByDateRangeCashOnly` filtran `cancelled = 0`).
8. **Pull de nube arreglado:** se quitó el filtro por fecha (se saltaba ventas de otro dispositivo con reloj atrás); dedupe por cloud_id; el pull de compras ya propaga anulaciones del otro dispositivo. Pull conectado a auto-sync y a la apertura de historial/informes.
9. `supabase/add_sale_cancelled.sql` **ejecutado** por el usuario. `dart analyze lib` → 0 errores.

### 🔴 PENDIENTES (continuar aquí mañana, en orden)
1. ✅ **FIX aplicado (07/09):** `pullSalesFromCloud` ahora propaga `cancelled` de la nube a ventas ya existentes localmente (patrón del pull de compras). Era la causa de "ventas anuladas visibles en el celular".
2. ✅ **FIX aplicado (07/09):** ticket de compra en el celular — causa: `onPurchaseCancelled` (setState del padre) corría ANTES del PDF y desmontaba el context. Ahora el ticket va primero, después la recarga (`purchases_page.dart`).
3. ✅ **IMPLEMENTADO (07/09):** anular COMPRA desde Informes→Compras (`reports_page.dart`: `_cancelPurchaseFromReports` + `_showCancelPurchasePdf`) — botón rojo en el detalle + ticket, misma autorización por PIN.
4. ✅ **SQL ejecutados por el usuario (07/09):** `add_sale_cancelled.sql` y `add_purchase_cancelled.sql`.
5. ✅ **RESET DE DATOS hecho (07/09):** TRUNCATE de ventas/compras en Supabase (hecho por el usuario) + BD local del EXE eliminada (`Documents\BaumarSolutions\database\integral_pos_v1.db`) + `pm clear` en el celular. Se conservaron: usuario, config del negocio, productos, proveedores, conceptos. PIN local se perdió con el reset → reconfigurar en Fase 1.
6. ⬜ **FASE 1 — VALIDACIÓN PASO A PASO (con datos limpios):**
   1. Configurar PIN en Configuración (se borró con el reset local).
   2. Venta rápida en EXE → stock baja.
   3. Anular esa venta (Administrador) → ticket VENTA ANULADA + stock regresa + desaparece de Informes/Caja.
   4. En el celular → la venta anulada NO debe aparecer (sync).
   5. Cambiar nombre de usuario → anular otra venta → debe pedir PIN.
   6. Compra en EXE → stock sube → anular desde Historial → stock baja + ticket COMPRA ANULADA.
   7. Anular otra compra desde Informes→Compras (botón nuevo).
   8. Cross-device: anular venta desde el celular → desaparece en EXE.
7. ✅ **FASE 2 — CIERRE COMPLETADO (07/09):** Fase 1 validada por el usuario (pasos 1-5 ✅; nota: stock/anulaciones se ven en el otro dispositivo tras refrescar manual — comportamiento conocido y aceptado). Commit `cf3fff2` de toda la Etapa 3. Logs temporales eliminados. **Etapa 3 CERRADA.**
   - Mejora pendiente menor: unificar vista previa de compra en el celular (hecho: PDF de compras ahora usa vista previa en app en ambas plataformas, incluido en el commit).

### 📌 ACLARACIÓN — Tiempo real de STOCK entre módulos y dispositivos (revisado 07/09, cierre Etapa 3)
- **Lo que YA existe y fue validado antes:** el stock es **unificado** entre Venta Rápida ↔ Mesas ↔ Inventario (mismo inventario, sin doble descuento). Y el stock se **sincroniza entre dispositivos** (fix del `product_repository`: al descargar productos de la nube sí se actualiza stock, validado en su momento). El usuario lo confirmó en la Fase 1: vender en EXE baja stock y el celular lo refleja (al refrescar).
- **Lo que NO existe:** Realtime de la tabla `products` para stock. Hoy solo hay Realtime en: `billar_settings` (imagen/negocio tipo WhatsApp — ese sí es instantáneo), `billiard_tables` (mesas) y `providers`/`purchases` (compras). Por eso el stock en el otro dispositivo se ve **al refrescar la pantalla**, no al instante.
- **⚠️ AGENDADO (nueva tarea, no bloquea Etapa 4):** Realtime de `products` (o pull periódico de stock) para que el stock cambie en vivo entre módulos y dispositivos, al estilo del cambio de imagen del negocio. Requiere: canal `public:products` filtrado por `billar_id` + recarga de la lista en Inventario/Venta Rápida/Mesas al recibir evento. Esfuerzo: moderado-bajo (el patrón ya existe en home_page/billiard_tables_page).
- **Nota de la validación Fase 1:** el usuario observó "stock no actualiza en celular en tiempo real" y anulaciones visibles solo tras refresh manual → exactamente esta limitación, no un bug de la Etapa 3.

### ▶️ SIGUIENTE ETAPA PROPUESTA — Etapa 4: Informe de UTILIDAD (opción A elegida, pendiente de arrancar)
- Nueva pestaña "Utilidad" en Informes con rango de fechas: Ventas − Costo de lo vendido − Retiros/Gastos = UTILIDAD NETA, con desglose de gastos por concepto.
- Requiere migración (DB v19): guardar el costo del producto al momento de vender en `sale_details` (columna `cost_at_sale`) para costo histórico real.
- Las compras NO se restan directo (son inventario/activo); solo el costo de lo vendido y los gastos de caja impactan utilidad.
- Opcional después: exportar PDF del mes (opción C).

### ▶️ CÓMO VALIDAR LA FASE 1 (checklist para el usuario, con EXE levantado por el asistente)
> EXE levantado y con BD limpia. El celular se conecta con `flutter run -d 0118caba0507` cuando el usuario lo enchufe (pedirá login porque se le borraron los datos con `pm clear`).

1. **PIN** → Configuración → Negocio → PIN de 4 dígitos → GUARDAR (botón disquete) → snackbar verde + regresa al Home. Verificar que al volver sigue.
2. **Venta + stock** → Venta Rápida: vende un producto con stock → verificar en Inventario que el stock bajó.
3. **Anular venta (Administrador)** → Informes → pestaña Ventas (o Historial, icono de historial arriba) → toca la venta → ANULAR VENTA → confirmar → **ticket "VENTA ANULADA"** con imprimir/compartir → verificar: stock devuelto en Inventario + venta fuera de Informes/Caja.
4. **Sync al celular** → conectar celular + `flutter run -d 0118caba0507` → login → la venta anulada NO debe aparecer en Informes/Historial del celular.
5. **PIN para no-admin** → Configuración → cambiar "Nombre del cajero" a otro nombre (≠ administrador) → GUARDAR → anular otra venta → debe PEDIR el PIN → ingresarlo → anula.
6. **Compra + stock** → Compras → registrar compra de un producto → stock sube.
7. **Anular compra (Historial)** → Compras → Historial → toca la compra → ANULAR COMPRA → confirmar → ticket "COMPRA ANULADA" + stock descontado + desaparece de Informes/Caja.
8. **Anular compra (Informes)** → Informes → pestaña Compras → toca una compra → botón rojo ANULAR COMPRA (nuevo) → ticket + stock descontado.
9. **Cross-device** → anular una venta desde el CELULAR → verificar que en el EXE desaparece al entrar/salir de Informes (y viceversa).

> Si TODOS pasan → avisar al asistente para Fase 2 (commit + limpieza de logs + cierre de Etapa 3). Si alguno falla → anotar cuál y qué se vio en pantalla.

### 📌 Nota Kardex (pendiente futuro, preguntado por el usuario)
El usuario quiere el **Kardex sincronizado a Supabase** (revisar movimientos remoto). Hoy es solo local. No es bloqueante de la Etapa 3; se puede hacer: tabla `inventory_movements` en Supabase + push en `recordInventoryMovement` + pull en la consulta. Es trabajo moderado, decidir cuándo agendarlo (no depende de roles de usuario para funcionar; los roles solo controlarían quién puede verlo).

### Estado Git
- Último commit: `cf3fff2` — feat: Etapa 3 completa (anulaciones con PIN, tickets, sync). Etapa 3 **CERRADA y commiteada**.

### Palabra clave para retomar
**"RETOMAMOS ANULACIONES"**

---

## 🗂️ HISTORIAL — SESIONES ANTERIORES (etapas de corte de caja, ya cerradas)

### ✅ VALIDADO EN RUNTIME (celular + exe) — no tocar, no re-hacer
1. **Mesas de billar — cronómetro/tiempo:** banner + diálogo de iniciar tiempo funcionan correctamente. Sincronización Realtime de mesas confirmada (ocupar/editar/liberar se refleja al instante entre celular y exe).
2. **Stock unificado (Venta Rápida ↔ Mesas):** mismas existencias en ambos módulos y en ambos dispositivos (app y exe). Doble descuento corregido. Confirmado por el usuario.
3. **Historial de compras entre dispositivos:** el historial descarga las compras remotas al entrar a la pantalla (`getHistory` → `pullPurchasesFromCloud`) y además hay Realtime (`providers`/`purchases`) para el dispositivo que NO generó el cambio, que lo recibe sin recargar.
   - **Aclaración validada:** el dispositivo que **registra** la compra no recibe su propio evento Realtime (comportamiento normal de Supabase), por eso ese mismo dispositivo solo se refresca al salir/entrar de la pantalla de Compras. El otro dispositivo sí lo ve reflejado sin recargar.
   - **Decisión del usuario:** este comportamiento es **suficiente**, no se requiere tiempo real perfecto para historial (es pantalla de consulta, no operación en vivo). **Cerrado, sin acción pendiente.**
4. **Usuario logueado (`created_by`) + botón REIMPRIMIR PDF** en historial de compras — commiteado y pusheado.
5. **PDF/historial de compras** (fix de transacción que impedía guardar) — commiteado y pusheado, encabezado unificado con el de ventas.
6. **Proveedores con `billar_id` correcto** — commiteado y pusheado.
7. **Origen del dinero en compras (Caja/Cajero/Transferencia/Tarjeta):** selector en el formulario de nueva compra, visible en PDF y en detalle de historial (incluye reimpresión). Validado en runtime por el usuario. El efecto en el corte de caja ya se validó: solo resta del efectivo esperado las compras con `cash_source = 'caja'`.
8. **Fix: stock no se sincronizaba entre dispositivos.** Causa: `product_repository.dart` tenía la regla "NUNCA actualizar stock" al descargar productos existentes de la nube, así que una compra hecha en un dispositivo no se reflejaba en el otro. Corregido: ahora sí se actualiza el stock al descargar, salvo que el producto tenga cambios locales aún sin subir (`synced = 0`), para no pisar una venta/compra offline. **Validado por el usuario:** tras reiniciar por completo (F5) ambos dispositivos, el stock ya se refleja correctamente.
9. **Icono/color por origen del dinero en la lista de historial de compras:** cada compra muestra un icono distinto (caja/persona/transferencia/tarjeta) sin necesidad de abrir el detalle.

### 📌 DECISIONES DE DISEÑO — Compras vs Informes
- **Filtro por rango de fechas de compras:** se hará en **Informes**, no en Compras. Compras es operativo (lista reciente + `LIMIT 100`, ya suficiente); Informes es analítico y ya tiene `getPurchasesByDateRange` para eso. No duplicar la lógica en dos pantallas.
- **Apartado de Compras: se considera completo** para pasar directo a Informes (proveedores, carrito, PDF, historial, origen del dinero, sync entre dispositivos, distinción visual por origen). No se identificó nada estructural faltante.

### 📌 DECISIÓN DE DISEÑO — Ubicación del CORTE DE CAJA
- El **corte de caja va DENTRO de Informes**, en la pestaña **"Caja"** (no como tarjeta nueva en el home). `ReportsPage` ya tiene 4 pestañas (Ventas/Compras/Caja/Kardex) y ya carga `getCashFlowSummary`; el corte es una operación sobre la caja, así que vive ahí. En la pestaña Caja quedará: resumen de flujo de caja + botones ABRIR TURNO / CORTE PARCIAL / CORTE TOTAL + ticket de corte (patrón de PDF/ticket ya usado en ventas y compras). Opcional a futuro: atajo en el home hacia esa misma pestaña.
- **Trazabilidad entre cajeros (entrega/recepción de efectivo) visible desde la primera versión:** aunque los roles/login formales con contraseña se dejan para más adelante (eso sí involucra `auth` y es un paso mayor), la pantalla de caja mostrará desde el inicio **quién abrió la caja y con cuánto** (`created_by` + `opening_amount`) y **quién la cierra y con cuánto** (`closed_by` + `closing_amount`). La base ya lo soporta (`cashier_sessions`), solo hay que hacerlo visible. El "usuario/cajero" por ahora será un campo simple (nombre), no un sistema de cuentas. Esto evita rehacer la trazabilidad cuando lleguen los roles formales.

### ✅ CORTE DE CAJA — IMPLEMENTADO y PROBADO en runtime (pestaña "Caja" de Informes)
- **Implementado** en `lib/features/reports/presentation/pages/reports_page.dart`: ABRIR TURNO, CORTE PARCIAL, CORTE TOTAL, ticket de corte (PDF), sección visible de entrega/recepción entre cajeros, y resumen de flujo de caja (ventas, compras de caja, retiros/gastos, efectivo esperado).
- **Corte total** filtra correctamente: solo resta compras con `cash_source = 'caja'` (las de cajero/transferencia/tarjeta no afectan el efectivo esperado). Validado en runtime.
- **Correcciones aplicadas en esta ronda (tras la prueba del usuario):**
  1. **Corte PARCIAL ahora SÍ genera ticket** (antes no salía). Tras guardar el corte parcial, muestra el comprobante con el monto retirado.
  2. **El ticket de corte (parcial y total) ahora se muestra como VISTA PREVIA dentro de la app** (bottom sheet con `PdfPreview` + botones imprimir/compartir/cerrar), igual que venta rápida — ya NO abre el diálogo de impresión del sistema (`Printing.layoutPdf` directo).
  3. El PDF del corte parcial muestra "Retiro parcial" y omite "Cerró"/"Efectivo contado"/"Diferencia" (que solo aplican al total).
- `dart analyze lib` → **0 errores** (solo avisos `info` de estilo preexistentes, no bloqueantes).
- **Hallazgos de la prueba en runtime del usuario (para referencia):** el primer render del PDF del corte parcial fue lento (carga inicial del logo/formato) pero los siguientes fueron rápidos; no es bug de formato.

### 🔜 SIGUIENTE — Plan de trabajo de mañana (fraccionado, pendiente de validar)
El usuario pidió dejar esto fraccionado en etapas y que se le indique cómo ir validando cada una. **Orden sugerido de etapas:**

- **Etapa 1 (sin tabla nueva ni script SQL):**
  - (B) Comprobante PDF para cada RETIRO/GASTO (hoy el retiro NO genera comprobante — punto 10 de la prueba).
  - (C) Comprobante al ABRIR TURNO (para que el cajero sepa cuánto recibe) — punto 4.
  - (D) Formato MONEDA en montos donde se requiera ($ con separador de miles) — punto 1.
  - (E) Mostrar "total en caja actual" en pantalla y ticket — punto 8.
- **Etapa 2 (requiere tabla nueva + script SQL Supabase):**
  - (A) Catálogo de CONCEPTOS de retiro/gasto (como las categorías de inventario), guardados en Supabase, con crear/editar. Al registrar un retiro se elige un concepto del catálogo. **Sin contraseña** (decisión del usuario). Puntos 1/9.
- **Etapa 3 (implementar en la próxima sesión):**
  - Contraseña de autorización para CANCELACIÓN de VENTAS (no para retiros — decisión del usuario, punto 3). Alcance ya decidido — ver detalle en "🗂️ PROGRESO POR ETAPAS".

### 🗂️ PROGRESO POR ETAPAS (LEER ESTO PRIMERO AL RETOMAR) — REGLA DE NO DESVÍO
> **Regla acordada con el usuario:** se avanza por etapas en orden, UNA a la vez. Al terminar la etapa en curso, **PARAR y reportar**. NO iniciar la siguiente etapa (ni desviarse a otra cosa) hasta que el usuario lo confirme explícitamente. No saltarse etapas.

- **Etapa 1 — Comprobante retiro + comprobante apertura + formato moneda + total en caja:** `✅ implementada y validada en runtime`
  - B) Comprobante PDF para cada retiro/gasto — implementado (vista previa + imprimir/compartir).
  - C) Comprobante al abrir turno (monto inicial + quién recibe) — implementado.
  - D) Formato moneda ($ con separador de miles) — implementado vía helper `_fmt()` en pestaña Caja y PDFs.
  - E) Mostrar "total en caja actual" en pantalla y ticket — implementado (tarjeta + línea en ticket).
  - **Fix aplicado:** el retiro NO descontaba del total en caja. Causa: `addCashOutflow` no fijaba `created_at` (default de SQLite con espacio+UTC), así que el filtro por rango de fechas (que usa formato ISO con 'T') no lo encontraba. Corregido: `addCashOutflow` ahora fija `created_at` con `DateTime.now().toIso8601String()`. **Validado:** abrir turno 200 → retiro 100 → "total en caja" marca 100.
  - **Fix aplicado:** el retiro exigía descripción para guardar. Corregido: ahora solo basta el concepto y el monto; la descripción es opcional.
  - **Validado en runtime por el usuario:** el retiro ya muestra la info correcta (descuenta del total en caja).
- **Etapa 2 — Catálogo de conceptos de retiro/gasto (tabla Supabase):** `✅ implementada, SQL ejecutado y VALIDADA en runtime por el usuario` ("Informes → Caja: validado ok todo", "Registrar retiro/gasto ya funciona correctamente")
  - A) Catálogo de conceptos como las categorías de inventario, guardado en Supabase, con crear/renombrar/eliminar. Al registrar retiro se elige concepto del catálogo (dropdown + botón + para agregar). Sin contraseña.
  - **SQL `supabase/add_cash_outflow_concepts.sql` ya ejecutado en Supabase por el usuario.**
  - Implementación: tabla local `cash_outflow_concepts` (DB version 16) + métodos `getConcepts/addConcept/renameConcept/deleteConcept` con sync por upsert `(billar_id, name)` en `reports_repository.dart` + botón "CONCEPTOS (catalogo)" y gestor (crear/renombrar/eliminar) en la pestaña Caja de `reports_page.dart`. La tabla local SÍ tiene respaldo en Supabase (sube/descarga conceptos, compartidos por `billar_id`).
  - **Fix aplicado:** los campos de crear/renombrar concepto solo dejaban escribir una letra. Causa: `onChanged: (v) => ctrl.text = v.toUpperCase()` reescribía el texto y rompía la composición del teclado. Corregido: se usa `TextInputFormatter.withFunction` para poner en mayúsculas sin romper la escritura.
  - **Fix aplicado:** el botón GUARDAR no daba feedback si faltaba el monto/concepto. Corregido: ahora muestra aviso "Ingresa un monto válido mayor a 0" o "Selecciona un concepto".
  - *Validación restante:* reinicio completo del EXE → Informes → Caja → "CONCEPTOS (catálogo)" (crear/renombrar/eliminar) → registrar retiro con descripción de varias palabras → GUARDAR → comprobante + descuento del "total en caja".
- **Etapa 3 — Contraseña cancelación ventas/mesas:** `🟡 alcance decidido, implementar en la próxima sesión`
  - **Investigación ya hecha (evidencia en código):** la cancelación NO existe en ningún lado. El detalle de venta en `sales_history_page.dart` (modal ~línea 445) es de solo lectura, solo tiene "REIMPRIMIR/REENVIAR TICKET" (~líneas 526-548). `SalesRepository` NO tiene delete/cancel sobre `sales_history`/`sale_details`. El cobro de mesa `_checkout()` en `billiard_tables_page.dart` (~líneas 801-972) es irreversible (guarda venta → descuenta stock → `freeTable` borra orders). NO existe ningún sistema de PIN/contraseña de autorización en la app (crear desde cero; candidato: `PreferencesService`).
  - **Alcance acordado con el usuario:**
    1. Contraseña de autorización: diálogo PIN configurable en Configuración, guardada en `PreferencesService`.
    2. Botón "ANULAR VENTA" en el detalle del Historial de ventas → pide contraseña → **DEVUELVE el stock** (crear `ProductRepository.increaseStock`, no existe) → anula la venta (debe salir de informes y del flujo de caja del corte).
    3. **Mesas: FUERA del alcance automático.** Revertir mesa cobrada es complejo (el tiempo jugado no es producto, y la mesa ya quedó liberada con orders borrados). Flujo manual acordado: anular la venta errónea en Historial + volver a cobrar la mesa. Reversión automática de mesa queda documentada como mejora futura.
    - Motivación del usuario: corregir ventas cerradas por error anulándolas y volviendo a vender bien (Venta Rápida o mesas).
  - *Validación:* vender algo → anular en Historial con contraseña → verificar stock devuelto, venta fuera de informes y total en caja reintegrado → registrar la venta correcta.

### ▶️ PRÓXIMO PASO INMEDIATO (implementar Etapa 3)
- Implementar el alcance acordado de la **Etapa 3** (arriba): PIN en Configuración + "ANULAR VENTA" en Historial con devolución de stock.
- Al terminar: correr `dart analyze lib`, reportar al usuario, y **ESPERAR su validación en runtime** antes de dar por cerrada la Etapa 3.

### 📌 DECISIONES DE DISEÑO — Corte de caja (confirmadas en esta ronda)
- Los **RETIROS/GASTOS no llevan contraseña** (decisión del usuario).
- La **contraseña de autorización se reserva para cancelar VENTAS/MESAS** (deshacer un ingreso registrado es lo crítico), no para retiros. Queda como pendiente futuro (Etapa 3).
- La **caja física se maneja en el EXE como "caja principal"** (un solo dispositivo hace apertura/cierre). `cashier_sessions` NO se sincroniza a la nube por ahora (riesgo de conflicto de "caja única"); se documenta como limitación. El celular muestra la pestaña "Caja" pero el turno es local de cada dispositivo.
- Trazabilidad entre cajeros: la pantalla muestra quién abrió y con cuánto (`created_by` + `opening_amount`) y quién cierra y con cuánto (`closed_by` + `closing_amount`). El "cajero" es un campo simple (nombre), no un sistema de cuentas (roles formales quedan para fase futura).

### Estado Git
- Último commit: `4283e85` — docs decisión ubicación corte de caja + trazabilidad entre cajeros. **Pusheado.**
- Cambios de esta sesión (origen del dinero + fix de stock + corte de caja + Etapa 1 completa + Etapa 2 catálogo de conceptos + fixes de formato de fecha/descripción/campos de texto) **aún sin commitear**.
- Working tree de código limpio salvo lo anterior. Solo quedan archivos de diagnóstico sueltos en la raíz (`an.txt`, `full.txt`, `analyze_full_out.txt`, `anerr.txt`, `fullerr.txt`, `verify_analyze.txt`, `analyze_out.txt`) que son residuos, no parte de la app.
- `dart analyze lib` → **0 errores** (avisos `info` de estilo preexistentes en `lib/features/reports/...`, no bloqueantes).
- Scripts SQL ya ejecutados en Supabase por el usuario, sin problemas: `add_purchase_cash_source.sql` y `add_cash_outflow_concepts.sql`.

### Lo que NO hay que hacer (para no gastar saldo de más)
- ❌ NO re-ejecutar los scripts SQL de Realtime ni el de `add_purchase_cash_source.sql` ni el de `add_cash_outflow_concepts.sql` (ya ejecutados, funcionan).
- ❌ NO re-revisar bugs ya corregidos y validados (ver lista arriba).
- ❌ NO re-hacer los cambios de compras/origen del dinero/stock/corte de caja ya implementados.
- ❌ NO pedir tiempo real perfecto en historial de compras (decisión ya tomada: no es necesario).
- ❌ NO usar hot reload para probar cambios de repositorios/base de datos/sync — siempre reiniciar completo (F5 / hot restart) en ambos dispositivos.
- ❌ NO implementar contraseña en retiros/gastos (decisión tomada: solo para cancelar ventas/mesas, Etapa 3).

### Palabra clave anterior (ya cerrada)
~~"RETOMAMOS CORTE DE CAJA"~~ → etapas 1 y 2 del corte de caja validadas y cerradas; Etapa 3 en curso (ver arriba).

> Al retomar mañana: leer primero la sección **"🗂️ PROGRESO POR ETAPAS"** (continuar exactamente la etapa en curso, regla de NO desvío) y luego "ESTADO ACTUAL — RESUMEN CLARO". Las 3 etapas: 1) comprobante retiro + comprobante apertura + formato moneda + total en caja — **implementada y validada**; 2) catálogo de conceptos de retiro con tabla Supabase — **implementada, SQL ejecutado y validada**; 3) contraseña para anular ventas con devolución de stock — **alcance decidido, implementar ahora** (ver detalle en PROGRESO POR ETAPAS). Después de la Etapa 3, evaluar la idea (ya comentada con el usuario) de un proyecto nuevo clon con solo: venta rápida, mesas, inventario, compras, informes, control de caja y configuración — mismo negocio de billar, sin login, con base Supabase nueva y los mismos scripts SQL.

---

## Seguimiento adicional (16/10/26, 12:34)
- Logo de negocio en Android: header ahora muestra un indicador de carga y un fallback visible ante error al descargar la imagen; validar arranque en frío conectado y sin conexión.
- Comprobante de retiro: se acortó/limitó el título y se compactaron los controles de la cabecera de vista previa para mantener visible Cerrar en pantallas estrechas.
- Inicio de tiempo de mesa: el diálogo ahora ofrece CANCELAR a la izquierda; al cancelar, vuelve a la cuadrícula de mesas sin ocuparla. El botón INICIAR de la vista de detalle abre el mismo diálogo de confirmación.
- `flutter build windows --debug`, `flutter build apk --debug` y `flutter test`: correctos. `flutter analyze lib`: cero errores y 8 avisos `info` preexistentes.
- Pendiente: probar logo en arranque frío Android, vista previa del ticket en pantalla estrecha y cancelar inicio de tiempo desde ambas formas de apertura (diálogo automático y botón INICIAR).

## Diagnóstico de demora al iniciar Android (16/10/26, 12:56)
- Los logs muestran `logo_url` remoto con acentos graves antes/después de la URL, lo cual vuelve inválida la URL de descarga. `ConfigRemoteRepository` ahora normaliza espacios y acentos graves al leer y guardar; splash y Realtime también aplican esa normalización.
- El log también muestra el pull de mesas durante el arranque, a la vez que aparece la pantalla inicial. Se quitó el sync inmediato del `initState` global y se programa después de navegar a Home; también se omite el primer evento `resumed` para evitar programar otra carga encima del primer render. Login y reconexiones conservan sus disparadores.
- El logo remoto del header limita la decodificación en memoria a 128x128 px; debe reducir trabajo cuando el archivo original es grande.
- Interpretación: las trazas aportadas confirman pérdida de frames y latencia del hilo de UI/render, pero no incluyen stack de un ANR fatal. No se puede asegurar aún que el logo sea la causa única; reinstalar/abrir el APK nuevo y revisar si vuelven los avisos de MIUI.
- `flutter analyze lib`: cero errores, 8 avisos `info` ya conocidos; `flutter test`: pasa placeholder. Pendiente compilar/validar APK en el Xiaomi y medir nuevo log.
- Nueva captura (13:05): Xiaomi/Android reporta `MainActivity.onCreate took 3269ms`, saltos de 183 frames y latencia MIUI de entrada; no aparece un stack de ANR de Dart ni excepción de la app. Tras la navegación inicial, los pulls de mesas/ventas/etc. se completan.
- Ajuste adicional: ahora `runApp` se llama antes de cargar `.env`, inicializar Supabase y preferencias; una pantalla de bootstrap liviana aparece durante esos awaits. En Splash se quitó la espera fija de 2 s y se inicia la comprobación de sesión después del primer frame.
- APK debug compilado, tests pasan y analyzer conserva los 8 `info`. Esto mejora el tiempo hasta el primer frame Flutter, pero no elimina el coste nativo de `MainActivity` de MIUI ni garantiza que el fabricante deje de mostrar su alerta; probar arranque en frío y comparar con build release si MIUI aún alerta.
- Validación 13:27: se instaló `app-release.apk` sobre la instalación existente vía `adb install -r` (sin borrar datos) y se abrió en el Xiaomi. El usuario confirma que ya no aparece “App no responde”; queda validado el arranque normal en release. No atribuir la solución exclusivamente al cambio de código, porque release y debug difieren en optimización.

## Fase 2 — Realtime de productos e inventario (16/10/26)
- Implementado el canal Realtime compartido, filtrado por `billar_id`, con refresco de Inventario, Venta Rápida y detalle de mesa. El refresco descarga/mergea el estado remoto mediante el repositorio existente, que preserva productos con `synced = 0`.
- `ProductRepository.refreshFromCloud()` hace pull antes de recargar el modelo local; la lectura puede omitir el pull en background para evitar duplicarlo.
- `supabase/enable_realtime_tables.sql` publica `products`, usa `REPLICA IDENTITY FULL` e incluye políticas de borrado para productos y relaciones de promociones. El usuario confirmó ejecutar el SQL en Supabase.
- Se agregó el botón de eliminar en vistas de cuadrícula y lista. Los borrados se guardan en `pending_product_deletions` (SQLite versión 22), se excluyen de pulls mientras esperan red y se empujan al reconectar; también se eliminan las presentaciones de caja y relaciones de promociones.
- Validación funcional con APK/EXE release instalados/abiertos: alta online desde Windows apareció automáticamente en Android; alta y edición online desde Android aparecieron automáticamente en Windows; edición de descripción/precio offline en Android se sincronizó automáticamente a Windows al reconectar; entrada de compra y venta de producto actualizaron el stock automáticamente en el dispositivo opuesto.
- Borrado online desde Windows desapareció automáticamente en Android tras corregir el listener que descartaba DELETE sin `billar_id`; borrado offline en Windows desapareció localmente, permaneció temporalmente en Android y se eliminó automáticamente en Android tras reconectar Windows. Se borró el producto temporal final y el usuario confirmó que desapareció en ambos dispositivos sin actualizar manualmente.
- Se recompilaron APK y EXE release luego del fix de DELETE. Tests, analyzer de archivos tocados y `git diff --check` pasan. Fase 2 validada para alta, edición, stock y borrado online/offline entre los dispositivos probados.
- UI de mesas: el botón CANCELAR del diálogo para iniciar tiempo ahora coincide con el botón elevado de INICIAR TIEMPO, con fondo rojo y sin flecha. APK y EXE release fueron instalados/abiertos el 16/10; el usuario confirmó que la UI quedó correcta.
- Seguimiento de inventario: el usuario confirma que el stock ya aparece actualizado correctamente en ambos dispositivos.

## Fase 3 — Sincronización del Kardex (implementación lista; validación pendiente, 16/10/26)
- Ya existía `inventory_movements` local; los movimientos se registran en ventas, compras y anulaciones, pero aún no estaban sincronizados con Supabase.
- Migraciones SQLite versión 23 y 24 agregan `client_id` estable a movimientos y `products.is_active` para archivar productos. El servicio central hace push idempotente de pendientes y pull paginado; el Kardex conserva el historial y no recalcula ni altera stock.
- La eliminación del producto se cambió por **archivado**: deja de aparecer en el catálogo activo, pero el producto y sus movimientos se conservan para reportes.
- El SQL remoto `supabase/sync_inventory_movements.sql` agrega `client_id` único, permite `cancel` en `movement_type` y cambia `product_id` de int a bigint para soportar IDs grandes usados por productos actuales.
- Validación técnica: `flutter test` pasa; APK release y Windows release compilan. `flutter analyze` no reporta errores, pero sí 6 avisos informativos existentes en informes.
- Builds disponibles: `build/app/outputs/flutter-apk/app-release.apk` y `build/windows/x64/runner/Release/app_integral_complete.exe`.
- El usuario confirmó que ejecutó `supabase/sync_inventory_movements.sql`. Se instaló el APK release con `adb install -r` (sin borrar datos) y se reiniciaron Android y Windows con los builds nuevos.
- Android inició Supabase, se suscribió a Realtime, completó el ciclo de auto-sync y subió tres movimientos locales pendientes (cloud IDs 3, 4 y 5); los logs revisados no muestran errores del sync del Kardex. Windows está ejecutando el EXE release nuevo.
- **Pendiente de validación funcional:** comprobar que los movimientos de compra, venta y anulación aparecen una sola vez y coinciden entre ambos dispositivos, incluyendo operación offline y reconexión. No se ha alterado el stock manualmente.

## Pendientes generales (fuera de compras), sin validar aún
- Logo del negocio: sincroniza correctamente vía Supabase (confirmado), pero requiere que ambos dispositivos usen el mismo usuario.
- Arranque Android: build release instalado y validado por el usuario sin aviso “App no responde”. Mantener pendiente solo la observación de arranques futuros; debug puede seguir mostrando lentitud adicional por su modo de ejecución.
- Migración SQLite Windows: resuelta (`sqlite3_flutter_libs`), build de Windows exitoso.
- Botón GUARDAR flotante en Configuración: funciona en pantallas grandes y móvil.
- Limpieza de imágenes huérfanas en Supabase Storage (productos): implementada.
- Bucket `player_avatars`: mismo patrón de subida sin limpieza que productos, pero no se encontró flujo de borrado de jugadores para enlazar el fix (fuera de alcance).
- Script `supabase/add_reports_and_cashflow.sql`: ya ejecutado correctamente en Supabase (incluye fix de cast `date::timestamptz`).

---

## Incidencias de sincronización reportadas (16/10/26)

### Cambios implementados en código; falta validar en dispositivos
- Configuración: el guardado ahora informa si Supabase no respondió; logo y redes sociales vacíos también se envían para permitir limpiarlos. Realtime aplica dirección, contacto, textos y redes además de nombre/logo/color. El campo de WhatsApp vuelve a guardar el valor que muestra su control.
- Compras: corregida la interpolación literal del subtotal. Para filas estrechas, cantidad/costo/subtotal se distribuyen en dos líneas y el nombre se trunca en vez de desbordar. No había traza guardada de un `RenderFlex overflow`; validar visualmente en móvil y ventana estrecha.
- Productos: productos nuevos, cajas y promociones reciben IDs locales grandes generados con tiempo + aleatoriedad antes de sincronizar. Así dos SQLite independientes ya no envían ambos `id=1` y se pisan en Supabase. Los registros históricos que ya se sobrescribieron no se pueden reconstruir desde la nube; revisar respaldos locales antes de borrar nada.
- Mesas: SQLite versión 21 agrega `billiard_tables.synced`; cambios locales de ocupación, orden, alta y liberación quedan pendientes y se suben antes del pull. El pull ya no pisa una mesa local marcada pendiente, incluso con `forceApply`.
- Retiros: `outflow_type` guarda el concepto configurable y no solo los cuatro valores fijos. Se añadió `supabase/fix_cash_outflows_outflow_type.sql` para quitar el constraint en instalaciones ya existentes; también se corrigió el script base.

### Validación reportada por el usuario (16/10/26)
- El usuario confirma que los pasos de validación y acciones Supabase solicitados para esta fase ya fueron completados en ambos dispositivos.
- Las pruebas de alta/edición/productos, stock y borrado online/offline se detallan en Fase 2 arriba.

### Builds de este cambio
- `flutter build windows --debug`: correcto.
- `flutter build apk --debug`: correcto (solo avisos de versiones Gradle/AGP/Kotlin próximas a quedar sin soporte).
- `flutter test`: pasa el placeholder existente; todavía no hay pruebas funcionales específicas para estas incidencias.
- `flutter analyze lib`: cero errores, pero salida con los mismos 8 avisos `info` preexistentes en archivos de informes.

*Este archivo es solo un resumen de trabajo, no forma parte de la app. Puedes borrarlo cuando termines de revisar.*
