# PENDIENTES - Baumar POS

## Última actualización
2026-07-30

## Cambios implementados recientemente
1. Splash page robusto: no se atasca si no hay internet. Muestra "SIN CONEXIÓN - MODO LOCAL".
2. Sincronización del logo del negocio:
   - Se sube a Supabase Storage (bucket `product_images/logos/`).
   - Se guarda la URL en `billar_settings.logo_url`.
   - Se descarga en todos los dispositivos al iniciar.
   - En Windows se usa `file_picker` para seleccionar imagen del disco.

---

## Pendientes por implementar

### 1. Verificar sincronización del logo
**Prueba a realizar:**
- Limpiar datos locales en Android y Windows.
- Recompilar e instalar en ambos.
- Cambiar logo en Windows y verificar que aparezca en Android.
- Cambiar logo en Android y verificar que aparezca en Windows.
- Probar sin internet: el logo local debe seguir visible.

**Si falla:**
- Revisar que el bucket `product_images` tenga permisos de escritura para usuarios autenticados.
- Revisar que la columna `logo_url` exista en `billar_settings`.
- Revisar logs de `ConfigRemoteRepository`.

### 2. Imágenes de productos offline
**Problema:**
- Las imágenes de productos se guardan como URL de Supabase Storage.
- Sin internet no se ven.

**Solución propuesta:**
- Usar `cached_network_image` para cachear automáticamente las imágenes.
- Mostrar un placeholder cuando no hay imagen ni conexión.

**Archivos a revisar:**
- `lib/features/inventory/presentation/pages/inventory_page.dart`
- `lib/features/inventory/presentation/widgets/product_sale_card.dart`

### 3. Mensaje de "Sin conexión" más visible
**Problema:**
- El mensaje solo aparece en el splash cuando hay sesión guardada y falla el refresh.
- No hay indicador en el home, inventario, ventas, etc.

**Solución propuesta:**
- Agregar un widget pequeño en el AppBar o HomeHeader que muestre un icono de wifi_off cuando no haya conexión.
- Usar `connectivity_plus` que ya está en las dependencias.

### 4. Flujo de compras con productos padre/hijo
**Problema:**
- En compras se muestran todos los productos excepto promociones, incluyendo hijos (cajas/presentaciones).
- Comprar un hijo puede tronar la app o generar cálculos incorrectos de stock/costo.

**Opciones a definir:**
- **Opción A:** En compras mostrar solo padres y productos simples. Los hijos no aparecen.
- **Opción B:** Mostrar padres e hijos, pero preguntar si la cantidad es en piezas o cajas.
- **Opción C:** Mostrar padres e hijos y convertir automáticamente cajas a piezas del padre.

**Archivos a modificar:**
- `lib/features/purchases/presentation/pages/purchases_page.dart` (filtro de productos)
- `lib/features/purchases/data/repositories/purchases_repository.dart` (lógica de stock/costo)

**Nota adicional:**
- El cálculo de costo actual sobreescribe el costo del padre con la última compra. Debería promediar o usar alguna lógica definida.

### 5. Guardar producto sin internet y avisar
**Problema:**
- Al guardar un producto sin conexión, si intenta subir imagen puede quedarse atorado o fallar silenciosamente.

**Solución propuesta:**
- Detectar sin conexión antes de guardar.
- Guardar localmente y marcar como no sincronizado.
- Mostrar mensaje: "Guardado localmente. Se sincronizará cuando haya internet."

### 6. Preguntar al cliente antes de borrar datos de Supabase
**Para producción:**
- Nunca usar `TRUNCATE` sin respaldo.
- Preguntar al cliente con algo como: "¿Quiere reiniciar la información de su negocio? Esto borra ventas, productos, compras y jugadores, pero mantiene la configuración de la app."

**SQL de limpieza para pruebas (NO PRODUCCIÓN):**
```sql
TRUNCATE TABLE products, billiard_tables, sales_history, sale_details,
  purchases, purchase_details, providers, provider_products,
  inventory_movements, cash_outflows, cashier_sessions,
  players, match_results, pending_sales, categories, promo_items,
  temp_reservations, billar_settings
RESTART IDENTITY CASCADE;
```

---

## Dudas por resolver con el usuario
1. ¿Qué opción prefiere para el flujo de compras padre/hijo? (A, B o C)
2. ¿El indicador de "Sin conexión" debe estar siempre visible en el home o solo en ciertas pantallas?
3. ¿Se quiere limitar a un solo dispositivo activo por usuario en el futuro?

---

## Notas técnicas
- Las sesiones son independientes por dispositivo. Hacer login en uno no cierra la sesión en otro.
- El tema (oscuro/claro) es local por dispositivo.
- Los datos del negocio (nombre, color, tarifa, mesas, logo) se sincronizan por Supabase.
