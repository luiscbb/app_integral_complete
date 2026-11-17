# Avance: aislamiento por cuenta y sincronización

Actualizado: cierre del 16 de noviembre de 2026.

## PUNTO DE REANUDACION PARA EL 17/11/2026

**Leer esta sección primero. Es el estado vigente; las secciones posteriores
conservan el historial y pueden describir bloqueos ya resueltos. No recomenzar
los diagnósticos, migraciones, privatización ni despliegues ya confirmados.
Revisarlos de nuevo únicamente si aparece un fallo nuevo relacionado.**

### Terminado y confirmado: no repetir

- El piloto de personal **ya está habilitado**, tanto en Supabase/Edge como
  en los perfiles de VS Code. No falta activar roles para iniciar sus pruebas
  limitadas: Venta rápida, Inventario de consulta y Compras/proveedores.
- **Ya existe una cuenta real de personal y entra al portal.** No volver al
  paso de crear la primera cuenta. Se verificaron su membresía activa y sus
  tres módulos asignados; no se registraron operaciones ficticias.
- La base y las RPC del piloto están instaladas; `player-admin` está
  desplegado y `STAFF_PILOT_ENABLED=true` está configurado en el servidor.
  El HMAC existente se conservó. No buscarlo, imprimirlo ni rotarlo.
- Los buckets `player_avatars`, `product_images` y `promo_images` **ya son
  privados**. El propietario confirmó logo online/offline en M2004J19C;
  la lectura pública sin autorización fue rechazada. La prueba entre billars
  sigue pendiente, no la privatización.
- Compras/proveedores ya están conectados al portal, con solicitudes
  recuperables/idempotentes, tratamiento de rechazos y condiciones de pago
  al confirmar. Se precargan las preferencias del proveedor y se permite una
  excepción para esa compra. Crédito es total en esta etapa; abonos y anticipos
  quedan para cuentas por pagar. Los campos financieros remotos están instalados.
- Configuración ya separa las listas de mesas de juego y comanda. No rehacer
  esa separación ni migrar sus tipos o IDs.
- El inicio de personal ya usa el encabezado y las cards originales:
  nombre, logo privado, color del negocio y usuario de la membresía visible.
  Solo muestra módulos asignados e integrados. Comparte `home_modules.dart`,
  `HomeHeader`, `HomeLayout` y `ModuleCard`, no los sincronizadores del dueño.
- `staff_business_profile.sql` **ya se aplicó remotamente con autorización**.
  Su RPC devuelve solo identidad visual del billar de la membresía activa;
  se verificó ejecución autenticada y ausencia de ejecución anónima.
  No abre SELECT/escritura sobre `billar_settings`.
- El último cambio del inicio se aplicó al M2004J19C mediante **hot restart**:
  guard sin error, identidad cargada, tres módulos correctos y logo privado
  descargado con **3 061 938 bytes**. Esto no equivale a una nueva instalación
  del APK: si se necesita abrir fuera de VS Code, compilar/actualizar la versión
  final conservando datos. No desinstalar ni borrar almacenamiento.
- Última validación dirigida: **6 pruebas Flutter y 3 PostgreSQL/PGlite
  aprobadas**, más análisis de los 8 archivos Dart implicados sin incidencias.
  Incluye cards filtradas, usuario visible, rechazo de identidad de otro billar,
  actualización/revocación de permisos, logo del dueño e imágenes privadas.
  No es una certificación de toda la app ni de producción.

### Continuar aquí: pendientes en orden

1. **Logo del administrador en A60L:** el reporte continúa pendiente.
   No confundirlo con el logo de personal en M2004J19C, que sí se verificó.
   Diagnosticar su versión/sesión y descarga autenticada, sin revelar URLs
   privadas o tokens. El último reinicio fue solo del teléfono de personal.
2. **Contraseña temporal más sencilla:** todavía no se cambió.
   Revisar `staff_creation_key.ts` y sus pruebas; conservar derivación
   determinista, recuperación exacta e idempotencia. No recortar la firma
   arbitrariamente ni rotar el HMAC con solicitudes pendientes.
3. **Permisos por módulo y subcategoría:** todavía no se implementaron.
   El usuario quiere asignar módulos completos o partes, por ejemplo solo
   informes de compras. Acordar el catálogo y proteger cliente, rutas,
   RPC/RLS/Edge de forma coordinada. No mostrar interruptores funcionales para
   módulos sin autorización efectiva del servidor ni abrir todo al personal.
4. **Pruebas reales autorizadas del piloto:** usar la cuenta existente.
   Validar venta, compra/proveedor, inventario de consulta, revocación y
   cambio de contraseña con acciones expresamente autorizadas. El acceso
   actual ya funciona; el primer cambio obligatorio con una cuenta real no
   se declara probado de extremo a extremo solo por las pruebas automatizadas.
   El aislamiento entre billars requiere otra cuenta autorizada disponible.
5. **Cola funcional restante, sin bloquear la corrección del piloto:**
   - Jugador: detalle propio de estadísticas como el administrador y
     retas/training con formas de victoria; training no suma estadísticas
     competitivas y retas sí. No reclasificar historial por suposición.
   - Caja y turnos: operación separada de Informes/Caja, permiso independiente,
     tickets y turnos explícitos. Corregir efectivo físico frente a flujo total,
     fondo inicial, ventana exacta de turno y dobles movimientos. Tarjeta y
     transferencia no alteran el cajón; crédito no es pago hasta liquidarlo.
   - Cuentas por pagar, abonos/anticipos y demás módulos fuera del piloto.

### Entorno y límites que deben conservarse

- Proyecto remoto vigente: `lxsikbxeuktwufhmsucs`. La CLI **ya está autenticada
  y funciona**; no volver a pedir project ref ni login por una limitación antigua.
  Esta CLI usa `--remote=<ref>` y las consultas SQL en Windows usan `--file`.
- **No reaplicar `staff_rollout_install.sql` sobre este proyecto**: es para
  preparación sin personal, exige cero cuentas y cierra endpoints.
  Las actualizaciones futuras deben ser incrementales y probadas.
- En VS Code, **Ambos telefonos (piloto)** inicia M2004J19C y A60L con sus
  destinos explícitos y `--dart-define=STAFF_PILOT_ENABLED=true`.
  Cada teléfono tiene sesión/consola propia; detener una detiene ambas.
  Los nombres Personal/Administrador del perfil no inician ni cambian cuentas.
- Para flags de compilación, detener y arrancar con el perfil correcto;
  hot reload/restart no cambia los argumentos del arranque existente.
  Las URIs de DTD/VM son temporales: descubrir solo las conexiones actuales
  si se necesita depurar, sin repetir la preparación del backend.
- No borrar datos, crear cuentas/movimientos ficticios, reabrir buckets ni
  ampliar permisos por atajos. Las autorizaciones de limpieza del historial
  no son una autorización vigente para repetir borrados.
- Este es el corte solicitado para guardar en Git todos los cambios de código,
  SQL, pruebas y documentación acumulados. Credenciales, `node_modules` y
  trazas generadas quedan fuera del versionado; los logs locales se conservan.

## Estado

El aislamiento local y el piloto limitado de personal están integrados y
desplegados, con acceso real de administrador y personal confirmado. La
cuenta de personal ya existe y su inicio muestra identidad del negocio,
usuario y cards autorizadas. **La app completa no está certificada para
producción**: faltan las pruebas reales de operaciones/aislamiento y los
pendientes indicados en el punto de reanudación. Los demás módulos y la
auditoría general siguen pendientes. No distribuir compilaciones de diagnóstico.

Lo que sigue es historial cronológico; ante una diferencia, prevalece el
**PUNTO DE REANUDACION** de arriba y después la entrada más reciente del tema.

El usuario confirmó que los datos locales anteriores pertenecen a una única
cuenta administradora y un único billar. Autorizó exigir cierre y reapertura de
la aplicación para cambiar de cuenta y abrir cada dispositivo con Internet y la
cuenta original para realizar la vinculación.

El usuario indicó después que ya no necesita las operaciones antiguas y que
planea limpiar los datos de Supabase y los locales de los dispositivos de
prueba para comenzar desde cero. A la pregunta sobre qué dispositivos usaría
posteriormente identificó esta PC y el teléfono M2004J19C; mencionó otro
teléfono antiguo que considera limpio. Borrar solo datos remotos no garantiza
un inicio limpio:
los dispositivos con datos locales o pendientes podrían volver a sincronizarlos.
Antes de cualquier borrado hay que identificar y confirmar los destinos y
coordinar el reinicio sin afectar información ajena.

El usuario indicó que no hay respaldo restaurable y eligió continuar sin él,
aceptando el riesgo. Mantener cerradas las aplicaciones anteriores y no
reinstalar ni abrir la del tercer teléfono durante la preparación.
La inspección de solo lectura de la base Windows anterior encontró cero
productos, ventas y compras marcados como no sincronizados, y cero borrados de
productos pendientes; las tablas de las colas nuevas no existen en esa versión.
Esto no demuestra ausencia de otros pendientes. En M2004J19C se identificaron
la base anterior y un archivo journal; no se inspeccionó su contenido. El
usuario confirmó que el A60L detectado es el teléfono antiguo.

El usuario eligió preparar la limpieza de datos operativos del billar en
Supabase conservando cuenta, membresías y configuración, y limpiar los datos
locales de esta PC y M2004J19C. Storage no está incluido automáticamente en
esta elección.
Posteriormente eligió conservar las cuentas Auth de los tres jugadores aunque
se borren sus fichas y preparar una limpieza de imágenes. Luego indicó que
puede cargar un logo nuevo y eligió incluir el logo actual en la limpieza.
La consulta de Storage reportó 18 objetos en `product_images`, 12 en
`player_avatars` y un logo configurado que coincide por sufijo con un objeto;
esa coincidencia no verificaba su origen. Se acordó revisar las rutas
compartidas y autorizar el borrado concreto mediante Storage, no SQL. No se
han borrado las cuentas Auth de los jugadores.
El usuario indicó que revisó las 30 rutas y que todas pueden incluirse en el
plan, incluido el logo, y autorizó el borrado concreto de 18 objetos de
`product_images` y 12 de `player_avatars` mediante Storage. La lista compartida
contenía 27 imágenes y tres objetos `.emptyFolderPlaceholder`. Después de la
limpieza, la consulta del usuario solo reportó cuatro marcadores de carpeta
en esos dos buckets, incluido uno nuevo en la carpeta de avatares: no son
imágenes. Posteriormente se cargó un logo nuevo.
El usuario autorizó abrir la compilación Windows nueva: se abrió y mostró el
inicio de sesión. El usuario inició sesión y la app mostró el panel de
administrador y los datos del negocio. El usuario informó que seleccionó y
guardó un logo; la imagen aparece en el panel de Windows. La consulta del
usuario confirmó una configuración cuya referencia coincide con un objeto en
la ruta de logos del billar. Esa coincidencia no verifica por sí sola el origen
de la URL. Los buckets siguen públicos.
El usuario abrió la app nueva en M2004J19C e inició sesión; el negocio coincide,
pero el logo no aparecía. Se identificó que el inicio de sesión inicial no
guardaba la URL remota, aunque el arranque posterior sí lo hace. Una prueba
reprodujo el fallo y pasó tras corregirlo; también pasaron las pruebas dirigidas
de sesión y el análisis de los archivos afectados. El APK debug corregido se
compiló y, con autorización, se actualizó en M2004J19C sin borrar datos; el
hash del APK instalado coincide con la compilación. Tras reabrirla, el usuario
confirmó que el logo se muestra en el teléfono. Un primer intento de cerrar
sesión quedó en espera: el registro mostró el evento local de cierre, sin
confirmar el resultado remoto. Tras cerrar y abrir la app, el usuario informó
que cerró sesión y volvió a entrar correctamente y el logo cargó. También
reportó una excepción del guard de preferencias durante el cierre, sin traza;
su causa y el bloqueo inicial siguen sin determinarse. El inicio de sesión
corregido pasó la prueba automatizada; el reingreso real conserva preferencias
y no reproduce un primer inicio con datos locales vacíos.
Al retomar, una prueba aislada reprodujo la misma excepción al reconstruir la
pantalla de sesión mientras el ámbito ya estaba retirado. Se evitó esa lectura
y se limitó a 12 segundos la espera del cierre remoto; si vence, la app informa
que no se confirmó. La prueba también comprobó esa salida, y pasaron cuatro
pruebas dirigidas y el análisis de los archivos afectados. El APK debug nuevo
compiló y, con autorización, se actualizó en M2004J19C conservando datos; el
hash instalado coincide. Falta probarlo en el teléfono. Esto no demuestra que
la excepción original tuviera exactamente la misma traza; tampoco limita el
tiempo de la sincronización previa al cierre.
Durante esa prueba volvió a aparecer la excepción: el usuario compartió el
registro, que identifica `ScopedRemoteImage` después del evento de cierre.
Una prueba reprodujo la recarga indebida de la imagen privada al cerrar
sesión. Se corrigió para no iniciar cargas privadas sin sesión y se verificó
que la imagen vuelva a cargarse al entrar; pasaron las pruebas dirigidas y el
análisis. El APK posterior con esta corrección se instaló en M2004J19C con
autorización, conservando datos; el hash coincide. Al repetir la prueba, la
excepción persistió. La pila facilitada por el usuario identificó una lectura
de `businessName` en el panel principal oculto tras retirar la cuenta. Se
protegió el panel sin relajar el guard de preferencias y se probó la apertura
con el ámbito retirado; pasaron seis pruebas dirigidas y el análisis. Se compiló
otro APK y se instaló con autorización en M2004J19C conservando datos; el hash
coincide. El usuario confirmó que cerró sesión y volvió a entrar correctamente
con esa versión. La prueba automatizada no reproduce la secuencia exacta de
reconstrucción de una ruta ya abierta.
El registro Android mostró nueve mesas descargadas después del inicio; el
diagnóstico de cero registros corresponde al momento anterior a abrir la app
y ya no debe suponerse vigente. El diagnóstico posterior compartido por el
usuario confirma nueve mesas remotas y cero en los demás conteos operativos.
El código de inicio crea localmente las mesas configuradas si no existen y la
sincronización sube las pendientes; esto puede explicar su reaparición, pero
no confirma por sí solo cuándo ni desde qué dispositivo se crearon. No repetir
el borrado operativo. El usuario confirmó que las nueve mesas son correctas
y desea conservarlas.
Después se revisó el estado de personal: la sección de gestión, las acciones
Edge de gestión y el acceso normal continúan deshabilitados. El cliente ya
integra cambio obligatorio de contraseña, portal, venta rápida con caché
separada e inventario online de consulta, únicamente bajo parámetros explícitos
de integración desactivados por defecto. Los demás módulos no se abren para personal. El detalle vigente
y las pruebas más recientes están al final de este documento; las siguientes
notas registran las etapas previas, no el estado final de esta integración.
En la revisión inicial la RPC de venta no estaba conectada. Pasaron ocho pruebas Flutter
dirigidas de formularios, creación y acceso, y seis pruebas SQL aisladas de
creación, permisos y ventas. No validan el despliegue ni habilitan personal.
Se preparó localmente una resolución de personal, activa únicamente en
pruebas por un parámetro de integración deshabilitado por defecto: verifica
membresía activa, billar, rol, usuario, módulos y cambios de sesión; el inicio
y el arranque siguen bloqueando ese tipo de cuenta. No es una integración
operativa: faltan el cambio obligatorio de contraseña, rutas y permisos por
módulo, las operaciones transaccionales y pruebas reales coordinadas. No se
aplicaron cambios remotos ni se habilitó personal.
Pasaron 17 pruebas Flutter dirigidas de acceso, inicio y navegación, y el
análisis de los archivos afectados. Las respuestas de membresía se simularon;
esto no sustituye pruebas con sesiones y políticas reales de Supabase.
Se preparó también una cola local para la venta rápida de personal: conserva
solicitud, identificador y respuesta remota por cuenta y billar, y reutiliza
la solicitud si se pierde la respuesta. La migración SQLite de versión 45 a 46
conserva los datos existentes. Pasaron tres pruebas Flutter dirigidas, el
análisis de los archivos afectados y la prueba SQL aislada de la RPC. El
transporte se probó con respuestas simuladas, no contra Supabase. La cola no está conectada al cobro.
Se preparó la conciliación local transaccional: el borrador de la RPC registra
los productos cuyo stock afectó cada venta y devuelve un comprobante sin
costos; el cliente conserva revisiones más recientes, registra la venta una
sola vez y retira el pendiente en la misma transacción. La migración SQLite 47
conserva solicitudes de la versión 46. El comprobante, el transporte y el
cliente todavía deben probarse conjuntamente con sesiones reales; tampoco se
han integrado a la pantalla de cobro. Se preparó el vínculo de la reserva
local al pendiente: bloquea cambios del carrito mientras se recupera una venta
y la libera en la misma transacción de conciliación, solo si no cambió.
Solicitudes de versiones anteriores sin instantánea no se liberan
automáticamente. Una descarga de stock con revisión anterior ya no reemplaza
una revisión local más reciente.
La migración SQLite 48 distingue costos no disponibles de costos cero. El
comprobante remoto solo incluye el costo histórico para personal autorizado a
informes; si falta algún costo, el informe indica que no está disponible y
deshabilita su ticket. Todavía falta recuperar costos para ventas ya
conciliadas cuando se habilite posteriormente el permiso de informes.
Las reservas siguen siendo locales, no coordinadas entre dispositivos; la
edición concurrente de promociones y la coexistencia con el administrador
offline siguen pendientes. Ambas RPC de personal siguen sin permiso de
ejecución y el SQL no se ha aplicado.
El usuario eligió conservar el modo offline del administrador: el personal
revalidará el stock al cobrar, pero podría vender existencias reservadas por
el administrador mientras este no tiene conexión. No presentar esa
revalidación como una garantía de reservas globales.
Pasaron cuatro pruebas Flutter dirigidas, tres pruebas PostgreSQL aisladas y
el análisis de los archivos afectados. Se cubrieron reversión local ante
conflicto o cambio de sesión, reintento sin duplicados, revisión más reciente
y promociones con varios componentes; no son pruebas de extremo a extremo.
Posteriormente pasaron cinco pruebas Flutter dirigidas y tres SQL aisladas de
reservas, costos y revisiones. El análisis dirigido reportó una advertencia
informativa preexistente de contexto asíncrono en la pantalla de informes.
Se preparó [owner_promo_atomic_partial.sql](supabase/owner_promo_atomic_partial.sql):
precio, datos y componentes de una promoción se guardan en una transacción
idempotente que bloquea la misma fila que la venta y rechaza revisiones
antiguas. Sus políticas impedirían los métodos actuales de escritura directa:
**no aplicar** hasta sustituirlos, integrar la cola offline del administrador
y validar creación, edición, archivado y concurrencia reales. El EXECUTE sigue
revocado. Pasaron cinco pruebas Flutter dirigidas y cuatro SQL aisladas;
PGlite no sustituye pruebas de transacciones concurrentes en Supabase.
Se conectó experimentalmente la cola offline del administrador a la RPC
atómica de promociones, solo mediante `ProductRepository(atomicPromoSync:
true)`; el valor usado por la aplicación sigue desactivado. La versión SQLite
49 agrega la cola y la migración desde la 48 preservó los pendientes en una
prueba aislada. Creación, edición y archivado guardan el marcador en la misma
transacción local; la solicitud conserva actor, billar e identificador para
reintentar una respuesta perdida. Las ediciones posteriores permanecen
pendientes. El sincronizador anterior no sube productos con un marcador
atómico pendiente, y los métodos anteriores de edición y archivado del
repositorio los rechazan. Los conflictos remotos quedan pendientes y solo se
registran en el log; todavía falta una resolución visible.
Pasaron cinco pruebas Flutter dirigidas y el análisis de los archivos
afectados; también pasaron dos pruebas SQL aisladas. Se simularon respuestas
perdidas, cambios de cuenta, edición posterior, archivado y conflicto. No
son pruebas reales contra Supabase ni cubren subida de imágenes de promoción.
Antes de activar falta coordinar el indicador con `SyncService` y todos los
caminos de escritura, revisar pendientes heredados e imágenes, resolver
conflictos en pantalla y probar concurrencia real.
Se preparó también, bajo el mismo indicador desactivado, la descarga de
promociones del administrador entre dispositivos. Una RPC de solo lectura
devuelve cada promoción con sus componentes en una instantánea coherente;
la actualización local se realiza en una transacción y conserva cambios
pendientes y revisiones locales más recientes. Rechaza composiciones
inválidas o componentes que faltan localmente y comprueba la sesión. La RPC
verifica al administrador y tiene EXECUTE revocado; no cubre acceso de
personal. Esta garantía exige que todas las escrituras remotas de promociones
sean atómicas: los clientes antiguos todavía escriben por separado. La lista
inicial de productos conserva sus límites y comportamiento existentes.
Las pruebas usan respuestas HTTP simuladas y PostgreSQL aislado; faltan
pruebas reales de concurrencia, rendimiento con varias promociones y
sincronización completa entre dispositivos. La pantalla de cobro de
personal sigue sin conectar; no aplicar el SQL ni habilitar personal.
Se ampliaron las pruebas aisladas: una descarga antigua que termina después
de otra más reciente no reemplaza su promoción ni componentes; dos editores
simulados con la misma revisión producen un conflicto para el segundo y se
conserva la edición del primero. También se probó el archivado en la lectura,
el cambio de imagen tras una respuesta perdida y la recuperación de una
solicitud tras cerrar y reabrir SQLite. Pasaron cuatro pruebas Flutter, dos
SQL aisladas y el análisis dirigido. Las imágenes y el servidor HTTP se
simularon; la prueba SQL intercaló las operaciones secuencialmente y la
reapertura verificó la cola, no un reinicio completo de la aplicación.
No se probó concurrencia PostgreSQL real ni se modificó Supabase o dispositivos.
El usuario indicó que continuará mañana con las pruebas reales de concurrencia.
Preparar primero un entorno de prueba aislado y acordar cualquier cambio
remoto o en dispositivos antes de ejecutarlo; mantener desactivada la
integración experimental y no aplicar las políticas pendientes en producción.
El usuario autorizó la limpieza local concreta: se eliminaron la SQLite
`integral_pos_v1.db` y `shared_preferences.json` de la app en Windows, y se
limpiaron los datos internos del paquete en M2004J19C. Se verificó la ausencia
de los dos archivos Windows y de las carpetas internas de bases y preferencias
en Android. No se tocaron archivos externos ni cachés anteriores de Windows,
ni los datos del A60L. Los pendientes del teléfono no pudieron inspeccionarse
antes de la limpieza.
Se preparó [business_reset_diagnostic.sql](supabase/business_reset_diagnostic.sql)
para contar registros y dependencias sin devolver datos personales. Se probó
en PostgreSQL aislado con billares múltiples y referencias cruzadas. El usuario
lo ejecutó: hay una configuración, tres jugadores, cuatro productos, dos
proveedores, cuatro compras, 34 ventas, 11 mesas, siete torneos y otros datos
operativos. Los cuatro conteos de relaciones cruzadas inspeccionadas fueron
cero. La consulta no demuestra ausencia de datos de otros billares ni de
cuentas de autenticación de jugadores. Una segunda consulta reportó cero
registros de otros billares en las tablas revisadas y tres jugadores vinculados
a cuentas Auth. El borrador local
[business_reset_plan.sql](supabase/business_reset_plan.sql) se probó en
PostgreSQL aislado: conserva cuentas y Storage y revierte si cambian los
conteos, el ámbito o la identidad. El usuario autorizó ejecutarlo tras la
limpieza local y lo ejecutó. El diagnóstico posterior reportó cero en todos
los conteos operativos y una configuración. Las cuentas Auth y Storage no
estaban incluidos en el borrado; las sesiones reales siguen sin probarse.

## Implementado en el cliente

- [AccountStorage](lib/core/storage/account_storage.dart) selecciona un ámbito
  de cuenta y billar, exige reiniciar para cambiar de sesión y rechaza el acceso
  al almacenamiento cuando cambia la sesión.
- [DatabaseHelper](lib/core/database/database_helper.dart) abre SQLite separado
  por cuenta y billar. La migración verifica el propietario, copia la base
  anterior y conserva el archivo original. Las transacciones aisladas se
  comprueban antes de confirmarse.
- Cada base aislada nueva registra su cuenta y billar en SQLite. Antes de abrir
  una base existente se verifica esa identidad, incluso si Windows interpreta
  dos nombres de archivo como iguales. Una copia anterior con propietario
  verificado puede incorporar la identidad al abrirse; una base aislada sin
  ninguna identidad verificable se rechaza y se conserva para revisión.
- [PreferencesService](lib/core/storage/preferences_service.dart) separa las
  preferencias por ámbito y permite importar los valores anteriores después
  de verificar el propietario. Conserva una copia inicial de ajustes sin el
  PIN; la importación del PIN utiliza las preferencias originales verificadas.
- El inicio y el login activan el ámbito antes de abrir la aplicación. Tras una
  vinculación online válida, el propietario puede reabrir su base existente
  sin conexión. La primera vinculación requiere conexión.
- Los errores al descargar configuración ya no se tratan como si el negocio no
  existiera. La configuración inicial confirma primero el guardado remoto.
- Las compras antiguas sin billar y las ventas rápidas antiguas sin identidad
  se conservan, pero no se asignan ni sincronizan automáticamente.
- La cola [OwnerTransactionOutbox](lib/core/services/owner_transaction_outbox.dart)
  conserva las solicitudes de ventas y compras ante una respuesta perdida.
  Los envíos antiguos cuyo resultado remoto es incierto no se pueden identificar
  automáticamente.
- Las nuevas imágenes de productos y logos se suben a rutas encabezadas por el
  billar, con nombres aleatorios. Las cargas capturan y verifican la sesión;
  el borrado de imágenes de productos solo acepta URLs del proyecto y rutas
  del billar actual. Las imágenes antiguas fuera de ese ámbito se conservan.
  Las cargas de avatares también fijan y comprueban la sesión; la sincronización
  de jugadores ya no incluye el nombre de la persona en el nombre del archivo.
  Las referencias nuevas siguen siendo URLs estables; no se guardan firmas
  temporales.
- [PrivateImageService](lib/core/services/private_image_service.dart) descarga
  imágenes del proyecto con la sesión capturada, verifica cuenta y billar y
  rechaza redirecciones. Guarda hasta 100 imágenes de hasta 5 MiB cada una en
  la SQLite aislada; ante un fallo de conexión puede leer la copia de la misma
  cuenta y billar, pero no ante una respuesta de acceso denegado. La caché no
  está cifrada y el acceso offline no puede detectar revocaciones remotas.
  Las vistas, tickets e informes usan el lector compartido. Las URLs externas y
  rutas antiguas `products/` y `logos/` siguen usando lecturas públicas sin
  credenciales hasta resolver su migración o eliminación. La caché compartida
  utilizada por versiones anteriores no se ha borrado de los dispositivos.

**Dependencia importante:** el usuario instaló `sync_owner_sale`,
`sync_owner_purchase` y `archive_provider_idempotent` y verificó sus permisos
y estructura, pero aún no se han probado desde sesiones reales. Una consulta
anterior confirmó que `resolve_product_stock_conflict`, `record_staff_sale` y
`can_access_private_image` no estaban instaladas.

## Diagnóstico de Supabase

El usuario ejecutó los diagnósticos de solo lectura
[owner_sync_schema_diagnostic.sql](supabase/owner_sync_schema_diagnostic.sql) y
[account_isolation_diagnostic.sql](supabase/account_isolation_diagnostic.sql).
Indicó previamente que no había ejecutado los scripts modificadores de
personal ni de origen de ventas.

- La inspección mostró las tablas de membresías y configuración, y los campos
  de ventas y compras necesarios para el borrador transaccional. Las cuatro
  columnas `id` de cabeceras y detalles son `GENERATED BY DEFAULT AS IDENTITY`.
- Existen políticas permisivas amplias y una restricción que comprueba si el
  usuario es administrador de **algún** billar, no necesariamente del billar
  de la fila. Un administrador activo podría acceder a datos de otro negocio.
- La existencia de la tabla y los campos no demuestra por sí sola que la
  membresía administradora correcta sea activa y visible desde la sesión real.
- Los activos de Storage también requieren revisión: algunas imágenes usan
  rutas compartidas y URLs públicas.
- Se preparó [remote_security_diagnostic.sql](supabase/remote_security_diagnostic.sql)
  para revisar metadatos de RLS, políticas, permisos, funciones privilegiadas,
  triggers y buckets de imágenes sin leer filas de negocio. El usuario lo
  ejecutó en el proyecto real: las 22 tablas reportadas tienen RLS habilitado,
  pero existen privilegios anónimos y políticas de Storage para `public`.
  Los tres buckets de imágenes reportados son públicos. Los privilegios por
  sí solos no demuestran acceso efectivo cuando RLS restringe una operación.
  No hay conexión directa de base disponible desde aquí.
- El usuario eligió que todas las imágenes sean privadas. Se preparó
  [private_image_storage_partial.sql](supabase/private_image_storage_partial.sql)
  con políticas por billar, roles y avatar propio, probadas en PostgreSQL
  aislado. El borrador permite además al personal de jugadores leer el logo
  de su billar. **No ejecutarlo:** pueden existir referencias antiguas sin
  billar; también faltan pruebas con las políticas reales, el cliente y
  dispositivos reales antes de hacer privados los buckets.
- El usuario compartió las políticas actuales de `storage.objects`. Una
  política permisiva de inserción para `public` acepta cualquier ruta de
  `player_avatars`; la restricción anterior se aplica solo a `authenticated`.
  La consulta posterior confirmó que RLS está activo y `anon` tiene privilegios
  SELECT e INSERT sobre la tabla. Por tanto, las políticas y permisos de base
  permiten esa inserción anónima; no se ha verificado el comportamiento de la
  API de Storage con una solicitud real. El borrador bloquea esa inserción en
  una prueba PostgreSQL aislada que reproduce las expresiones reportadas.
- Se preparó la mitigación independiente
  [anonymous_avatar_insert_guard.sql](supabase/anonymous_avatar_insert_guard.sql):
  solo restringe inserciones del rol `anon` en el bucket de avatares, no cambia
  lecturas ni demás buckets. La prueba aislada comprobó rechazo anónimo,
  inserción de administrador, otros buckets e idempotencia. La consulta real
  confirmó que `authenticated` no hereda `anon` y que no existe todavía una
  política de ese nombre. El usuario ejecutó la mitigación en el proyecto
  actual y confirmó mediante consulta que existe como política restrictiva
  `INSERT` para `anon` con la condición prevista. Aún no se ha probado mediante
  la API de Storage real; las imágenes siguen siendo públicas.

**No ejecutar los demás archivos `*_partial.sql` sin revisión y autorización.**
El guard de identidad, el aislamiento por billar, las RPC del propietario, el
archivado de proveedores y los controles de stock aplicados no constituyen una
protección integral; los borradores de personal y Storage siguen pendientes.

## Orden candidato (no ejecutar todavía)

El orden siguiente es solo una guía para terminar el preflight, no una
autorización de despliegue:

1. Verificar las migraciones base existentes; no volver a ejecutar
   `add_player_registration.sql` sin revisar sus efectos sobre datos y
   membresías.
2. Revisar duplicados y valores existentes antes de aplicar
   `add_staff_account_fields.sql` o `add_sales_origin.sql`; no habilitar la
   creación de personal en esta etapa.
3. El usuario aplicó `business_owner_guard_partial.sql` y después
   `owner_business_scope_partial.sql`. Este par y su idempotencia se probaron
   en PGlite; el segundo precedió a las políticas de módulos de personal.
4. El usuario instaló las RPC del propietario, de archivado de proveedores y
   los dos scripts de stock; falta validar las operaciones reales. El guard
   rechaza actualizaciones de stock que no incrementen la revisión, incluidas
   las de versiones anteriores de la aplicación.
5. Las políticas y RPC de personal requieren su propio despliegue coordinado
   con la aplicación. No ejecutarlas mientras la función de personal siga
   deshabilitada.
6. Aplicar Storage privado después de su propia validación: resolver todas
   las referencias antiguas y comprobar imágenes autenticadas, tickets y
   operación offline. No necesita esperar todas las mejoras de jugadores,
   caja o Compras; sí requiere clientes compatibles y revisar las políticas
   reales. Al hacer privados los buckets, las URLs públicas antiguas dejan
   de ser un mecanismo válido de acceso.

Faltan resultados actuales del preflight remoto, incluida la detección de
valores incompatibles y la resolución de imágenes antiguas. La conexión de
Database Client no está disponible directamente desde aquí.

El usuario confirmó en el proyecto actual una configuración, sin billares
duplicados, identidades vacías, membresías sin configuración ni propietarios
con varias configuraciones; la configuración tiene administrador activo.
Existe un índice único por `user_id`. Tras autorizar y aplicar el guard de
identidad, el usuario verificó una identidad registrada y coincidente, el
trigger y el índice instalados y un administrador activo. Tras aplicar el
alcance por billar verificó 22 políticas de bloqueo anónimo, tres bloqueos de
escritura directa en membresías y un administrador activo. No se han probado
esos controles desde sesiones reales. También confirmó la instalación de ambas
RPC de propietario, sus dos columnas e índices y la tabla de solicitudes; el
rol anónimo no puede ejecutarlas y `authenticated` sí. Después instaló la RPC
de archivado, su tabla de solicitudes y `providers.is_active` y confirmó que
solo `authenticated` puede ejecutar la función. Falta validar su funcionamiento
real y las demás protecciones. El usuario instaló después el guard de stock y
verificó la columna de revisión, dos triggers habilitados y ninguna revisión
nula. Instaló después la conciliación y verificó la RPC, la auditoría con RLS
y que solo `authenticated` puede ejecutar la función. Aún no se han probado
ventas, compras y demás operaciones reales con esas protecciones.

## Validación realizada

- El 15 de noviembre de 2026 pasó la suite completa local: 75 pruebas Flutter,
  16 pruebas PostgreSQL aisladas y 14 pruebas TypeScript de Edge. Tras corregir
  un aviso del test de cierre de sesión, esa prueba volvió a pasar. El análisis
  completo no reportó errores ni advertencias; permanecen tres avisos
  informativos previos de `BuildContext` en informes.
- Tras instalar la RPC de proveedores pasaron tres pruebas PostgreSQL aisladas
  de stock y archivado y dos pruebas Flutter de sincronización y diálogo de
  conflictos. No validan el proyecto remoto ni las versiones instaladas.
- La herramienta de base de datos no encontró una conexión activa. No se
  consultó ni modificó Supabase desde aquí. El usuario ejecutó la consulta
  agregada de membresías: una configuración, un billar, un propietario y una
  configuración con administrador activo y sin cambio de contraseña pendiente.
  Esto no valida los permisos desde una sesión real.
- El diagnóstico de Storage ejecutado por el usuario indica tres buckets
  públicos: 18 objetos en rutas compartidas de productos, 12 avatares de los
  cuales uno no tiene carpeta y ningún objeto en promociones. Ese diagnóstico
  es anterior a la limpieza y al logo nuevo descritos en el estado.
- El usuario seleccionó el proyecto Supabase actual y autorizó actualizar el
  teléfono M2004J19C sin borrar datos. Después autorizó abrir la app y actualizar
  el APK con la corrección del logo; las comprobaciones posteriores están
  descritas en el estado.
  El proyecto de pruebas no está separado del actual. Revisar y obtener
  aprobación para cada cambio remoto concreto antes de aplicarlo.
- Pasaron 23 pruebas Flutter dirigidas de migración, aislamiento, inicio,
  offline simulado, sesión, sincronización y portal de jugador.
- Pasaron las pruebas aisladas de PostgreSQL para identidad del negocio,
  restricciones por billar y sincronización transaccional idempotente.
- Tras agregar la comprobación de identidad SQLite pasaron seis pruebas
  dirigidas de aislamiento, migración y arranque en Windows; también pasó el
  análisis estático de los archivos afectados.
- Se corrigió en los borradores la incompatibilidad entre las restricciones del
  propietario y las políticas de personal para inventario, ventas y compras.
  Cinco pruebas PostgreSQL aisladas verificaron las restricciones previas, el
  acceso por módulo y el rechazo de un orden incorrecto; una de ellas ejecuta
  juntos los borradores de propietario y personal. Siguen sin desplegarse.
- Se amplió la prueba combinada para instalar primero
  `business_owner_guard_partial.sql` y después
  `owner_business_scope_partial.sql`, ejecutando ambos más de una vez antes
  de instalar las políticas de módulos. También pasaron en conjunto las
  pruebas aisladas de transacciones y Storage privado: cinco pruebas dirigidas
  en total. Esto valida ese orden sobre fixtures PostgreSQL, no sobre el
  esquema real de Supabase.
- Los borradores ahora activan RLS y bloquean el rol anónimo en sus tablas,
  exigen una membresía del propietario para archivar proveedores y rechazan
  productos ajenos o ausentes al sincronizar ventas y compras. Un producto aún
  no subido debe sincronizarse antes de que su venta o compra pueda completarse.
  Siete pruebas PostgreSQL aisladas verificaron estos controles y las políticas
  de personal; no sustituyen las pruebas con Supabase real.
- Se añadió restricción de lectura y bloqueo de escrituras directas a
  membresías en el borrador de propietario. La función Edge preparada ya no
  autoriza al propietario sin membresía activa o con contraseña pendiente;
  las cuatro pruebas de permisos pasaron. No se ha desplegado.
- El análisis estático de los archivos integrados no reportó problemas.
- Compilaron Windows y Android en modo **debug**. No son versiones verificadas
  para uso con datos reales; el estado de instalación posterior se indica arriba.
- La migración de SQLite y el arranque offline se probaron en Windows con FFI y
  servicios simulados, no en Android ni contra el proyecto Supabase real.
- Se probaron con servicios simulados la descarga autenticada, el aislamiento
  por cuenta, la caché offline, el rechazo de redirecciones y cambios de
  sesión. Pasaron las pruebas dirigidas de imágenes, portal, tickets y PDF.
  El borrador de Storage se probó en PostgreSQL aislado junto con las políticas
  de módulos de personal. No demuestra el comportamiento de las políticas
  existentes del proyecto real. El análisis de los archivos afectados reportó
  tres avisos informativos previos sobre `BuildContext` en informes.
- Las compilaciones debug de Windows y Android volvieron a pasar tras integrar
  las imágenes. Posteriormente se instalaron y probaron parcialmente como se
  indica arriba; Gradle mostró avisos de futuras actualizaciones.
- La prueba [owner_login_logo_test.dart](test/owner_login_logo_test.dart)
  reprodujo que el primer inicio de administrador no restauraba el logo remoto.
  Tras corregir [login_page.dart](lib/features/auth/presentation/pages/login_page.dart)
  pasaron esa prueba, `staff_login_page_test.dart` y
  `owner_storage_startup_test.dart`, además del análisis de los archivos
  modificados. El APK Android instalado incluye la corrección; el EXE Windows
  abierto se compiló antes de ella y no se ha recompilado.

Se intentó iniciar el emulador Android en modo de solo lectura, pero falló. Su
registro indicó `Deleting snapshot default_boot`; la carpeta de la instantánea
seguía existiendo, pero no se verificó su integridad. No se modificó el teléfono
conectado en ese intento. No volver a usar o borrar esa instantánea sin revisar
su estado.

## Siguientes pasos históricos (anteriores a la activación del piloto)

Esta lista conserva el contexto de aquella etapa, **no es la cola vigente**.
Para continuar usar exclusivamente los pendientes del punto de reanudación
al principio del documento; no repetir estos despliegues ni la privatización.

1. Completar los módulos restantes de personal y la recuperación posterior de
   costos para informes. Contraseña, portal y venta rápida ya están integrados
   localmente, pero hay que validar Auth, Edge, RPC y políticas. El usuario
   autorizó después usar el proyecto actual conservando sus datos: comenzar
   por el preflight de solo lectura y no ejecutar allí pruebas que reconstruyen
   o limpian tablas. El acceso normal y la gestión siguen deshabilitados;
   no desplegar borradores por separado.
2. Probar cargas, lecturas, tickets y caché de imágenes contra Storage real;
   resolver referencias antiguas y revisar políticas antes de pedir autorización
   para privatizar buckets. No ejecutar aún el borrador de Storage privado.
3. Android: sesión del propietario, base aislada y reapertura offline
   verificadas en M2004J19C; el usuario confirmó que también se conserva el logo
   sin conexión. El A60L no se abrió. Windows se recompiló y se abrió la versión
   nueva; el panel y el logo se ven con la sesión local existente. Falta una
   prueba de primer inicio con preferencias vacías, sin borrar datos de la
   instalación actual.

El repositorio contiene numerosos cambios previos y archivos no versionados;
no revertirlos ni sobrescribirlos sin revisar. Las pruebas SQL aisladas usan
`@electric-sql/pglite` y no equivalen a una prueba en Supabase real.

### Validación móvil y caché offline del logo (16/11/26)

- La instalación inicial del APK informó que Flutter desinstalaba la versión
  anterior; la inspección posterior encontró el paquete sin base local ni
  preferencias. El usuario eligió continuar como instalación limpia, volvió a
  iniciar sesión y los datos del negocio se restauraron. Las actualizaciones
  siguientes se hicieron con `adb install -r` y conservaron esa nueva base.
- En Android, el panel y los datos abrían sin conexión, pero el logo no. Los
  logs identificaron el límite de `CursorWindow` al leer logos grandes como
  BLOB. Además, las rutas públicas antiguas usaban `Image.network` y no se
  guardaban para uso offline.
- La caché ahora guarda imágenes pequeñas en SQLite y las mayores de 512 KiB
  en archivos separados por cuenta y billar; también envía las rutas públicas
  antiguas por el cargador con caché. Los archivos grandes siguen limitados a
  5 MiB por imagen y 100 entradas por ámbito.
- Pasaron diez pruebas dirigidas de sesión/aislamiento y las pruebas de caché,
  imagen pública antigua y restauración del logo. El análisis de los dos
  archivos de caché no encontró problemas. Las compilaciones debug de Windows
  y Android pasaron; Gradle mostró avisos de futuras actualizaciones.
- El usuario confirmó en M2004J19C que los datos y el logo aparecen en línea y
  que el logo se conserva tras cerrar y reabrir en modo avión. La app Windows
  recompilada se abrió después de cerrar la instancia anterior y muestra el
  panel y el logo. Entró con la sesión/preferencias ya existentes; esto no
  sustituye una prueba de primer inicio en un perfil Windows limpio.

### Preflight local para habilitar personal (16/11/26)

- Pasaron 13 pruebas Flutter de acceso, formularios, creación, login, gestión y
  colas del personal.
- Pasaron 27 pruebas Node/PostgreSQL aisladas para identidad, creación,
  permisos por módulo, inventario, compras, ventas y recuperación idempotente
  de solicitudes Edge. Se instaló `@electric-sql/pglite` 0.5.16 localmente sin
  modificar manifiestos del proyecto.
- Estos resultados no prueban Auth, permisos ni RPC contra Supabase real. La
  sección y las acciones Edge siguen deshabilitadas; el cliente no conecta la
  venta del personal a `record_staff_sale`, y las dos RPC de personal siguen
  sin permiso de ejecución. No habilitar roles todavía.
- Para continuar hace falta un proyecto Supabase de pruebas separado, cuentas
  de propietario y personal de prueba y una validación coordinada del esquema,
  funciones Edge, políticas por módulo, creación/revocación de cuentas y ventas.
  No se hicieron cambios remotos en esta sesión.

### Integración local del cobro de personal

- Los diagnósticos compartidos por el usuario corresponden al proyecto actual,
  no a un proyecto de pruebas. Confirman RLS y restricciones del propietario,
  pero no demuestran los permisos efectivos de una sesión de personal. No
  confundir políticas permisivas amplias con acceso efectivo: también aplican
  las políticas restrictivas. No se ejecutó SQL modificador ni se desplegó Edge.
- Se añadió
  [staff_quick_sale_checkout.dart](lib/features/quick_sale/data/staff_quick_sale_checkout.dart)
  para unir autorización, cola persistente, envío a `record_staff_sale` y
  conciliación del comprobante. Antes de cobrar o recuperar exige membresía
  activa de personal, módulo `quick_sale`, contraseña cambiada y el mismo
  ámbito de sesión. Los errores se propagan sin confirmar una venta local.
- La recuperación reutiliza la solicitud pendiente; si el servidor ya confirmó
  el identificador de venta, no vuelve a enviarla. El inventario local se toma
  del comprobante autoritativo, sin ejecutar el descuento del propietario.
- Las pruebas dirigidas cubren cobro, pérdida de respuesta de venta y
  comprobante, recuperación sin duplicados, acceso revocado o sin módulo,
  contraseña pendiente, falta de conexión y cambio de ámbito.
  Pasaron nueve pruebas Flutter, incluidas las colas, conciliación y bloqueo
  de personal existentes y una regresión de sincronización del propietario.
- Esta integración es de la capa de datos: todavía no está conectada a
  `QuickSalePage`. El login y las acciones Edge de personal siguen bloqueados.
  La conexión posterior a una pantalla separada con permisos se documenta
  al final; `QuickSalePage` sigue siendo el flujo del propietario.

### Catálogo de venta del personal sin costos

- Se añadió
  [staff_sale_catalog_repository.dart](lib/features/quick_sale/data/staff_sale_catalog_repository.dart),
  que consulta únicamente `staff_sale_products` con el token y billar capturados.
  Comparte con el cobro la comprobación de membresía, módulo `quick_sale`,
  contraseña cambiada y ámbito de sesión. No usa el repositorio ni la
  sincronización del propietario; tampoco guarda el catálogo en SQLite.
- El resultado usa
  [StaffSaleProduct](lib/features/quick_sale/domain/entities/staff_sale_product.dart),
  un modelo sin costos ni filas remotas sin filtrar. Rechaza productos de otro
  billar, duplicados, importes no válidos y respuestas malformadas. Un error o
  una revocación no devuelve un catálogo vacío ni una copia anterior como éxito.
- El borrador `staff_inventory_guards_partial.sql` calcula ahora en `stock`
  las unidades vendibles de presentaciones y promociones, en lugar de su
  stock bruto. Agrupa componentes repetidos y deja sin disponibilidad las
  relaciones incompletas, archivadas, inválidas o de otro billar. Esto no reserva
  existencias: la RPC de cobro sigue revalidándolas.
- Pasaron cuatro pruebas PostgreSQL aisladas de inventario, compras, ventas y
  restricciones del propietario, con reaplicación de los borradores. La prueba
  de catálogo verifica existencias de presentaciones/promociones y ausencia
  de costos, además de los controles de acceso.
- Pasaron 13 pruebas Flutter dirigidas de catálogo, cobro, recuperación,
  bloqueo de personal y regresión del propietario. El análisis estático de
  los cinco archivos Dart nuevos o afectados en este paso no encontró problemas.
- Al cerrar este paso faltaban la pantalla y la caché para reservas y
  conciliación. Su integración posterior se documenta a continuación.

### Caché aislada y pantalla de venta rápida del personal

- SQLite 50 agrega `staff_sale_catalog` y `staff_sale_cart`, separados de
  `products` y de las reservas del propietario, con claves por cuenta y billar.
  La migración desde 49 conserva los datos; también se conserva la migración
  de pendientes de 48. La caché no tiene costos ni convierte costos desconocidos
  en cero. Conserva revisiones de stock superiores y rechaza valores distintos
  para una misma revisión.
- La RPC del borrador devuelve además stock bruto, revisión y componentes
  agrupados, siempre sin costos. El cliente calcula la disponibilidad de
  presentaciones y promociones descontando su propio carrito. **Cambió el
  contrato del borrador no desplegado**: su recreación y despliegue deben ser
  coordinados con el cliente; no ejecutar este SQL por separado.
- La cola y la conciliación usan la caché de personal mediante
  `StaffQuickSaleOutbox.staffCache`. Mientras hay una solicitud pendiente no
  se edita el carrito. La confirmación aplica el stock autoritativo a esa
  caché, guarda la venta/comprobante y elimina carrito y pendiente en la misma
  transacción. No escribe ni descuenta el inventario del propietario.
- [StaffQuickSalePage](lib/features/quick_sale/presentation/pages/staff_quick_sale_page.dart)
  conecta catálogo, carrito persistente, diálogo de pago, cobro, recuperación
  del mismo identificador y comprobante con los nombres confirmados por el
  servidor. Comprueba permisos en operaciones, invalida el acceso al cambiar
  sesión y revalida al regresar a primer plano. Un carrito modificado durante
  el pago exige revisión aunque conserve el mismo total.
- La ruta de venta rápida ya evita enviar una cuenta con metadatos de personal
  a la pantalla de escritura del propietario. La pantalla de personal requiere
  `enableForIntegration: true`; la ruta normal conserva el valor `false`.
  El login, la resolución de acceso normal y las acciones Edge siguen
  bloqueados. No se habilitaron roles.
- La recuperación exige conexión y permisos vigentes. Los errores conservan
  el intento; no se ofrece descartar automáticamente una solicitud incierta
  ni anular una venta de personal. Un rechazo persistente requiere revisión:
  no se debe modificar la cola a mano para permitir otro cobro.
- Se generó un APK Android debug con este código, sin instalarlo. Gradle,
  AGP y Kotlin mantienen los avisos previos de futuras actualizaciones.
  No se hicieron cambios en Supabase ni en las instalaciones existentes.
- Validación final: pasaron 25 pruebas Flutter de caché, migración, pantalla,
  pago, carrito cambiado con el mismo total, pérdida de respuesta, recuperación
  al reabrir, revocación y regresiones de aislamiento/arranque offline del
  propietario. Pasaron cuatro pruebas PostgreSQL aisladas del contrato ampliado
  y sus políticas. El análisis de 14 archivos no encontró problemas; formato y
  `git diff --check` pasaron. Auth y las RPC se simularon en las pruebas Flutter:
  no se ha probado este flujo con cuentas reales ni en un dispositivo instalado.
- Al cerrar este paso faltaban el cambio obligatorio de contraseña, el portal
  y los permisos del resto de rutas/módulos, la recuperación posterior de costos
  para informes y las pruebas coordinadas con Auth/RPC/Edge en Supabase de pruebas.

### Contraseña obligatoria, portal y bloqueo de rutas de personal (16/11/26)

- El login y el arranque admiten personal únicamente con
  `enableStaffForIntegration: true`. Activan el almacenamiento por cuenta y
  billar sin migrar datos ni preferencias del propietario. El acceso normal,
  `AppRouter.onGenerateRoute` y la gestión Edge conservan sus gates cerrados.
  Las contraseñas se envían exactamente como se escribieron, incluidos espacios;
  solo se normaliza el identificador de acceso.
- [AuthAccessRepository](lib/features/auth/data/auth_access_repository.dart)
  captura la sesión y fija su token al resolver acceso o cambiar contraseña.
  Rechaza respuestas de una sesión sustituida, incluso si conserva usuario y
  token. Antes de cambiar la contraseña de personal exige membresía activa y
  cambio pendiente; después exige `{ok: true}` y vuelve a comprobar membresía,
  billar y que el cambio ya no esté pendiente.
- La pantalla obligatoria no permite volver atrás y ofrece cerrar sesión.
  Solo navega al portal después de confirmar el acceso con la misma sesión;
  ni un HTTP 200 malformado ni una revocación liberan la navegación.
- El borrador Edge extrae la operación en
  [password_change_workflow.ts](supabase/functions/player-admin/password_change_workflow.ts).
  Personal no se autoriza mediante filas de jugadores: valida su membresía,
  usuario, módulos y revisión; detiene la recuperación de la contraseña
  temporal antes de actualizar Auth. Los errores de consulta, recuperación,
  Auth o confirmación se notifican explícitamente. Se conservan y prueban los
  caminos de jugadores y encargados anteriores.
- El borrador
  [staff_account_creation_partial.sql](supabase/staff_account_creation_partial.sql)
  agrega `complete_staff_password_change`, ejecutable solo por `service_role`.
  Bloquea la membresía, comprueba identidad y revisión, exige recuperación
  temporal desactivada y confirma flag, nueva revisión y auditoría sin secretos
  en una transacción. Repetir una confirmación ya aplicada no duplica auditoría.
  Depende del esquema de personal, incluida `staff_revision`, todavía ausente
  en el diagnóstico del proyecto actual: **no ejecutar este cambio por separado**.
- [StaffRouteGate](lib/features/auth/presentation/pages/staff_route_gate.dart)
  intercepta las rutas de personal, incluidas rutas desconocidas o propias del
  administrador. Revalida sesión, membresía, billar y módulo al entrar y al
  regresar a primer plano; no monta pantallas del propietario. El portal muestra
  solo los módulos asignados: únicamente venta rápida puede abrirse; los demás
  aparecen deshabilitados como pendientes de integración. El resume de personal
  tampoco dispara la sincronización general del propietario.
- Validación final: **43 pruebas Flutter** en 20 archivos pasaron, incluidas
  las nuevas pruebas de contraseña exacta, sustitución de sesión, respuesta
  inválida, login, arranque con sesión guardada, contraseña obligatoria, portal,
  rutas directas, revocación del módulo y cierre de sesión. También pasaron las
  regresiones de venta rápida, aislamiento, jugador, encargado anterior y
  arranque online/offline del propietario.
- Pasaron **15 pruebas TypeScript** de flujos y permisos y **cuatro pruebas
  PostgreSQL aisladas**, incluida confirmación de contraseña, permisos de
  ejecución, revisión obsoleta, inactividad, rollback de auditoría e idempotencia.
  El análisis de 12 archivos Dart no encontró problemas; el formato de los
  archivos nuevos y `git diff --check` pasaron.
- Se compiló el APK Android debug final, **sin instalarlo**. Los avisos previos
  de Gradle/AGP/Kotlin siguen presentes. Edge pasó comprobación sintáctica con
  Node y pruebas de su lógica aislada; no se hizo type-check con Deno ni
  despliegue. Las pruebas Flutter simulan Auth/RPC y usan SQLite real temporal;
  no validan Supabase real ni un dispositivo con cuentas de personal.
- No se modificaron servicios remotos, cuentas, buckets ni instalaciones.
  **No habilitar roles todavía**: faltan los módulos restantes, recuperación
  posterior de costos, tratamiento seguro de rechazos persistentes de cobro y
  pruebas coordinadas en Supabase de pruebas antes de autorizar un despliegue.

### Destino autorizado y conexión pendiente (16/11/26)

- El usuario autorizó continuar los cambios en el **proyecto Supabase actual,
  conservando todos sus datos**, en lugar de usar un proyecto de pruebas
  separado. No autoriza borrados ni sustituye la validación previa a habilitar
  personal.
- Antes de modificar el proyecto hace falta repetir el preflight de solo
  lectura y contrastar el esquema, funciones y permisos con los borradores.
  Las comprobaciones en el proyecto actual deben preservar sus operaciones;
  no ejecutar allí pruebas que limpian o reconstruyen tablas.
- Inicialmente Database Client no tenía conexiones creadas. Después de que el
  usuario configuró el perfil `intappcomplete`, este ya aparece en el panel,
  pero las herramientas siguen devolviendo `Connection not found`, incluso
  al indicar la base `postgres` en una consulta de solo lectura. El usuario
  ejecutó `SELECT 1 AS conexion_ok` y se observó su resultado correcto en el
  editor: la conexión funciona en la interfaz, no en el enlace de herramientas.
  Los intentos de interacción con el editor se interrumpieron por entrada
  activa del usuario; no se forzó el control. No se encontraron los ejecutables
  Supabase/Deno en PATH ni variables de acceso de administración disponibles.
  No se ejecutó SQL modificador ni se desplegó Edge después de esta autorización.
- Para continuar el preflight remoto, configurar y seleccionar la conexión
  en el enlace de herramientas, o ejecutar las consultas de solo lectura
  desde la conexión ya operativa o el editor SQL de Supabase y compartir sus
  resultados. No compartir contraseñas, tokens ni claves de servicio en el chat.

### Diagnóstico remoto recibido y preflight de personal (16/11/26)

- El usuario compartió el resultado de
  [remote_security_diagnostic.sql](supabase/remote_security_diagnostic.sql)
  ejecutado sobre la conexión autorizada. Las 26 tablas reportadas tienen RLS
  habilitado, sin `FORCE ROW LEVEL SECURITY`. Se reportan las restricciones
  del propietario por billar, los bloqueos anónimos y las restricciones de
  escritura de membresías. Sus nombres y los indicadores resumidos no
  demuestran por sí solos sus expresiones ni el acceso de una sesión real.
- Los indicadores `anon_select/insert/update/delete: true` son privilegios
  de tabla: **no significan acceso efectivo ilimitado** cuando aplican las
  políticas restrictivas. Este resultado no es motivo para quitar dichas
  restricciones ni reemplazarlas por políticas permisivas.
- Se reportan las RPC de sincronización del propietario, archivado y
  conciliación de stock con ejecución para `authenticated`, no para `anon`,
  y los triggers de identidad y revisión de productos. No se repitió ninguna
  operación real de venta, compra ni ajuste de stock.
- No aparecen las cinco tablas de solicitudes, auditoría y conciliación de
  personal esperadas por los borradores. Tampoco aparecen sus funciones
  `SECURITY DEFINER` en la lista correspondiente. El diagnóstico general no
  enumera columnas ni funciones no privilegiadas: no permite confirmar
  `staff_revision` ni detectar todos los despliegues parciales.
- Los tres buckets de imágenes siguen públicos. Se reporta
  `deny_anonymous_avatar_insert`; el resumen no muestra las condiciones de las
  políticas de Storage ni valida su API. No se cambió la privacidad de buckets.
- Se preparó
  [staff_rollout_diagnostic.sql](supabase/staff_rollout_diagnostic.sql):
  una consulta de solo lectura con columnas/tipos/defaults, tablas y RLS,
  firmas/retornos/grants de funciones de personal, restricciones e índice de
  usuario y expresiones de las políticas de membresías. Agrega únicamente
  conteos de usuarios incompatibles, duplicados normalizados, roles, nombres,
  puestos y módulos; no devuelve filas ni identificadores de cuentas.
- Pasaron dos pruebas PostgreSQL aisladas: el diagnóstico funciona sin las
  columnas nuevas, detecta datos incompatibles, no devuelve los valores de las
  cuentas de prueba ni altera sus filas, y distingue permisos de funciones
  ausentes frente al esquema preparado. También pasó la regresión de
  creación/cambio de contraseña. El SQL modificador de estas pruebas se ejecuta
  **solo en PGlite**, nunca en el proyecto actual.
- El usuario ejecutó después el diagnóstico específico: confirmó cero filas
  de personal, cero incompatibilidades y duplicados normalizados, los campos
  base con tipos/defaults previstos, las dos restricciones validadas y el
  índice único de usuario. En ese diagnóstico `staff_revision`, las cinco
  tablas de personal y las 13 funciones consultadas estaban ausentes. Las expresiones de
  lectura de membresías permiten la fila propia o al administrador del mismo
  billar; las políticas restrictivas reportadas bloquean escrituras directas
  y acceso anónimo.
- Se actualizó
  [add_staff_account_fields.sql](supabase/add_staff_account_fields.sql)
  para preparar también `staff_revision bigint NOT NULL DEFAULT 0`, sin
  funciones, cuentas, grants ni políticas nuevas. En el esquema reportado,
  los otros campos, restricciones e índice ya existen. El script es
  transaccional y limita la espera de bloqueos a tres segundos y la duración
  de cada sentencia a 30 segundos. Si una ejecución manual falla, ejecutar
  `ROLLBACK` y revisar el error; no continuar con otro script.
- Pasaron seis pruebas PostgreSQL aisladas después de este ajuste:
  preparación repetida sin cambios de permisos ni creación de personal,
  rollback ante datos incompatibles, diagnóstico, creación/contraseña,
  políticas de módulos, inventario, ventas y restricciones del propietario.
  La compatibilidad aislada no demuestra aún la aplicación en el proyecto real.
- El usuario ejecutó después el bloque acotado de preparación de revisión y
  compartió su verificación del proyecto actual (16/11/26, 13:42):
  `staff_revision`, tipo `bigint`, `is_nullable = NO`, `column_default = 0`.
  Queda confirmada la columna remota; este cambio no crea cuentas, funciones,
  permisos ni políticas de personal. No demuestra todavía el funcionamiento
  de los flujos completos ni una validación de datos operativos reales.
- La preparación base de campos queda confirmada. Siguen pendientes los
  módulos locales restantes y el despliegue coordinado de funciones,
  políticas y Edge con sus verificaciones. No desplegar los borradores por
  separado ni habilitar personal todavía.

### Inventario de consulta y preparación de proveedores (16/11/26)

- Alcance confirmado por el usuario: **Inventario solo consulta** de productos,
  costos y existencias; **Compras permite registro y gestión auditada de
  proveedores, sin cancelaciones**. Esto define el alcance requerido, no
  significa que Compras ya esté integrado ni que se hayan habilitado permisos.
- Se integró
  [StaffInventoryPage](lib/features/inventory/presentation/pages/staff_inventory_page.dart)
  al portal y a la ruta de inventario exclusivamente bajo integración explícita.
  Exige el módulo `inventory`; tener `purchases` o `reports` no abre esta
  pantalla. Venta rápida conserva sus permisos independientes. El acceso
  normal sigue cerrado y el resto de los módulos del portal está deshabilitado.
- La pantalla consulta productos activos, muestra precio, costo y stock
  registrados, y filtra por nombre, código y categoría. No permite altas,
  edición, ajustes ni cancelaciones. El banner distingue el stock registrado
  de la disponibilidad vendible: no descuenta reservas ni calcula existencias
  de presentaciones o promociones a partir de sus bases o componentes.
- [StaffInventoryRepository](lib/features/inventory/data/repositories/staff_inventory_repository.dart)
  hace exclusivamente lecturas online, con columnas explícitas y filtro por
  billar. Pagina por ID ascendente hasta una página vacía, incluso si el servidor
  devuelve páginas menores al límite solicitado. Rechaza productos de otro
  billar, respuestas inválidas, IDs repetidos/desordenados y costos desconocidos
  o inválidos; no los convierte a cero. Admite stock negativo finito como valor
  registrado, sin reinterpretarlo como autorización para vender.
- Revalida módulo y membresía antes y después de la lectura; fija el token y
  comprueba sesión y generación después de cada espera. Al actualizar, reanudar,
  cambiar sesión o fallar una consulta, retira los datos anteriores. No conserva
  costos en SQLite, preferencias ni caché de venta; tampoco utiliza el
  repositorio, la pantalla ni la sincronización general del propietario.
- Para proveedores se preparó
  [staff_provider_operations_partial.sql](supabase/staff_provider_operations_partial.sql):
  crea solicitudes y auditoría aisladas y la RPC
  `apply_staff_provider_operation` para alta, edición completa y archivado,
  incluyendo las relaciones con productos del mismo billar. El archivado
  conserva las relaciones y el registro histórico; no elimina proveedores ni
  cancela compras.
- Esa RPC exige identidad de personal en `app_metadata`, billar coincidente,
  membresía activa, contraseña cambiada y módulo `purchases`. Bloquea la
  membresía, la solicitud y el proveedor; comprueba productos bajo bloqueo.
  El UUID, actor y payload fijan la operación: repetirla devuelve exactamente
  el comprobante original y no duplica cambios ni auditoría; modificar la
  solicitud o repetirla después de revocar acceso produce error. La auditoría
  guarda actor, operación y estados anterior/posterior, solo visibles al
  administrador del billar. Un fallo de auditoría revierte toda la operación.
- El futuro cliente debe persistir UUID, ID de proveedor y payload completo
  **antes de enviar** y conservarlos si no puede confirmar la respuesta. El
  comprobante de una repetición corresponde a la operación original, no
  sustituye una consulta del estado actual. La RPC queda sin ejecución para
  `PUBLIC`, `anon` y `authenticated`; no se conectó todavía a una pantalla.
  El diagnóstico de despliegue incluye ahora esta función y sus dos tablas.
- Validación: **48 pruebas Flutter en 22 archivos**, incluidas consulta paginada,
  costos, datos inválidos, sesión, revocación, filtros, error HTTP, respuesta
  malformada y ausencia de escrituras en inventario local. También pasaron
  las regresiones de contraseña, login/arranque, venta rápida, jugador,
  encargado anterior y propietario online/offline.
- Pasaron **cuatro pruebas PostgreSQL aisladas**: permisos de compras y
  proveedores con la nueva RPC, inventario, archivado del propietario y
  diagnóstico. Comprueban aislamiento, permisos cerrados por defecto,
  identidad confiable frente a `user_metadata`, payload inválido, repetición,
  cambio de actor, revocación, auditoría y rollback. Estas pruebas solo usan
  PGlite; no modifican el proyecto actual.
- El análisis de siete archivos Dart no encontró problemas y el APK Android
  debug compiló **sin instalarse**. Permanecen los avisos previos de
  Gradle/AGP/Kotlin. No se hicieron despliegues, cambios de cuentas remotas,
  instalaciones ni cambios en buckets.
- **Compras continúa pendiente y bloqueada**: falta registrar compra,
  detalles, movimientos, costos y revisiones de stock en una transacción
  auditada e idempotente, y conectar su cliente de personal con recuperación
  persistente, proveedores e historial sin cancelaciones. No reutilizar la
  pantalla ni las RPC exclusivas del propietario como atajo. Después siguen
  los otros módulos y las verificaciones coordinadas de SQL, políticas y Edge;
  no habilitar roles todavía.

### Registro transaccional de compras y recuperación persistente (16/11/26)

- Se completó el **núcleo de registro y recuperación**, no la pantalla ni el
  módulo completo. Compras continúa bloqueado en el portal y en sus rutas;
  no se habilitó el acceso normal de personal ni se desplegó SQL o Edge.
- El borrador
  [staff_purchase_recording_partial.sql](supabase/staff_purchase_recording_partial.sql)
  prepara `record_staff_purchase`, solicitudes privadas y auditoría para el
  administrador del billar. La ejecución permanece revocada para `PUBLIC`,
  `anon` y `authenticated`. El diagnóstico de despliegue incluye ahora esta
  función y sus dos tablas.
- La RPC exige identidad de personal en `app_metadata`, billar coincidente y
  membresía activa con módulo `purchases` y contraseña ya cambiada. El cliente
  envía UUID, proveedor opcional, referencia, origen del dinero y detalles;
  cada detalle fija producto, cantidad, costo por unidad, padre y piezas por
  presentación. El servidor calcula total, fecha y nombres y atribuye la compra
  al usuario de la membresía, con actor Auth inmutable en la auditoría.
- Rechaza productos o proveedores ajenos/inactivos, promociones, cantidades
  no positivas, costos inválidos, detalles repetidos y campos extra, incluidas
  cancelaciones o nombres suplantados. Una presentación cuyo padre o número
  de piezas cambió no se interpreta silenciosamente con la conversión nueva.
  Los desbordamientos y cantidades que no pueden incrementar el stock
  representado provocan error y rollback, no éxito sin efecto.
- Bloquea membresía, solicitud, proveedor y productos afectados. Los productos
  y sus presentaciones conocidas se bloquean por ID ascendente; un producto
  solicitado que aparece después de ese bloqueo no puede confirmarse sin
  haber quedado incluido. Compra, detalles, movimientos, costos, revisiones y
  auditoría se confirman juntos o se revierten juntos.
- Las presentaciones incrementan el stock del producto base y convierten el
  costo a pieza; no incrementan su propio stock bruto. Se actualiza el costo de
  las presentaciones conocidas y sus revisiones, conservando el stock bruto.
  Como en el registro actual del propietario, se usa **último costo de compra**,
  no promedio: si varias líneas afectan una misma base, prevalece el costo
  convertido de la última línea. No se modifican precios de venta.
- El comprobante incluye la cabecera, detalles canónicos y stock/costo/revisión
  anterior y posterior. Un costo anterior desconocido permanece `null`; un
  costo nuevo cero solo corresponde a una compra explícitamente con costo cero.
  Repetir el mismo UUID y payload devuelve el comprobante original, incluso
  después de operaciones posteriores, sin volver a afectar inventario. No es
  una consulta del stock actual ni debe aplicarse como tal a una caché.
- [StaffPurchasesRepository](lib/features/purchases/data/repositories/staff_purchases_repository.dart)
  conecta el núcleo desde Dart: revalida módulo y membresía, fija el token y
  exige la misma sesión y generación. Antes de enviar persiste UUID y payload
  inmutables mediante
  [StaffPurchaseOutbox](lib/features/purchases/data/repositories/staff_purchase_outbox.dart).
  Una respuesta perdida o una caída al guardar la confirmación conserva la
  solicitud para recuperar exactamente la misma operación; no genera otra compra.
- La migración SQLite **51** agrega únicamente `staff_purchase_operations` y
  un índice que permite una compra incierta por cuenta y billar. Conserva las
  operaciones confirmadas con su comprobante, sin sobrescribir las tablas de
  compras, productos, ventas o colas del propietario. La migración desde 50
  preservó datos anteriores y pendientes de venta en la prueba aislada; también
  pasaron las migraciones previas de promociones y caché de venta.
- El cliente valida actor, billar, UUID, cabecera, total, detalles, conversiones
  y revisiones del comprobante antes de confirmarlo localmente. Una respuesta
  nula, malformada o incoherente no libera el pendiente. Sin conexión para
  revalidar permisos no inicia ni recupera compras con un fallback de éxito.
  Tampoco descarta automáticamente pendientes por rechazos: falta integrar su
  resolución segura antes de habilitar el módulo completo.
- Validación final: **56 pruebas Flutter en 24 archivos** y **siete pruebas
  PostgreSQL aisladas** aprobadas. Cubren recuperación tras reabrir SQLite,
  persistencia previa al envío, confirmación local fallida, respuestas inválidas,
  sesión cambiada, revocación, conversión de presentaciones, costos, aislamiento,
  permisos cerrados, auditoría y rollback. Una prueba SQL simula la aparición
  tardía de un producto. No sustituyen pruebas concurrentes entre dispositivos
  ni las políticas reales: Flutter simula HTTP y SQL solo se ejecuta en PGlite.
- Análisis de ocho archivos Dart limpio; APK Android debug compilado **sin
  instalarlo**. Permanecen los avisos previos de Gradle/AGP/Kotlin. No se
  modificaron el proyecto Supabase, cuentas, buckets ni instalaciones.
- **Siguiente paso:** lectura de catálogo de compras con padre/piezas y costos
  explícitos, proveedores e historial; cliente persistente de gestión de
  proveedores; pantalla de personal para registrar, recuperar y consultar, sin
  cancelaciones, con tratamiento seguro de rechazos y pruebas de rutas/permisos.
  No montar `PurchasesPage` del propietario ni su sincronizador como atajo.

### Solicitudes adicionales y decisiones aprobadas (16/11/26)

Estos requisitos se incorporan a la cola previa al uso normal de roles. No
representan funcionalidades financieras desplegadas ni permisos habilitados.

1. **Jugador:** verificar el detalle propio con las mismas estadísticas que
   consulta el administrador; el portal ya enlaza `PlayerDetailPage` en modo
   lectura. Completar retas/training y opciones de victoria ya disponibles en
   registro de partidas. Las retas suman estadísticas competitivas; training no.
   El repositorio actual de enfrentamientos todavía suma ambos jugadores sin
   distinguir el tipo. No reclasificar partidas históricas por suposición.
2. **Caja y turnos:** se aprobó separar la operación de `Informes → Caja`,
   que quedará solo para consulta. El permiso de operar caja será independiente
   del de informes. Aperturas/cierres, retiros, gastos, conceptos y tickets
   pertenecen al apartado operativo, con actor, billar y turno identificables.
   - Efectivo físico esperado = fondo inicial + cobros/entradas en efectivo
     de esa caja - pagos/retiros en efectivo de esa caja.
   - Tarjeta y transferencia no modifican el cajón. Se desglosan por medio y
     participan en el flujo total de cobros/pagos, que no equivale a utilidad.
   - Una factura a crédito genera deuda; no representa pago ni salida hasta
     su liquidación. No restar dos veces la compra y el pago relacionado.
   - El cierre debe pedir efectivo contado y mostrar diferencia, con opción
     explícita de cerrar y abrir nuevo turno indicando su fondo inicial.
     No cerrar silenciosamente el anterior al abrir otro. Los tickets de
     movimientos y pagos deben poder reimprimirse sin repetir la operación.
   - **Correcciones pendientes detectadas:** el resumen actual suma ventas
     de todos los medios como efectivo; los auxiliares amplían el rango del
     turno a días completos; el esperado guardado al cierre omite el fondo
     inicial, aunque la pantalla sí lo incluye. Abrir turno cierra el anterior
     automáticamente. Corregir y probar juntos antes de habilitar caja.
3. **Mesas, completado localmente:** Configuración muestra listas separadas
   de juego y comanda mediante `ConfigTablesList`, conservando tipos, IDs,
   orden relativo y acciones de editar/eliminar. Los tipos existentes distintos
   de `Comanda` siguen siendo mesas de juego, incluido el tipo por defecto
   `Billar`. Cada grupo vacío se indica sin ocultar el otro. No se migraron
   datos ni se crearon tipos nuevos.
4. **Cierre de compra:** seleccionar efectivo, tarjeta, transferencia o
   crédito al confirmar, sin confundir medio de pago con origen del efectivo.
   Se aprobó **crédito total en esta etapa**; anticipos y abonos quedan en
   cola para cuentas por pagar. No basta agregar crédito al enum `CashSource`.
5. **Proveedor:** agregar días de crédito y preferencia de pago. Precargar
   las condiciones al confirmar una compra y permitir una excepción solo para
   esa compra, guardando su snapshot y vencimiento sin alterar defaults ni
   compras anteriores. Preparar migraciones SQLite/Supabase y relaciones por
   billar para saldo y futuros pagos auditados/idempotentes.

Los puntos 4 y 5 son **prerrequisitos de la nueva pantalla de Compras de
personal**. Ajustar contratos, modelos, validación de comprobantes y pruebas
antes de conectarla; conservar UUID/payload de operaciones inciertas y datos
históricos. No inventar pagos ni vencimientos históricos durante la migración.
El resto continúa en cola sin despliegue coordinado ni instalación todavía.

Validación de la separación de mesas:

- Tres pruebas de widget cubren listas mixtas, orden relativo, acciones con
  IDs/nombres originales, grupos vacíos y ausencia total de mesas.
- Junto con `config_session_guard_test.dart`, **cuatro pruebas aprobadas**.
  Formato verificado y análisis de los tres archivos Dart implicados limpio.
- La ejecución adicional de `table_business_migration_test.dart` falló:
  su fixture SQLite versión 43 crea solo `billiard_tables` y la actualización
  actual intenta alterar `sale_details`, ausente en ese fixture. Queda
  pendiente revisar esa prueba de migración antes de la validación coordinada;
  no se modificaron el esquema ni las migraciones para la separación visual.

### Migración corregida y adaptación de proveedores/crédito (16/11/26)

- **Resuelto el fallo de migración de mesas:** el fixture versión 43 omitía
  `sale_details`, existente en esa versión. La migración 48 necesita añadirle
  `cost_available`; no correspondía saltarla ni ocultar el error en producción.
  La prueba ahora conserva también una venta con su costo, además de la mesa
  ocupada, su índice y el aislamiento por billar. Se completaron las tablas
  mínimas de los otros fixtures afectados por las migraciones posteriores.
- **SQLite actual: 52.** Añade `credit_days` y `preferred_payment_method` al
  proveedor, y condición, medio, días, vencimiento, importe pagado y saldo a
  compras. Las columnas nuevas de datos anteriores quedan `NULL`: no se
  inventan pagos, deudas ni condiciones. Se probaron conservación de
  proveedores archivados, compras y payloads pendientes sin cambiar sus UUID.
- El formulario de proveedor permite días enteros no negativos y preferencia
  efectivo/tarjeta/transferencia/crédito; ambos datos pueden estar sin definir.
  Cero días significa vencimiento el mismo día, no ausencia de información.
  Las preferencias no registran pagos ni modifican compras anteriores.
- El guardado del proveedor conserva estos campos en su cola offline. La
  descarga valida sus valores y diferencia un campo omitido por un servidor
  antiguo de un `NULL` explícito: lo primero no borra el valor local y lo
  segundo sí permite limpiarlo. Un proveedor con escrituras locales pendientes
  sigue protegido de sobrescrituras por la descarga.
- Nuevo borrador
  [provider_credit_terms_partial.sql](supabase/provider_credit_terms_partial.sql).
  Debe preceder al cliente nuevo y a la RPC de proveedores. Esta RPC admite
  el contrato anterior de ocho campos o el nuevo de diez; una edición antigua
  conserva las condiciones actuales, mientras el contrato nuevo permite
  cambiarlas o limpiarlas explícitamente. No reescribe solicitudes, resultados
  ni auditorías guardadas y mantiene ejecución revocada.
- Nuevo borrador
  [purchase_payment_terms_partial.sql](supabase/purchase_payment_terms_partial.sql):
  añade `payment_condition`, `payment_method`, `credit_days`, `due_date`,
  `paid_amount` y `balance_due` a Supabase, con validación de coherencia.
  `cash_source` puede ser nulo para crédito. Son bases para cuentas por pagar;
  **no hay todavía operaciones de abonos, anticipos ni una cuenta por pagar
  operable**. Los registros históricos no reciben un backfill financiero.
- **Núcleo de Compras de personal adaptado:** las nuevas intenciones pueden
  incluir condiciones explícitas. Efectivo conserva origen caja/cajero;
  tarjeta y transferencia no afectan el cajón. Crédito exige proveedor y
  días, registra pagado **exactamente cero**, saldo igual al total y fecha de
  vencimiento a partir del día de registro UTC del servidor. Solo se admiten
  fechas representables hasta el año 9999.
- La elección de esa compra queda en su comprobante y auditoría, dentro de
  la misma transacción de stock/costos/detalles/movimientos. Una excepción de
  días no cambia al proveedor. Cambiar después sus preferencias no altera la
  compra ni el resultado de repetir su UUID. No se genera un retiro ni pago
  por registrar una factura a crédito.
- La RPC mantiene la firma original de seis argumentos como entrada compatible
  y añade una firma de siete con condiciones explícitas; **ambas siguen sin
  ejecución para `PUBLIC`, `anon` y `authenticated`**. Los payloads antiguos
  permanecen con sus cuatro parámetros, sin inyectarles nuevos valores.
  El outbox restaura ambos formatos y valida saldo, pagado y vencimiento antes
  de confirmar localmente. Una respuesta incoherente conserva el pendiente.
- **Compatibilidad con el propietario:** al descargar una compra a crédito
  se conservan sus condiciones y saldo en SQLite y no se transforma el origen
  nulo en `caja`. El detalle y su PDF muestran crédito, vencimiento y saldo;
  el historial usa un indicador de crédito. Una prueba descarga una factura
  de 250 y verifica que el resumen de efectivo queda exactamente igual.
  Esto no corrige todavía los demás problemas de turnos/caja listados arriba.
- El diagnóstico de despliegue informa las ocho columnas nuevas de
  proveedores/compras y ambas firmas de la RPC, sin consultar datos personales
  ni modificar filas.
- Validación final: **26 pruebas Flutter en 13 archivos**, **cinco pruebas
  PostgreSQL/PGlite**, análisis de **17 archivos Dart** limpio y APK debug
  compilado **sin instalar**. Incluye crédito recuperado después de reabrir
  SQLite, respuesta perdida, rechazo de abonos incluso diminutos, vencimientos
  alterados, contratos antiguos, aislamiento, auditoría y permisos cerrados.
  Se mantienen los avisos previos de Gradle/AGP/Kotlin.
- **Continuación:** la confirmación de pago y sincronización del propietario
  se completaron localmente en la sección siguiente. Siguen pendientes
  catálogo, proveedores, historial y pantalla de personal con recuperación y
  resolución segura de rechazos. Compras de personal sigue bloqueado.

No se ejecutaron estos borradores en Supabase ni se habilitaron roles, Edge
o instalaciones. Se conserva el despliegue coordinado como requisito.

### Confirmación de pagos conectada en Compras (16/11/26)

- El registro del **propietario** ya solicita el pago al confirmar, no al
  preparar el carrito. Precarga la preferencia del proveedor y sus días de
  crédito, y permite cambiarlos solo para esa compra. Cancelar conserva el
  carrito; confirmar no modifica al proveedor.
- Ofrece efectivo, tarjeta, transferencia y crédito. Solo efectivo solicita
  origen caja/cajero. Crédito requiere proveedor y plazo explícito: pagado
  cero, saldo total y vencimiento desde el día UTC de registro. No genera
  salida de caja ni admite anticipos. Se rechazan plazos cuyo vencimiento
  exceda el año 9999 antes de construir una duración que pueda desbordarse.
- Compra, detalles, stock, costos y movimientos de inventario se guardan en
  una sola transacción SQLite. Un fallo de movimiento revierte todo; un cambio
  de sesión durante la confirmación rechaza el registro. Las sincronizaciones
  de stock posteriores también comprueban la sesión original.
- El carrito se limpia después del guardado y antes de imprimir. Si falla el
  comprobante, se informa que la compra ya quedó guardada y puede reimprimirse
  desde el historial, evitando un segundo registro por reintentar la impresión.
  Detalle/PDF incluyen las condiciones financieras.
- El outbox conserva UUID y payload frente a respuesta perdida, reapertura o
  cambio local posterior. Los pendientes antiguos no reciben campos nuevos.
  Las compras nuevas con condiciones usan **`sync_owner_purchase_with_payment`**;
  las antiguas conservan `sync_owner_purchase`. Si falta la entrada nueva en
  el servidor, la compra permanece pendiente: **no se usa una RPC antigua que
  pudiera confirmar ignorando el crédito**.
- La RPC valida pago/saldo, proveedor, detalles, total y vencimiento. No permite
  modificar las condiciones ya registradas, borrarlas mediante un cliente
  antiguo ni inventarlas para compras históricas. La anulación conserva el
  snapshot; para futuras cuentas por pagar deben excluirse compras anuladas.
  Fechas con distinto formato pero el mismo instante son compatibles.
- El diagnóstico de sincronización del propietario informa la presencia de
  las tres entradas RPC. Las columnas de proveedores/compras deben prepararse
  antes de las RPC adaptadas y del cliente. Los propietarios deben actualizar
  sus clientes antes de modificar compras con condiciones nuevas.
- **Validado localmente:** 20 pruebas Flutter en seis archivos, cinco pruebas
  PostgreSQL/PGlite, análisis limpio de diez archivos Dart y APK debug compilado
  sin instalar. Incluye excepción por compra sin cambiar al proveedor, crédito
  sin alterar efectivo, reversión transaccional, sesión cambiada, servidor sin
  RPC nueva, reintento con el mismo UUID, anulación y reaplicación del SQL
  conservando datos. Persisten los avisos previos de Gradle/AGP/Kotlin.
- **Roles todavía no habilitados.** El siguiente bloqueo de Compras es la
  pantalla de personal, con catálogo/proveedores/historial autorizados, cliente
  persistente de proveedores y resolución segura de rechazos. Después deben
  cerrarse los módulos autorizables restantes y validarse el despliegue
  coordinado SQL/RLS/Edge y cliente, con aislamiento, revocación y coexistencia
  con propietarios offline, antes de abrir los gates.

No se ejecutó SQL remoto, no se desplegó Edge, no se instalaron aplicaciones
y no se activaron permisos ni flags de personal.

### Pantalla de Compras de personal y preparación del piloto (16/11/26)

- Se preparó `StaffPurchasesPage`, **deshabilitada por defecto y todavía sin
  conectar al portal**. Permite buscar productos, capturar cantidad y costo
  por presentación, elegir proveedor, confirmar el pago y consultar el resumen
  de las últimas 50 compras. No ofrece cancelaciones ni edición de proveedores.
- El catálogo online incluye costo, producto base y piezas por presentación;
  excluye promociones e inactivos. Un costo desconocido sigue siendo desconocido:
  no se transforma en cero. Se rechazan presentaciones sin base activa.
  Proveedores conservan sus datos completos, plazo y preferencia de pago.
- Las lecturas filtran billar y usan el token de la sesión capturada. Se recorren
  páginas cortas por clave, comprobando orden, duplicados y ámbito, y se verifica
  nuevamente el permiso de Compras antes de entregar resultados. Los datos no
  se escriben en las tablas locales del propietario.
- El historial distingue condiciones históricas sin completar de crédito y
  contado. Valida saldo, pagado y vencimiento, sin inferir pagos antiguos. Para
  una compra anulada se muestra el saldo histórico, no una deuda exigible.
- La confirmación reutiliza el diálogo de pagos y las preferencias del proveedor.
  Los ítems y condiciones se congelan antes de enviar. Tras una respuesta incierta,
  se bloquea una nueva compra y se ofrece recuperar la misma solicitud persistida:
  no se borra, modifica ni sustituye su UUID automáticamente.
- **Para terminar Compras de personal** faltan el cliente persistente de edición
  auditada de proveedores, la resolución segura de rechazos definitivos y la
  conexión al portal con sus pruebas de rutas/permisos. La pantalla preparada
  no implica que estos pendientes estén resueltos ni habilita roles.
- Se añadió
  [private_image_rollout_diagnostic.sql](supabase/private_image_rollout_diagnostic.sql),
  **de solo lectura**. Devuelve únicamente conteos: buckets presentes/públicos,
  imágenes y marcadores, objetos sin billar conocido, referencias fuera del
  billar de su fila y rutas no resueltas. No devuelve URLs ni datos personales,
  no mueve objetos y no cambia políticas o privacidad.
- Este diagnóstico no verifica el host ni decodifica URLs, y no sustituye pruebas
  contra la API. Referencias externas, no canónicas o codificadas requieren revisión;
  ningún resultado se presenta como autorización automática de privatización.
- **Pruebas reales por etapas:** se puede comenzar ahora por el preflight de
  solo lectura y las imágenes del propietario con un cliente compatible.
  Después se prueban cargas/lecturas autenticadas, tickets, caché offline y
  denegación sin sesión o desde otro billar. Con esos resultados se revisa y
  autoriza el cambio de los tres buckets, independientemente de los módulos
  de negocio que sigan pendientes.
- Un piloto posterior de personal debe limitarse a módulos expresamente
  preparados y desplegados en conjunto con Auth/Edge/RPC/RLS; los demás deben
  permanecer bloqueados. No hace falta terminar todas las mejoras de jugadores
  y caja para empezar ese piloto, pero no equivale a habilitar uso diario libre.
- **Validación local:** 27 pruebas Flutter en seis archivos, cuatro pruebas
  PostgreSQL/PGlite, análisis limpio de cuatro archivos Dart y APK debug
  compilado sin instalar. Incluye interacción real del widget para crédito,
  bloqueo de nueva intención y recuperación del mismo payload; se mantienen
  pruebas de persistencia, aislamiento, revocación y caché privada sin fallback
  después de una denegación. El diagnóstico detectó rutas ajenas y no resueltas
  sin cambiar buckets en la base aislada.

No se ejecutaron pruebas contra Supabase real en esta etapa. Los buckets no se
modificaron, no hubo instalaciones y los flags de personal permanecen cerrados.

### Preflight real de Storage recibido (16/11/26)

- El usuario ejecutó el diagnóstico de solo lectura en el proyecto actual.
  Los tres buckets existen y continúan públicos.
- `product_images`: una imagen y dos marcadores; `player_avatars`: cero
  imágenes y dos marcadores; `promo_images`: sin imágenes ni marcadores.
  No se detectaron objetos de imagen sin billar conocido.
- Solo se reportó una referencia, del logo: ruta resuelta, dentro del billar
  de su fila y canónica según el diagnóstico. No se detectaron referencias
  externas/no canónicas ni rutas pendientes en los campos examinados.
- Los cuatro marcadores de carpeta no son imágenes y no requieren borrarse.
  Este resultado no justifica mover, borrar ni recrear objetos.
- Queda despejada la revisión estructural de las referencias reportadas.
  **No se ha comprobado aún el acceso por la API real ni la compatibilidad de
  la instalación utilizada para las siguientes pruebas.** El resultado no
  valida por sí solo privacidad, aislamiento o funcionamiento offline.
- Siguiente paso: prueba controlada con el cliente del propietario y el logo
  existente, incluyendo solicitud autenticada, vista previa/reimpresión de
  un comprobante existente y reapertura offline sin borrar datos ni crear
  ventas. Después se coordina el cambio de privacidad y se comprueban accesos
  permitidos/denegados; no se presenta una URL pública funcionando como prueba
  de aislamiento.
- No hace falta esperar las mejoras de jugadores, caja o el cierre de Compras
  para continuar esta validación de Storage. No se autorizaron ni ejecutaron
  cambios de buckets con este resultado.

### Primera descarga real autenticada en Android (16/11/26)

- El usuario eligió Android y autorizó actualizar M2004J19C, confirmando la app
  cerrada y sin operaciones en curso. Se utilizó exclusivamente `adb install -r`;
  no hubo desinstalación ni comandos de borrado de datos.
- El SHA-256 del APK instalado coincide con el APK validado localmente. La app
  abrió correctamente. No se operó en A60L ni en otros dispositivos.
- Se añadió una señal solo de depuración después de un HTTP 200 de la descarga
  autenticada: bucket y cantidad de bytes, sin URL, ruta, usuario ni token.
  La lectura de logs se limitó a esa señal del proceso de esta app.
- **Confirmación real:** `product_images`, HTTP 200 autenticado, **3.061.938 bytes**.
  Corresponde al único objeto de imagen reportado por el preflight, el logo.
  No se presenta una copia de caché como prueba de descarga remota.
- La señal se validó con dos pruebas Flutter dirigidas, análisis limpio del
  servicio y nueva compilación de APK antes de instalar.
- Pendientes: confirmación visual del logo, vista previa/reimpresión de un
  comprobante existente y reapertura offline sin borrar datos ni crear ventas.
  No se modificaron buckets ni roles. La descarga autorizada en un bucket
  todavía público no demuestra por sí sola el aislamiento tras privatizarlo.

- Resultado manual del usuario: **logo visible con internet** y **reapertura
  sin Wi-Fi/datos conservando el logo**. No hay comprobantes disponibles; la
  prueba visual de ticket no se realizó y no se contará como aprobada.
  Los accesos existentes a vista previa de ticket requieren una venta previa;
  no se registrará una venta ficticia solo para completar esta comprobación.
- El siguiente hito es autorizar y coordinar el cambio de privacidad, verificar
  nuevamente el acceso autenticado del propietario y el rechazo de la URL
  pública sin sesión. La prueba visual del ticket queda señalada para cuando
  exista un comprobante o una vista previa independiente segura.
- El usuario autorizó expresamente pasar al cambio de privacidad de los tres
  buckets. La autorización se limita a
  [private_image_storage_partial.sql](supabase/private_image_storage_partial.sql),
  ejecutado completo y de forma coordinada; no habilita otros borradores,
  creación de personal ni flags de roles.
- Se añadieron límites locales de bloqueo de tres segundos y ejecución de
  treinta segundos a su transacción; se volvió a aprobar la prueba aislada de
  políticas. **La aplicación remota sigue pendiente de ejecución y confirmación
  por el usuario**; no se marcarán buckets privados antes de recibir el resultado.
- La verificación posterior enviada por el usuario todavía devuelve
  `public = true` para los tres buckets. El usuario aclaró que recibió la
  consulta de verificación, pero necesita el script completo pegado en el chat,
  no solo el enlace al archivo. El cambio sigue sin aplicarse; se entrega el
  contenido completo antes de continuar con las pruebas de acceso privado.

### Privacidad de buckets confirmada por consulta remota (16/11/26)

- Tras entregar el script completo, el usuario reportó `public = false` para
  `player_avatars`, `product_images` y `promo_images`. Queda confirmado el
  indicador de privacidad de los tres buckets, no todavía el aislamiento por API.
- Continúan pendientes la descarga autenticada del propietario después del
  cambio, el rechazo de la URL pública sin sesión y la comprobación con otra
  cuenta autorizada de prueba. Las pruebas online/offline anteriores al cambio
  no se contarán como validación posterior.
- No se habilitaron roles ni se desplegaron los otros scripts preparados.
  La prueba visual de ticket sigue pendiente por no haber comprobantes.
- Después del cambio, el usuario reabrió la app con internet en M2004J19C y
  confirmó el logo visible. La lectura limitada al proceso actual y a eventos
  posteriores al inicio de esta comprobación registró nuevas descargas
  autenticadas HTTP 200 de `product_images`, de **3.061.938 bytes** cada una.
  Queda validado el acceso real del propietario después de privatizar, no solo
  la caché. Siguen pendientes la denegación anónima y el aislamiento entre cuentas.
- Se probó la antigua URL pública del logo existente mediante GET sin
  `Authorization`, sin seguir redirecciones y evitando caché con un parámetro
  de prueba. Se descartó el cuerpo en la primera solicitud; una segunda lectura
  acotada confirmó **HTTP 400**, con `statusCode: 404` y
  `error: Bucket not found` de Storage. No se descargó la imagen sin sesión.
  La URL real no se guarda en este documento.
- Queda validada la denegación anónima para el logo de `product_images`.
  No se presenta como prueba de acceso autenticado entre billares ni como
  descarga probada en los otros buckets, que no contienen imágenes actualmente.
  Faltan la reapertura offline posterior al cambio y la prueba entre cuentas
  cuando haya cuentas de prueba autorizadas.
- El usuario confirmó la reapertura **posterior al cambio**, sin Wi-Fi ni datos:
  la app abre y muestra el logo. Quedan aprobadas para el propietario la descarga
  autenticada y la continuidad offline, y para el logo la denegación anónima.
- El usuario no dispone de otra cuenta autorizada de un billar distinto.
  La prueba de aislamiento entre cuentas queda pendiente por ese motivo;
  no se crearon cuentas ni se abrió ningún rol para suplirla.
  Este límite no impide continuar la implementación local de los módulos
  pendientes, pero no permite declarar validado el aislamiento entre cuentas.

### Cliente persistente de proveedores de personal (16/11/26)

- Se integraron alta, edición y archivado de proveedores a la pantalla
  preparada de Compras de personal. Conserva `enableForIntegration = false`
  por defecto y todavía no está conectada al portal ni a las rutas de personal.
  No se modificaron los flags globales, cuentas, grants ni datos remotos.
- [StaffProviderDraft](lib/features/purchases/domain/entities/staff_provider_operation.dart)
  congela UUID, ID de proveedor, operación, diez campos y relaciones. Reutiliza
  `ProviderEntity` para las condiciones de pago y el patrón de ID del
  propietario; restaurar/reintentar nunca genera un ID nuevo.
- SQLite pasa a **53**: añade exclusivamente `staff_provider_operations`,
  separada de las colas del propietario y de compras, con una sola solicitud
  pendiente por actor y billar. El comprobante se conserva después del éxito.
  Las migraciones anteriores y la creación de bases nuevas siguen incluyendo
  sus tablas; no se reescriben compras ni payloads pendientes.
- [StaffProvidersRepository](lib/features/purchases/data/repositories/staff_providers_repository.dart)
  exige permiso online `purchases` antes y después de operar, fija el token
  capturado y comprueba la sesión. Persiste antes de llamar a la RPC auditada;
  no utiliza el repositorio ni la sincronización del propietario.
- La lectura de relaciones pagina por ID hasta una página vacía, incluso con
  páginas cortas, mediante el proveedor unido y filtrado por billar. Rechaza
  relaciones de otro proveedor/billar, repetidas o desordenadas. El formulario
  conserva las relaciones cuyos productos ya no aparecen en el catálogo;
  retirarlas requiere desmarcarlas explícitamente.
- El formulario permite editar los datos del proveedor, días de visita,
  productos, días de crédito y pago preferido. Días vacíos siguen sin definir;
  cero conserva su significado. No modifica compras históricas ni registra
  pagos. Archivar pide confirmación y no ofrece borrado físico.
- El comprobante se valida contra actor, billar, UUID, proveedor, operación,
  estado activo, campos financieros y relaciones solicitadas. Una RPC ausente,
  respuesta perdida/inválida, revocación o fallo al guardar el comprobante
  conserva la intención para recuperar la misma solicitud. Mientras haya un
  cambio de proveedor incierto, la pantalla bloquea nuevas operaciones.
- Validación final: **33 pruebas Flutter en seis archivos**, incluidas
  migración desde 52, reapertura de SQLite, respuesta perdida, fallo de commit,
  recibos inválidos, revocación/cambio de sesión, relaciones y formulario.
  La prueba de pantalla comprueba bloqueo y rehabilitación de los botones de
  proveedor tras recuperar, sin reenviar una intención nueva.
- Pasaron **dos pruebas PostgreSQL aisladas** de compras/proveedores auditados;
  análisis de ocho archivos Dart sin problemas y APK Android debug compilado
  **sin instalarse**. Persisten los avisos previos de Gradle/AGP/Kotlin; no se
  actualizaron dependencias.
- Siguiente paso: protocolo seguro de rechazos definitivos para liberar solo
  solicitudes que el servidor confirme que no se aplicaron; después, conectar
  Compras al portal/rutas y validar permisos antes del despliegue coordinado.
  Los pendientes inciertos todavía no tienen botón de descartar.

### Resolución definitiva y conexión de Compras al portal (16/11/26)

- Se preparó
  [staff_purchase_resolution_partial.sql](supabase/staff_purchase_resolution_partial.sql)
  con la RPC `resolve_staff_purchase_request`, para compras y operaciones de
  proveedores. Requiere las dos RPC y sus tablas de solicitudes anteriores;
  no se debe desplegar aisladamente ni antes de esas dependencias.
- Exige identidad confiable de personal, billar coincidente, membresía activa,
  contraseña cambiada y permiso `purchases`. Bloquea la membresía y utiliza la
  misma inserción idempotente y bloqueo de fila que la operación original.
  Un UUID de otro actor, billar o payload se rechaza sin devolver su resultado.
- Si la operación ya se aplicó, devuelve su comprobante original y no cancela
  compras ni revierte proveedores. Si no se aplicó, deja un resultado terminal
  `not_applied_closed` ligado a tipo, UUID, actor, billar y payload. Una petición
  original que llegue después devuelve ese cierre sin ejecutar cambios.
  No se confunde una consulta sin filas con la imposibilidad de recibir
  peticiones tardías.
- El cierre persiste en el ledger del servidor y en la columna `receipt` de la
  cola local; no se borra la solicitud ni se modifica su payload. SQLite sigue
  en **53**. Se validan identidad, tipo, motivo y contenido completo, incluidas
  condiciones financieras y detalles; el orden de claves JSON no altera la
  comparación del payload.
- La notificación de rechazo se emite después de confirmar la transacción
  SQLite. Si falla la red, falta la RPC, cambia/revoca la sesión, la respuesta
  es inválida o no se puede guardar el comprobante, el pendiente se conserva.
  Reenviar un UUID ya cerrado localmente no vuelve a llamar a la operación.
- En las tarjetas pendientes se añadió la verificación de cierre, separada de
  recuperar/reintentar. Antes de contactar al servidor explica y confirma
  ambos resultados posibles. Solo una respuesta terminal validada libera la
  pantalla para corregir y enviar una intención nueva; no hay borrado local
  arbitrario ni cancelación de compras aplicadas.
- [StaffRouteGate](lib/features/auth/presentation/pages/staff_route_gate.dart)
  conecta la tarjeta y ruta de Compras a la pantalla de personal. Exige
  `purchases`; `inventory` o `reports` no abren esa ruta. La tarjeta indica
  registro/proveedores sin cancelaciones. El router sigue enviando las cuentas
  de personal al gate, no a la pantalla del propietario.
- Se mantiene el opt-in de integración y el acceso normal de personal cerrado.
  No se cambiaron flags de gestión, cuentas, grants ni Edge, y no se ejecutó SQL
  remoto. El diagnóstico de despliegue ahora incluye la RPC de resolución.
- Validación: **35 pruebas Flutter en tres archivos**, con respuesta aplicada
  perdida, cierre perdido, recibos alterados, crédito, cambio/revocación de
  sesión, fallo de commit, reapertura de SQLite, no reenvío del UUID cerrado,
  confirmación/cancelación del diálogo y rehabilitación de acciones.
- El flujo completo simulado verifica login/cambio de contraseña, tarjeta de
  Compras, rechazo de ruta directa sin permiso, acceso con `purchases`,
  revocación al reanudar, retiro de datos y bloqueo por defecto. Los callbacks
  HTTP del test usan `expectSync` para no competir con el bombeo asíncrono de
  widgets mientras se abre SQLite.
- Pasaron **tres pruebas PostgreSQL aisladas**: cierre antes de una petición
  original tardía (legacy y financiera), recuperación después de aplicar,
  cierres repetidos, fallo original sin efectos, aislamiento por actor/billar,
  permisos y diagnóstico con ejecución aún revocada. Se validaron ambos órdenes
  secuenciales; no equivalen a una prueba concurrente de la API real de Supabase.
- Análisis de diez archivos Dart sin problemas y APK Android debug compilado
  **sin instalarse**. Persisten los avisos previos de Gradle/AGP/Kotlin.
- Los dos bloques solicitados quedan implementados y validados localmente.
  Sigue el diagnóstico remoto y el despliegue coordinado de esquema, RPC/RLS,
  Edge y cliente, con piloto autorizado por módulos. Las pruebas reales de
  cuentas de personal, aislamiento entre cuentas y concurrencia siguen
  pendientes; no se declara habilitación de roles en producción.

### Diagnóstico remoto y lote agrupado de preparación de personal (16/11/26)

- Diagnóstico recibido: los seis campos de membresía están instalados, con
  índice de usuario y restricciones validadas. No hay cuentas de personal ni
  incompatibilidades de datos. Faltan las nueve tablas de solicitudes/auditoría,
  las funciones de personal y las ocho columnas financieras de compras/proveedores.
- `SELECT` concedido a `anon` sobre membresías no demuestra exposición: sigue
  instalada la política restrictiva `owner_no_anon` con ambas condiciones falsas.
  Los tres buckets ya fueron confirmados privados; no se vuelve a pedir esa prueba.
- Se generó `supabase/staff_rollout_install.sql`, archivo completo para ejecutar
  en SQL Editor. Agrupa doce fuentes en **una transacción**, sin sus `BEGIN`/
  `COMMIT` individuales. Se reproduce con
  `node supabase\build_staff_rollout.cjs`; la prueba comprueba que el SQL entregado
  coincide con las fuentes. No ejecutar los borradores por separado.
- Antes de modificar el esquema, bloquea cambios concurrentes de membresías y
  exige cero cuentas de personal, campos previos, guardas base RLS/anon y los tres
  buckets privados. Si falta un prerrequisito se detiene, sin inventar datos.
- Instala primero condiciones financieras y actualiza la RPC financiera del
  propietario, preservando la firma legacy. Después instala cuentas, guardas,
  ventas, proveedores, compras y resolución definitiva. No vuelve a aplicar el
  aislamiento owner sobre las nuevas políticas de personal.
- Al final revoca y verifica el acceso `anon`/`authenticated` a **todas las
  firmas** de los endpoints de personal. Mantiene los permisos de los helpers
  usados por RLS y las concesiones de servicio necesarias para Edge. No crea
  cuentas ni activa flags, y no instala ninguna APK.
- Conserva las políticas existentes de Storage y los buckets privados; el
  guard de módulos añade únicamente restricciones de escritura de avatares.
  El diagnóstico de salida se ejecuta después del `COMMIT`: un error anterior
  revierte la instalación; ante cualquier error detenerse, ejecutar `ROLLBACK;`
  y revisar el mensaje antes de continuar.
- Validación: once pruebas PostgreSQL/PGlite relacionadas aprobadas, incluida
  la instalación agrupada dos veces, rollback de un fallo inyectado antes del
  commit, conservación de datos y políticas previas, lectura/escritura del
  propietario, aislamiento de otro billar, crédito idempotente, denegación
  anónima y bloqueo de RPC de personal. No equivalen a pruebas remotas reales.
- **El usuario ejecutó el lote y entregó el diagnóstico remoto satisfactorio.**
  Están instaladas las nueve tablas nuevas con RLS, todas las funciones y las
  ocho columnas financieras. Continúa sin cuentas de personal y con todos sus
  endpoints cerrados a `authenticated`. Jugadores/caja permanecen en cola.

### Piloto de tres módulos preparado después de instalar la base (16/11/26)

- El resultado real mostró `EXECUTE anon` en dos helpers por las concesiones
  predeterminadas de Supabase. Se corrigieron los dos scripts para revocar
  explícitamente `PUBLIC`, `anon` y `authenticated`, devolviendo el permiso
  necesario a `authenticated`. El archivo agrupado se regeneró; **no hace falta
  repetir la instalación remota**, porque la activación corrige los helpers ya
  instalados. No se detectó acceso anónimo a filas a partir de ese diagnóstico.
- `staff_pilot_activation.sql` abre solo catálogo/venta/conciliación,
  compras/proveedores/resolución y consulta administrativa de personal.
  Creación, finalización, contraseña y actualización de cuentas continúan
  restringidas al servicio. Conserva RLS y Storage privado y rechaza cuentas
  asignadas a módulos ajenos al piloto. Ejecutarlo solo después de desplegar Edge.
- Edge queda habilitable con el secreto `STAFF_PILOT_ENABLED=true`, deshabilitado
  por omisión. Tanto altas como cambios rechazan módulos distintos de
  `quick_sale`, `inventory`, `purchases`; el formulario ofrece solo esos tres.
  El contrato general de módulos se conserva para no reinterpretar datos.
- El cliente se activa únicamente al compilar con
  `--dart-define=STAFF_PILOT_ENABLED=true`. El router normal entrega el opt-in
  a login, inicio y portal, y Configuración habilita la gestión. Las
  compilaciones normales y las llamadas de integración sin opt-in siguen
  bloqueadas por defecto.
- Validación: 24 pruebas Node/PGlite relacionadas aprobadas, incluida activación
  repetida, cuentas fuera del piloto y concesiones predeterminadas como las
  remotas. Cinco pruebas Flutter estándar aprobadas; además pasó el flujo
  completo compilado con el flag del piloto y usando el router de entrada real.
  Análisis de seis archivos Dart sin problemas y `deno check` del entrypoint
  Edge aprobado mediante npm, sin ejecutar ni desplegar la función.
- APK debug del piloto compilado correctamente, **sin instalarse**. Persisten
  los avisos previos de Gradle/AGP/Kotlin. No se ejecutaron conexiones remotas
  adicionales ni se buscaron credenciales.
- Pendiente externo: configurar el HMAC del servidor sin compartirlo y sin
  rotarlo si existe, desplegar `player-admin` completo, confirmar el despliegue,
  ejecutar la activación SQL y autorizar actualización sin borrar datos.
  La CLI disponible se verificó con `functions deploy --help`: usa
  `--remote=<project-ref> --use-api`, sin Docker ni vinculación a PostgreSQL.

### Activación remota y actualización Android realizadas (16/11/26)

- El usuario inició sesión en la CLI y confirmó el despliegue de `player-admin`.
  **La CLI quedó operativa con esa nueva sesión**: ya no aplica el bloqueo
  anterior de conexión para estos pasos. No se buscaron credenciales ni se
  volvieron a intentar conexiones directas con contraseña de PostgreSQL.
- Se confirmó que el HMAC ya existía y se conservó, sin imprimir ni guardar su
  valor. Se creó únicamente `STAFF_PILOT_ENABLED=true`; la API confirmó el cambio.
  No volcar listados de secretos: la CLI actual incluye un campo `value`.
- Se ejecutó remotamente `staff_pilot_activation.sql` mediante
  `npx supabase db query --remote=<ref> --file <archivo> --yes`.
  Usar `--file` en Windows: el intento de SQL multilínea como argumento llegó
  vacío y recibió HTTP 400, sin aplicar cambios. El archivo sí se ejecutó.
- Una consulta independiente de solo lectura verificó la persistencia:
  **17 firmas presentes, cero endpoints anónimos, seis endpoints de cuentas
  solo al servicio**, permisos de cliente previstos, tablas con RLS y columnas
  financieras instaladas. Continúa sin cuentas de personal creadas.
- Después de configurar el flag se redesplegaron desde este repositorio los
  seis archivos exactos de Edge previamente validados. La CLI confirmó éxito.
- El usuario autorizó explícitamente actualizar M2004J19C sin borrar datos.
  `adb install -r` devolvió **Success** y se abrió la actividad principal.
  Android confirmó versión 2.0.0 y actualización realizada; el proceso continúa
  ejecutándose. No se desinstaló, no se borraron datos y no se tocó otro teléfono.
- El filtro de señales de inicio no devolvió confirmación `App services ready`
  ni un fallo de inicialización. No se considera eso una prueba de interfaz ni
  de migración real completa. Falta que el usuario abra **Configuración >
  Personal** y confirme `AGREGAR USUARIO` o comunique el mensaje mostrado.
- Ya no se necesita que el usuario busque `project_ref`, configure el flag ni
  copie SQL. Sigue el primer acceso real de administrador/personal, cambio
  obligatorio de contraseña y pruebas autorizadas de los tres módulos,
  revocación y aislamiento. No crear cuentas ni operaciones ficticias por rutina.

### Diagnóstico del botón ausente al volver a ejecutar desde VS Code

- El usuario vio Personal sin botón de alta. Se inspeccionó exclusivamente la
  app M2004J19C del workspace actual mediante Dart SDK/VM Service.
  Configuración y `StaffManagementSection` estaban construidas; la evaluación
  directa confirmó **`staffPilotEnabled=false` y
  `_staffManagementEnabled=false`** en la ejecución real.
- Había una nueva sesión de depuración y el APK local se había recompilado
  después de la actualización autorizada: el arranque de F5 no enviaba el flag.
  No era evidencia de un fallo de permisos de Supabase.
- Se añadió `--dart-define=STAFF_PILOT_ENABLED=true` al perfil existente
  **App Integral (Supabase)** en `.vscode/launch.json`, conservando su carga de
  configuración y el perfil stub. No se leyeron los valores de `.env`.
- El usuario detuvo la ejecución y arrancó de nuevo con ese perfil en
  M2004J19C; confirmó **«Aparece AGREGAR USUARIO y carga sin errores»**.
  Queda validado el acceso administrativo real a Personal. Hot reload/restart
  no cambia los argumentos de compilación de la sesión.
- No hace falta más SQL ni cambiar secretos para comenzar el piloto.
  Sigue crear desde la app una cuenta autorizada, entregar su contraseña
  temporal fuera del chat y comprobar cambio obligatorio, módulos, revocación
  y operaciones reales autorizadas. No se creó ninguna cuenta de prueba.

### Depuración simultánea de los dos teléfonos

- Se añadieron perfiles con destino explícito para **Personal - M2004J19C**
  y **Administrador - A60L**, y el compuesto **Ambos telefonos (piloto)**.
  Ambos conservan la configuración Supabase y el flag del piloto.
- Con autorización del usuario se detuvo la sesión anterior y se inició el
  compuesto desde VS Code, sin desinstalar ni borrar datos o cambiar cuentas.
  Los nombres de los perfiles no seleccionan automáticamente el rol del usuario.
- VS Code mostró **dos sesiones activas**. DTD confirmó ambas conexiones;
  cada VM respondió por separado, con Android arm64 en M2004J19C y Android
  arm en A60L. Los dos isolates principales estaban ejecutándose
  (`pauseEvent.kind=Resume`), sin errores de ejecución registrados al consultar.
  Esto verifica el arranque dual, no las operaciones reales de cada módulo.
- Se validó el JSON, los dos destinos distintos y el flag en ambos perfiles.
  README explica cómo alternar los registros mediante **Sesión de depuración**.
  Detener una sesión del compuesto detiene las dos; los perfiles individuales
  permiten iniciarlas por separado.
- Continúan pendientes la imagen del negocio en A60, simplificar la contraseña
  temporal y definir permisos efectivos por módulo/subcategoría. No se ampliaron
  permisos del piloto ni se realizaron operaciones ficticias para este arranque.

### Inicio de personal con identidad del negocio y cards originales

- Se reemplazó la lista del portal por un inicio con `HomeHeader`, `HomeLayout`
  y `ModuleCard`. Administrador y personal comparten el catálogo visual
  `home_modules.dart`; personal filtra por módulos asignados e integrados.
  Las rutas operativas siguen pasando por `StaffRouteGate` y sus verificaciones.
- El encabezado muestra el usuario validado de la membresía, no el nombre del
  perfil de VS Code ni una etiqueta administrativa. Incluye nombre del negocio,
  logo privado, color, búsqueda y categorías de las cards disponibles.
- Se añadió `staff_business_profile.sql`: devuelve exclusivamente billar,
  nombre, logo y color para una membresía de personal activa, del mismo billar
  y sin cambio de contraseña pendiente. No concede acceso directo a la tabla
  de configuración. Fallos o respuestas de otro billar bloquean el inicio con
  un error y opción de reintentar, sin reutilizar identidad de otra cuenta.
- Con autorización expresa se aplicó solamente esta actualización incremental
  al proyecto remoto y se recargó la app de personal. Una consulta independiente
  confirmó la función instalada, ejecución autenticada y **sin ejecución anon**.
  La instalación agrupada, activación y diagnóstico incluyen la nueva función
  para proyectos nuevos; no se reaplicó la instalación agrupada al piloto.
- En el teléfono de personal se verificó la membresía real con los tres módulos
  del piloto, identidad cargada y ausencia de error en el guard. El cargador
  privado del logo completó su descarga con **3 061 938 bytes**. No se imprimieron
  tokens ni URLs privadas. La app del A60 no fue reiniciada ni se da por resuelto
  su reporte anterior de imagen.
- Validación: seis pruebas Flutter aprobadas (flujo de acceso y cards, usuario
  visible, respuesta de otro billar, actualización de permisos, logo de dueño
  e imágenes privadas); tres pruebas PostgreSQL/PGlite aprobadas para lectura
  limitada, instalación y diagnóstico. Análisis Dart de los ocho archivos
  involucrados sin incidencias. No se realizaron ventas ni compras de prueba.
