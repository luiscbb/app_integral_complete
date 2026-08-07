import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../sales/data/repositories/billiard_table_repository.dart';

class InitialSetupPage extends StatefulWidget {
  const InitialSetupPage({super.key});

  @override
  State<InitialSetupPage> createState() => _InitialSetupPageState();
}

class _InitialSetupPageState extends State<InitialSetupPage> {
  final _prefs = PreferencesService();
  final _nameCtrl = TextEditingController(text: 'Baumar Billar');
  final _tablesCtrl = TextEditingController(text: '8');
  final _rateCtrl = TextEditingController(text: '0');
  final _nameFocus = FocusNode();
  final _tablesFocus = FocusNode();
  final _rateFocus = FocusNode();
  bool _loading = false;
  int _step = 0;
  int _selectedColor = 0xFFE53935; // Rojo default
  String _generatedBillarId = '';

  static const _palette = [
    (Color(0xFFE53935), 'Rojo'),
    (Color(0xFF1E88E5), 'Azul'),
    (Color(0xFF43A047), 'Verde'),
    (Color(0xFFFB8C00), 'Naranja'),
    (Color(0xFF8E24AA), 'Morado'),
    (Color(0xFF00ACC1), 'Cyan'),
    (Color(0xFFFFB300), 'Amarillo'),
    (Color(0xFFE91E63), 'Rosa'),
    (Color(0xFF546E7A), 'Gris'),
    (Color(0xFFFF5722), 'Coral'),
  ];

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(_capitalizeWords);
    _generateBillarId();
  }

  void _generateBillarId() {
    // Generar ID unico basado en timestamp: BILLAR_YYYYMMDD_HHMMSS
    final now = DateTime.now();
    _generatedBillarId = 
        'BILLAR_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_capitalizeWords);
    _nameCtrl.dispose();
    _tablesCtrl.dispose();
    _rateCtrl.dispose();
    _nameFocus.dispose();
    _tablesFocus.dispose();
    _rateFocus.dispose();
    super.dispose();
  }

  void _capitalizeWords() {
    final text = _nameCtrl.text;
    if (text.isEmpty) return;
    // Capitalizar cada palabra: hola mundo -> Hola Mundo
    final capitalized = text.split(' ').map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1);
    }).join(' ');
    if (capitalized != text) {
      _nameCtrl.value = TextEditingValue(
        text: capitalized,
        selection: TextSelection.collapsed(offset: capitalized.length),
      );
    }
  }

  void _clearIfDefault(TextEditingController controller, String value) {
    if (controller.text.trim() == value) {
      controller.clear();
    }
  }

  Future<void> _finish() async {
    final name = _nameCtrl.text.trim();
    final tables = int.tryParse(_tablesCtrl.text) ?? 8;
    final rate = double.tryParse(_rateCtrl.text) ?? 0.0;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El nombre del negocio es requerido'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _loading = true);

    await _prefs.setBusinessName(name);
    await _prefs.setTableCount(tables.clamp(1, 100));
    await _prefs.setHourlyRate(rate);
    await _prefs.setPrimaryColorValue(_selectedColor);
    await _prefs.setBillarId(_generatedBillarId);
    
    // Aplicar el color seleccionado al tema
    if (mounted) {
      context.read<ThemeProvider>().setPrimaryColor(Color(_selectedColor));
    }

    // Crear mesas en la base de datos local y en Supabase
    final tableCount = tables.clamp(1, 100);
    final tableRepo = BilliardTableRepository();
    final db = await DatabaseHelper.instance.database;

    for (int i = 1; i <= tableCount; i++) {
      await db.insert('billiard_tables', {
        'id': i,
        'billar_id': _generatedBillarId,
        'name': 'Mesa $i',
        'table_type': 'Billar',
        'is_occupied': 0,
        'orders': '[]',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Sube cada mesa a Supabase (fire-and-forget)
      unawaited(tableRepo.insert(
        id: i,
        billarId: _generatedBillarId,
        name: 'Mesa $i',
        tableType: 'Billar',
      ));
    }

    // Subir config a Supabase si hay sesion activa
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final remote = ConfigRemoteRepository();
        await remote.upsertSettings(
          billarId: _generatedBillarId,
          businessName: name,
          tableCount: tables.clamp(1, 100),
          hourlyRate: rate,
          primaryColor: _selectedColor,
        );
      }
    } catch (_) {
      // Fallo silencioso: la config local ya quedo y la sincronizacion
      // puede hacerse luego desde ConfigPage.
    }

    await _prefs.setIsFirstRun(false);

    if (mounted) {
      Navigator.pushReplacementNamed(context, AppRoutes.home);
    }
  }

  Widget _buildStep(Color primary) {
    switch (_step) {
      case 0:
        return Column(
          children: [
            Icon(Icons.storefront, size: 64, color: primary),
            const SizedBox(height: 24),
            const Text(
              'BIENVENIDO A BAUMAR POS',
              style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Configura tu establecimiento en 3 pasos',
              style: TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            AppButton(
              label: 'COMENZAR',
              icon: Icons.arrow_forward,
              onPressed: () => setState(() => _step = 1),
            ),
          ],
        );
      case 1:
        WidgetsBinding.instance.addPostFrameCallback((_) => _nameFocus.requestFocus());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PASO 1 DE 4',
              style: TextStyle(color: primary, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Nombre de tu negocio',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            AppTextField(
              controller: _nameCtrl,
              label: 'Ej: Baumar Billar',
              icon: Icons.store,
              focusNode: _nameFocus,
              onTap: () => _clearIfDefault(_nameCtrl, 'Baumar Billar'),
            ),
            const SizedBox(height: 24),
            AppButton(
              label: 'SIGUIENTE',
              icon: Icons.arrow_forward,
              onPressed: () {
                if (_nameCtrl.text.trim().isNotEmpty) {
                  setState(() => _step = 2);
                }
              },
            ),
          ],
        );
      case 2:
        WidgetsBinding.instance.addPostFrameCallback((_) => _tablesFocus.requestFocus());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PASO 2 DE 4',
              style: TextStyle(color: primary, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Cuantas mesas de billar tienes?',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Puedes cambiar esto despues en configuracion',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),
            AppTextField(
              controller: _tablesCtrl,
              label: 'Numero de mesas (1-100)',
              hint: '8',
              icon: Icons.table_bar,
              isNumber: true,
              focusNode: _tablesFocus,
              onTap: () => _clearIfDefault(_tablesCtrl, '8'),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => setState(() => _step = 1),
                    child: const Text('ATRAS', style: TextStyle(color: Colors.white38)),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: AppButton(
                    label: 'SIGUIENTE',
                    icon: Icons.arrow_forward,
                    onPressed: () {
                      final count = int.tryParse(_tablesCtrl.text) ?? 0;
                      if (count >= 1 && count <= 100) {
                        setState(() => _step = 3);
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      case 3:
        WidgetsBinding.instance.addPostFrameCallback((_) => _rateFocus.requestFocus());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PASO 3 DE 4',
              style: TextStyle(color: primary, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tarifa por hora (opcional)',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Deja en 0 si no cobras por tiempo de mesa',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),
            AppTextField(
              controller: _rateCtrl,
              label: 'Tarifa por hora (\$)',
              hint: '0',
              icon: Icons.timer,
              isNumber: true,
              focusNode: _rateFocus,
              onTap: () => _clearIfDefault(_rateCtrl, '0'),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => setState(() => _step = 2),
                    child: const Text('ATRAS', style: TextStyle(color: Colors.white38)),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: AppButton(
                    label: 'SIGUIENTE',
                    icon: Icons.arrow_forward,
                    onPressed: () {
                      setState(() => _step = 4);
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      case 4:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PASO 4 DE 4',
              style: TextStyle(color: primary, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Color principal de tu app',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Puedes cambiar esto despues en configuracion',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _palette.map((entry) {
                final (color, name) = entry;
                final isSelected = _selectedColor == color.toARGB32();
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = color.toARGB32()),
                  child: Tooltip(
                    message: name,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: isSelected
                            ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 12, spreadRadius: 2)]
                            : [],
                      ),
                      child: isSelected
                          ? const Icon(Icons.check, color: Colors.white, size: 22)
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => setState(() => _step = 3),
                    child: const Text('ATRAS', style: TextStyle(color: Colors.white38)),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: AppButton(
                    label: 'FINALIZAR',
                    icon: Icons.check,
                    isLoading: _loading,
                    onPressed: _finish,
                  ),
                ),
              ],
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: primary.withValues(alpha: 0.4)),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _buildStep(primary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
