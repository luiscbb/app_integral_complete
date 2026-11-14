# 🔍 MAPA DE CAMBIOS EN EL CÓDIGO

Este documento muestra exactamente dónde encontrar cada cambio implementado.

---

## 📍 PROBLEMA 1: Bola 8 del Contrario

### 1. Agregar campo a entidad PlayerStats
**Archivo**: `lib/features/players/domain/entities/player_stats.dart`

**Líneas**: ~8-25 (constructor)
```dart
class PlayerStats {
  final int wins;
  final int losses;
  final int draws;
  final int breakAndRun;
  final int goldenBreaks;
  final int opponent8BallFoul;  // ← NUEVO
  // ...
}
```

**Líneas**: ~33 (toMap)
```dart
Map<String, dynamic> toMap() => {
  // ...
  'opponent_8_ball_foul': opponent8BallFoul,  // ← NUEVO
  // ...
};
```

**Líneas**: ~43-60 (copyWith)
```dart
PlayerStats copyWith({
  // ...
  int? opponent8BallFoul,  // ← NUEVO
  // ...
}) {
  return PlayerStats(
    // ...
    opponent8BallFoul: opponent8BallFoul ?? this.opponent8BallFoul,  // ← NUEVO
    // ...
  );
}
```

**Líneas**: ~187 (fromMap en PlayerEntity)
```dart
stats: PlayerStats(
  // ...
  opponent8BallFoul: (m['opponent_8_ball_foul'] as num?)?.toInt() ?? 0,  // ← NUEVO
  // ...
),
```

---

### 2. Agregar campo a MatchResult
**Archivo**: `lib/features/players/domain/entities/match_result.dart`

**Líneas**: ~1-30 (clase)
```dart
class MatchResult {
  final bool opponent8BallFoul;  // ← NUEVO
  
  MatchResult({
    // ...
    this.opponent8BallFoul = false,  // ← NUEVO
    // ...
  });
  
  Map<String, dynamic> toMap() => {
    // ...
    'opponent_8_ball_foul': opponent8BallFoul ? 1 : 0,  // ← NUEVO
    // ...
  };
}
```

---

### 3. Agregar opción en RecordMatchPage
**Archivo**: `lib/features/players/presentation/pages/record_match_page.dart`

**Líneas**: ~20-25 (variables de estado)
```dart
class _RecordMatchPageState extends State<RecordMatchPage> {
  // ...
  bool _opponent8BallFoul = false;  // ← NUEVO
  // ...
}
```

**Líneas**: ~110-130 (UI - FilterChip)
```dart
Wrap(
  spacing: 10,
  children: [
    FilterChip(
      label: const Text('Golden Break'),
      selected: _goldenBreak,
      onSelected: (_) => setState(() => _goldenBreak = !_goldenBreak),
    ),
    FilterChip(
      label: const Text('Break & Run'),
      selected: _breakAndRun,
      onSelected: (_) => setState(() => _breakAndRun = !_breakAndRun),
    ),
    FilterChip(
      label: const Text('Bola 8 del Contrario'),  // ← NUEVO
      selected: _opponent8BallFoul,
      onSelected: (_) => setState(() => _opponent8BallFoul = !_opponent8BallFoul),
    ),
  ],
),
```

**Líneas**: ~155-170 (_save)
```dart
void _save() async {
  final match = MatchResult(
    // ...
    opponent8BallFoul: _opponent8BallFoul,  // ← NUEVO
    // ...
  );
  // ...
}
```

---

### 4. Actualizar PlayerRepository
**Archivo**: `lib/features/players/data/repositories/player_repository.dart`

**Líneas**: ~315-350 (método recordMatch)
```dart
Future<void> recordMatch(
  int playerId, {
  required bool won,
  bool isDraw = false,
  bool goldenBreak = false,
  bool breakAndRun = false,
  bool opponent8BallFoul = false,  // ← NUEVO
}) async {
  // ...
  if (opponent8BallFoul) {  // ← NUEVO
    stats = stats.copyWith(opponent8BallFoul: stats.opponent8BallFoul + 1);
  }
  // ...
}
```

---

### 5. Actualizar MatchRepository
**Archivo**: `lib/features/players/data/repositories/match_repository.dart`

**Líneas**: ~20-45 (recordHeadToHead)
```dart
Future<void> recordHeadToHead(MatchResult match) async {
  // ...
  if (match.winnerId == match.player1Id) {
    await _playerRepo.recordMatch(
      match.player1Id,
      won: true,
      goldenBreak: match.goldenBreak,
      breakAndRun: match.breakAndRun,
      opponent8BallFoul: match.opponent8BallFoul,  // ← NUEVO
    );
  } else if (match.winnerId == match.player2Id) {
    await _playerRepo.recordMatch(
      match.player2Id,
      won: true,
      goldenBreak: match.goldenBreak,
      breakAndRun: match.breakAndRun,
      opponent8BallFoul: match.opponent8BallFoul,  // ← NUEVO
    );
  }
}
```

---

### 6. Actualizar Base de Datos
**Archivo**: `lib/core/database/database_helper.dart`

**Línea**: ~28 (versión de BD)
```dart
return await openDatabase(path, version: 36, onCreate: _createDB, onUpgrade: _upgradeDB);
                                          ↑ Cambio de 35 a 36
```

**Líneas**: ~36-42 (migración para v36)
```dart
Future<void> _upgradeDB(Database db, int oldV, int newV) async {
  if (oldV < 36 && !await _hasColumn(db, 'players', 'opponent_8_ball_foul')) {
    await db.execute(
      'ALTER TABLE players ADD COLUMN opponent_8_ball_foul INTEGER NOT NULL DEFAULT 0',
    );
  }
  // ...
}
```

**Líneas**: ~720-740 (tabla players en onCreate)
```dart
await db.execute('''
  CREATE TABLE players (
    // ... columnas previas ...
    opponent_8_ball_foul INTEGER NOT NULL DEFAULT 0,  // ← NUEVO
    // ... columnas previas ...
  )
''');
```

**Líneas**: ~720-742 (tabla match_results en onCreate)
```dart
await db.execute('''
  CREATE TABLE match_results (
    // ... columnas previas ...
    opponent_8_ball_foul INTEGER NOT NULL DEFAULT 0,  // ← NUEVO
    // ... columnas previas ...
  )
''');
```

---

## 📍 PROBLEMA 2: WINRATE - Verificación
**Status**: Ya estaba correcto, sin cambios requeridos

**Archivos revisados**:
- `lib/features/players/presentation/providers/players_provider.dart` (línea ~35-50)
  - Método: `winRateFor()`
  - Cálculo: `(player.stats.wins + record.$1) / totalMatches * 100`
  
- `lib/features/players/presentation/pages/player_detail_page.dart` (línea ~60-70)
  - Cálculo: `(totalWins / totalMatches) * 100`
  - Ambos incluyen estadísticas de torneos correctamente

---

## 📍 PROBLEMA 3: Formato de Cliente

### 1. Importar servicios
**Archivo**: `lib/features/special_client/presentation/pages/special_client_page.dart`

**Línea**: ~1-3
```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';  // ← NUEVO - para TextInputFormatter

import '../../../../core/storage/preferences_service.dart';
```

---

### 2. NOMBRE - UPPERCASE
**Archivo**: `lib/features/special_client/presentation/pages/special_client_page.dart`

**Líneas**: ~270-280 (TextField)
```dart
TextField(
  controller: name,
  textCapitalization: TextCapitalization.characters,  // ← NUEVO
  inputFormatters: [  // ← NUEVO
    TextInputFormatter.withFunction(
      (_, value) => value.copyWith(text: value.text.toUpperCase()),
    ),
  ],
  decoration: const InputDecoration(
    labelText: 'Nombre *',
  ),
),
```

---

### 3. TELÉFONO - Máscara XXX-XXX-XXXX
**Archivo**: `lib/features/special_client/presentation/pages/special_client_page.dart`

**Líneas**: ~281-310 (TextField)
```dart
TextField(
  controller: phone,
  keyboardType: TextInputType.phone,
  inputFormatters: [  // ← NUEVO
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(10),
    TextInputFormatter.withFunction((_, value) {
      if (value.text.isEmpty) return value;
      final text = value.text;
      if (text.length <= 3) {
        return value.copyWith(text: text);
      } else if (text.length <= 6) {
        return value.copyWith(
          text: '${text.substring(0, 3)}-${text.substring(3)}',
          // ...selección del cursor...
        );
      } else {
        return value.copyWith(
          text: '${text.substring(0, 3)}-${text.substring(3, 6)}-${text.substring(6)}',
          // ...selección del cursor...
        );
      }
    }),
  ],
  decoration: const InputDecoration(
    labelText: 'Teléfono (10 dígitos)',
    hintText: 'XXX-XXX-XXXX',
  ),
),
```

---

### 4. EMAIL - lowercase
**Archivo**: `lib/features/special_client/presentation/pages/special_client_page.dart`

**Líneas**: ~311-320 (TextField)
```dart
TextField(
  controller: email,
  keyboardType: TextInputType.emailAddress,
  inputFormatters: [  // ← NUEVO
    TextInputFormatter.withFunction(
      (_, value) => value.copyWith(text: value.text.toLowerCase()),
    ),
  ],
  decoration: const InputDecoration(
    labelText: 'Correo',
  ),
),
```

---

### 5. Guardar con transformaciones finales
**Archivo**: `lib/features/special_client/presentation/pages/special_client_page.dart`

**Líneas**: ~350-375 (ElevatedButton onPressed)
```dart
ElevatedButton(
  onPressed: () {
    if (name.text.trim().isEmpty) {
      // error handling
      return;
    }
    // Remover caracteres de la máscara del teléfono
    final phoneCleaned = phone.text.replaceAll(RegExp(r'[^\d]'), '');  // ← NUEVO
    Navigator.pop(
      context,
      PersonalClient(
        id: client?.id,
        clientId: client?.clientId ?? '',
        name: name.text.trim().toUpperCase(),  // ← NUEVO
        phone: phoneCleaned,
        email: email.text.trim().toLowerCase(),  // ← NUEVO
        notes: notes.text.trim(),
      ),
    );
  },
  child: const Text('GUARDAR'),
),
```

---

## 📍 PROBLEMA 6: Icono del Botón

### Cambiar icono
**Archivo**: `lib/features/special_client/presentation/pages/special_client_page.dart`

**Líneas**: ~247-252 (OutlinedButton)
```dart
OutlinedButton.icon(
  onPressed: () => Navigator.pop(context),
  icon: const Icon(Icons.person_add),  // ← Cambio de Icons.person_add_alt_1
  label: const Text('ADMINISTRAR CLIENTES'),
),
```

---

## 📍 PROBLEMA 4: Error de Cancelación

**Status**: PENDIENTE - Requiere investigación adicional

**Posible ubicación** (si aplica):
- `lib/features/special_client/presentation/pages/special_client_page.dart`
- Método: `_showClientForm()` (~línea 265)
- Dialog: `AlertDialog` con `StatefulBuilder`

**Nota**: El error `_DEPENDENTS.ISEMPTY` es interno de Flutter Provider y requiere reproducción exacta para debuguear.

---

## 📊 Resumen de Líneas Modificadas

| Archivo | Líneas Modificadas | Tipo |
|---------|-------------------|------|
| player_stats.dart | ~8, 33, 43-60, 187 | Nuevo campo |
| match_result.dart | ~8-30 | Nuevo campo |
| record_match_page.dart | ~20-25, 110-130, 155-170 | UI + lógica |
| player_repository.dart | ~315-350 | Lógica |
| match_repository.dart | ~20-45 | Integración |
| database_helper.dart | ~28, 36-42, 720-742 | BD |
| special_client_page.dart | ~1-3, 270-375, 247-252 | UI + lógica |

**Total de cambios**: ~400+ líneas

---

## 🔗 Relaciones entre Cambios

```
PlayerStats (nuevo campo opponent8BallFoul)
    ↓
PlayerEntity.fromMap() - mapea el campo
    ↓
MatchResult (nuevo campo opponent8BallFoul)
    ↓
RecordMatchPage (UI para seleccionar)
    ↓
MatchRepository.recordHeadToHead()
    ↓
PlayerRepository.recordMatch() (registra en stats)
    ↓
DatabaseHelper (v36 - nueva columna)
```

---

## ✅ Verificación de Cambios

Para verificar que todos los cambios están en lugar:

```bash
# Ver diferencias desde HEAD~1 (commit anterior)
git diff HEAD~1

# Ver solo archivos modificados
git diff HEAD~1 --name-only

# Ver cambios específicos de un archivo
git show HEAD:lib/features/players/domain/entities/player_stats.dart
```

---

## 🚀 Compilación y Ejecución

```bash
# Limpiar build
flutter clean

# Obtener dependencias
flutter pub get

# Analizar código
flutter analyze

# Compilar para Windows
flutter run -d windows

# Compilar para Android
flutter run
```

---

**Documento actualizado**: 2026-11-14  
**Propósito**: Facilitar la navegación y revisión de cambios en el código
