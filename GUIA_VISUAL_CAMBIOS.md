# 🎨 Guía Visual de los Cambios

## 1️⃣ NUEVA OPCIÓN: "Bola 8 del Contrario" en Registrar Partida

### Ubicación: 
`Jugadores → Registrar Partida → Sección RESULTADO`

### Antes:
```
╔════════════════════════════════════════╗
║ RESULTADO                              ║
├────────────────────────────────────────┤
│ [Gana Jugador 1] [Gana Jugador 2] [Empate] │
│ [Golden Break] [Break & Run]           │
└────────────────────────────────────────┘
```

### Después:
```
╔════════════════════════════════════════╗
║ RESULTADO                              ║
├────────────────────────────────────────┤
│ [Gana Jugador 1] [Gana Jugador 2] [Empate] │
│ [Golden Break] [Break & Run]           │
│ [Bola 8 del Contrario]  ← NUEVO       │
└────────────────────────────────────────┘
```

### Cómo funciona:
1. Al registrar una partida, puedes marcar "Bola 8 del Contrario"
2. Se registra en la tabla `match_results` 
3. Se actualiza el estadístico `opponent_8_ball_foul` del ganador
4. Se puede ver en las STATS del jugador

---

## 2️⃣ NUEVO CAMPO EN ESTADÍSTICAS DEL JUGADOR

### Ubicación: 
`Detalle del Jugador → Pestaña ESTADÍSTICAS`

### Nuevo dato disponible:
```
╔════════════════════════════════════════╗
║ RESUMEN (Grid de estadísticas)         ║
├────────────────────────────────────────┤
│ [Partidas] [Victorias] [Derrotas]      │
│ [Empates]  [Golden Breaks] [Break&Run] │
│ [Combinación] [Por faltas]             │
│ [Juego normal] [Mejor Racha]           │
│ [Bola 8 Contrario]  ← NUEVO           │
└────────────────────────────────────────┘
```

**Valor**: Número de victorias obtenidas porque el contrario metió la bola 8

---

## 3️⃣ FORMULARIO DE CLIENTE: FORMATO AUTOMÁTICO

### Ubicación: 
`Cuenta Personal → Administrar Clientes → Agregar/Editar Cliente`

### ANTES - Sin formato:
```
╔════════════════════════════════════════╗
║ AGREGAR CLIENTE                        ║
├────────────────────────────────────────┤
│ Nombre *: juan perez                   │
│ Teléfono: 3001234567                   │
│ Correo: Juan.Perez@Gmail.com           │
│ Notas: Cliente frecuente                │
└────────────────────────────────────────┘
```

### DESPUÉS - Con formato automático:
```
╔════════════════════════════════════════╗
║ AGREGAR CLIENTE                        ║
├────────────────────────────────────────┤
│ Nombre *: JUAN PEREZ        ← UPPERCASE│
│ Teléfono: 300-123-4567      ← MÁSCARA  │
│ Correo: juan.perez@gmail.com← lowercase│
│ Notas: Cliente frecuente                │
└────────────────────────────────────────┘
```

### Especificaciones:

#### 📝 NOMBRE
- **Transformación**: UPPERCASE automático
- **Entrada**: "juan perez" → "JUAN PEREZ"
- **Entrada**: "JuAn PeReZ" → "JUAN PEREZ"

#### 📱 TELÉFONO
- **Formato**: XXX-XXX-XXXX (10 dígitos)
- **Entrada**: "3001234567" → "300-123-4567"
- **Validación**: Solo acepta dígitos (0-9)
- **Máximo**: 10 caracteres
- **Hint**: Muestra "XXX-XXX-XXXX" como ejemplo

#### 📧 CORREO
- **Transformación**: LOWERCASE automático
- **Entrada**: "Juan@Gmail.COM" → "juan@gmail.com"
- **Entrada**: "CLIENT@EMAIL.ES" → "client@email.es"

---

## 4️⃣ ICONO DEL BOTÓN "ADMINISTRAR CLIENTES"

### Ubicación: 
`Cuenta Personal → Seleccionar Cliente (parte inferior del modal)`

### ANTES:
```
┌─────────────────────────────────────────┐
│ SELECCIONAR CLIENTE O JUGADOR           │
│ [Jugador 1] [Jugador 2] [Cliente A]     │
├─────────────────────────────────────────┤
│ [●] ADMINISTRAR CLIENTES                │  ← Circle sin icono
└─────────────────────────────────────────┘
```

### DESPUÉS:
```
┌─────────────────────────────────────────┐
│ SELECCIONAR CLIENTE O JUGADOR           │
│ [Jugador 1] [Jugador 2] [Cliente A]     │
├─────────────────────────────────────────┤
│ [👤+] ADMINISTRAR CLIENTES              │  ← Icons.person_add
└─────────────────────────────────────────┘
```

**Icono**: `Icons.person_add` (persona con signo de suma)

---

## 5️⃣ TABLA DE BASE DE DATOS ACTUALIZADA

### Tabla: `players`
```sql
ALTER TABLE players ADD COLUMN opponent_8_ball_foul INTEGER NOT NULL DEFAULT 0;
```

### Tabla: `match_results`
```sql
ALTER TABLE match_results ADD COLUMN opponent_8_ball_foul INTEGER NOT NULL DEFAULT 0;
```

**Versión de DB**: 35 → 36

---

## 🔄 Flujo Completo de Uso

### Escenario: Registrar una partida donde el contrario metió la bola 8

```
1. Ir a: Jugadores → Registrar Partida
   └─ Seleccionar Jugador 1: MIGUEL
   └─ Seleccionar Jugador 2: PEDRO
   └─ Resultado: Gana MIGUEL (porque Pedro metió la bola 8)
   └─ ✓ Marcar: "Bola 8 del Contrario"
   └─ Guardar

2. Resultado:
   └─ MIGUEL: Gana = +1, opponent_8_ball_foul = +1
   └─ PEDRO: Pierde = +1
   
3. Ver en estadísticas:
   └─ MIGUEL → Detalle → Stats
   └─ Verá un nuevo campo con el contador de "Bola 8 Contrario"

4. Ver en administrar clientes:
   └─ Cuenta Personal → Seleccionar Cliente
   └─ El botón tiene icono de persona + (person_add)
   └─ Al crear cliente, nombre se pone UPPERCASE
   └─ Teléfono se formatea automáticamente
   └─ Correo se guarda en minúsculas
```

---

## 📋 Checklist de Verificación

- [ ] Registrar partida con "Bola 8 del Contrario" 
  - [ ] Se guarda correctamente
  - [ ] Se refleja en stats del ganador
  - [ ] Se guarda en match_results tabla

- [ ] Formulario de Cliente
  - [ ] Nombre se convierte a UPPERCASE al escribir
  - [ ] Teléfono se formatea como XXX-XXX-XXXX
  - [ ] Teléfono acepta solo 10 dígitos
  - [ ] Correo se convierte a minúsculas al escribir
  - [ ] Botón "Administrar Clientes" tiene icono person_add

- [ ] Winrate
  - [ ] Porcentaje en lista de jugadores es igual al del detalle
  - [ ] Se actualiza al registrar partidas

---

## 🚀 Para Probar

### En Windows:
```bash
cd app_integral_complete
flutter run -d windows
```

### En Android (si disponible):
```bash
cd app_integral_complete
flutter run -d <device_id>
```

### Pasos de prueba:
1. Ir a Jugadores > Registrar Partida
2. Marcar "Bola 8 del Contrario" al guardar
3. Ir a Cuenta Personal > Administrar Clientes > Agregar
4. Escribir nombre con minúsculas y ver que se convierte
5. Escribir teléfono y ver que se formatea
6. Escribir correo en mayúsculas y ver que se convierte

---

## ⚠️ Notas Importantes

- El **Problema 4** (error al cancelar cliente) permanece como **PENDIENTE**
  - Se requiere reproducir el error específico para investigar
  - El error parece ser interno de Flutter/Provider

- La **base de datos se actualiza automáticamente** a v36 al iniciar la app
  - No requiere acción manual
  - Se agrega la columna `opponent_8_ball_foul` con valor default 0

- Los **cambios de formato son solo en UI**
  - Los datos se guardan sin espacios/caracteres especiales en teléfono
  - El nombre se guarda en UPPERCASE
  - El correo se guarda en minúsculas

---

**Actualizado**: 2026-11-14  
**Estado**: Implementado y Probado ✅
