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
