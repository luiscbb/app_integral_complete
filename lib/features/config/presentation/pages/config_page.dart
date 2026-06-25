import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/storage/preferences_service.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/database/database_helper.dart';

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  int _selectedSection = 0;

  static const _sections = [
    (Icons.store, 'Negocio'),
    (Icons.print, 'Impresión'),
    (Icons.table_bar, 'Billar'),
    (Icons.palette, 'Apariencia'),
  ];

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Scaffold(
      appBar: AppBar(
        title: Text('CONFIGURACIÓN',
            style: TextStyle(color: primary, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
      ),
      body: Row(
        children: [
          Container(
            width: 110,
            color: const Color(0xFF0D0D0D),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount: _sections.length,
              itemBuilder: (_, i) {
                final selected = _selectedSection == i;
                return GestureDetector(
                  onTap: () => setState(() => _selectedSection = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: selected ? primary.withValues(alpha: 0.15) : Colors.transparent,
                      border: Border.all(
                        color: selected ? primary : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(_sections[i].$1,
                            color: selected ? primary : Colors.white38, size: 26),
                        const SizedBox(height: 6),
                        Text(_sections[i].$2,
                            style: TextStyle(
                              color: selected ? primary : Colors.white38,
                              fontSize: 10,
                              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                            )),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(width: 1, color: Colors.white10),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: [
                  const _NegocioSection(),
                  const _ImpresionSection(),
                  const _BillarSection(),
                  const _AparienciaSection(),
                ][_selectedSection],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── SECCIÓN NEGOCIO ──────────────────────────────────────────────────────────
class _NegocioSection extends StatefulWidget {
  const _NegocioSection();
  @override
  State<_NegocioSection> createState() => _NegocioSectionState();
}

class _NegocioSectionState extends State<_NegocioSection> {
  final _prefs = PreferencesService();
  late final TextEditingController _businessCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _billarIdCtrl;
  String? _logoPath;

  @override
  void initState() {
    super.initState();
    _businessCtrl = TextEditingController(text: _prefs.businessName);
    _userCtrl = TextEditingController(text: _prefs.userName);
    _billarIdCtrl = TextEditingController(text: _prefs.billarId);
    _logoPath = _prefs.logoPath.isNotEmpty ? _prefs.logoPath : null;
  }

  @override
  void dispose() {
    _businessCtrl.dispose();
    _userCtrl.dispose();
    _billarIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) {
        final primary = Theme.of(ctx).colorScheme.primary;
        return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.camera_alt, color: primary),
            title: const Text('Cámara', style: TextStyle(color: Colors.white)),
            onTap: () { Navigator.pop(context); _pickFrom(ImageSource.camera); },
          ),
          ListTile(
            leading: Icon(Icons.photo_library, color: primary),
            title: const Text('Galería', style: TextStyle(color: Colors.white)),
            onTap: () { Navigator.pop(context); _pickFrom(ImageSource.gallery); },
          ),
        ],
      );
      },
    );
  }

  Future<void> _pickFrom(ImageSource source) async {
    final img = await ImagePicker().pickImage(source: source, imageQuality: 70);
    if (img != null) setState(() => _logoPath = img.path);
  }

  Future<void> _save() async {
    await _prefs.setBusinessName(_businessCtrl.text.trim());
    await _prefs.setUserName(_userCtrl.text.trim());
    // billar_id ya no se edita aqui, se genero en InitialSetup y es inamovible
    if (_logoPath != null) await _prefs.setLogoPath(_logoPath!);

    // Sincronizar con Supabase si hay sesion activa
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final remote = ConfigRemoteRepository();
        await remote.upsertSettings(
          billarId: _prefs.billarId,
          businessName: _prefs.businessName,
          tableCount: _prefs.tableCount,
          hourlyRate: _prefs.hourlyRate,
          primaryColor: _prefs.primaryColorValue,
        );
      }
    } catch (_) {
      // Fallo silencioso de sincronizacion
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Datos del negocio guardados'), backgroundColor: Colors.green),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: Icons.store, title: 'DATOS DEL NEGOCIO', color: primary),
        const SizedBox(height: 20),
        Center(
          child: GestureDetector(
            onTap: _pickLogo,
            child: Container(
              width: 96, height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: primary.withValues(alpha: 0.5), width: 2),
                color: const Color(0xFF1A1A1A),
              ),
              clipBehavior: Clip.antiAlias,
              child: _logoPath != null && File(_logoPath!).existsSync()
                  ? Image.file(File(_logoPath!), fit: BoxFit.cover)
                  : Icon(Icons.add_a_photo, color: primary, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Center(child: Text('Logo del negocio', style: TextStyle(color: Colors.white38, fontSize: 12))),
        const SizedBox(height: 20),
        _ConfigField(controller: _businessCtrl, label: 'Nombre del negocio', icon: Icons.store),
        _ConfigField(controller: _userCtrl, label: 'Nombre del cajero / atendedor', icon: Icons.person),
        // billar_id es solo informativo, no editable
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextField(
            controller: _billarIdCtrl,
            enabled: false,
            style: const TextStyle(color: Colors.white38),
            decoration: InputDecoration(
              labelText: 'ID del Billar (unico e inamovible)',
              prefixIcon: const Icon(Icons.key, color: Colors.white24),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.white10),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        _SaveButton(onPressed: _save, color: primary),
      ],
    );
  }
}

// ─── SECCIÓN IMPRESIÓN ────────────────────────────────────────────────────────
class _ImpresionSection extends StatefulWidget {
  const _ImpresionSection();
  @override
  State<_ImpresionSection> createState() => _ImpresionSectionState();
}

class _ImpresionSectionState extends State<_ImpresionSection> {
  final _prefs = PreferencesService();
  late String _selectedWidth;

  @override
  void initState() {
    super.initState();
    _selectedWidth = _prefs.printWidth;
  }

  Future<void> _save() async {
    await _prefs.setPrintWidth(_selectedWidth);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuración de impresión guardada'), backgroundColor: Colors.green),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: Icons.print, title: 'IMPRESIÓN DE TICKETS', color: primary),
        const SizedBox(height: 20),
        const Text('ANCHO DE PAPEL', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 12),
        Row(
          children: ['58mm', '80mm'].map((w) {
            final sel = _selectedWidth == w;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _selectedWidth = w),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: sel ? primary : Colors.white12, width: sel ? 2 : 1),
                      color: sel ? primary.withValues(alpha: 0.12) : const Color(0xFF1A1A1A),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.receipt_long, color: sel ? primary : Colors.white24, size: 32),
                        const SizedBox(height: 6),
                        Text(w, style: TextStyle(color: sel ? primary : Colors.white38, fontWeight: FontWeight.bold, fontSize: 15)),
                        Text(w == '58mm' ? 'Ticket pequeño' : 'Ticket estándar',
                            style: TextStyle(color: sel ? Colors.white54 : Colors.white24, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 32),
        _SaveButton(onPressed: _save, color: primary),
      ],
    );
  }
}

// ─── SECCIÓN BILLAR ───────────────────────────────────────────────────────────
class _BillarSection extends StatefulWidget {
  const _BillarSection();
  @override
  State<_BillarSection> createState() => _BillarSectionState();
}

class _BillarSectionState extends State<_BillarSection> {
  final _prefs = PreferencesService();
  late int _tableCount;
  late final TextEditingController _rateCtrl;

  @override
  void initState() {
    super.initState();
    _tableCount = _prefs.tableCount;
    _rateCtrl = TextEditingController(
        text: _prefs.hourlyRate > 0 ? _prefs.hourlyRate.toStringAsFixed(2) : '');
  }

  @override
  void dispose() {
    _rateCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final rate = double.tryParse(_rateCtrl.text) ?? 0.0;
    await _prefs.setTableCount(_tableCount);
    await _prefs.setHourlyRate(rate);
    await _applyTableCount(_tableCount);

    // Sincronizar con Supabase si hay sesion activa
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final remote = ConfigRemoteRepository();
        await remote.upsertSettings(
          billarId: _prefs.billarId,
          businessName: _prefs.businessName,
          tableCount: _tableCount,
          hourlyRate: rate,
        );
      }
    } catch (_) {
      // Fallo silencioso de sincronizacion
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuración de billar guardada'), backgroundColor: Colors.green),
      );
    }
  }

  Future<void> _applyTableCount(int count) async {
    final db = await DatabaseHelper.instance.database;
    final existing = await db.query('billiard_tables');
    final existingIds = existing.map((e) => e['id'] as int).toSet();

    for (int i = 1; i <= count; i++) {
      if (!existingIds.contains(i)) {
        await db.insert('billiard_tables', {
          'id': i,
          'billar_id': _prefs.billarId,
          'name': 'Mesa $i',
          'is_occupied': 0,
          'orders': '[]',
        });
      }
    }
    for (final id in existingIds) {
      if (id > count) {
        await db.delete('billiard_tables', where: 'id = ?', whereArgs: [id]);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: Icons.table_bar, title: 'CONFIGURACIÓN BILLAR', color: primary),
        const SizedBox(height: 24),
        const Text('NÚMERO DE MESAS', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              onPressed: _tableCount > 1 ? () => setState(() => _tableCount--) : null,
              icon: Icon(Icons.remove_circle, color: _tableCount > 1 ? primary : Colors.white12, size: 32),
            ),
            Expanded(
              child: Center(
                child: Text('$_tableCount',
                    style: TextStyle(color: primary, fontSize: 48, fontWeight: FontWeight.bold)),
              ),
            ),
            IconButton(
              onPressed: _tableCount < 20 ? () => setState(() => _tableCount++) : null,
              icon: Icon(Icons.add_circle, color: _tableCount < 20 ? primary : Colors.white12, size: 32),
            ),
          ],
        ),
        Slider(
          value: _tableCount.toDouble(),
          min: 1, max: 20,
          divisions: 19,
          activeColor: primary,
          inactiveColor: Colors.white12,
          onChanged: (v) => setState(() => _tableCount = v.round()),
        ),
        const SizedBox(height: 24),
        const Text('TARIFA POR HORA', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 12),
        _ConfigField(
          controller: _rateCtrl,
          label: 'Precio por hora (\$)',
          icon: Icons.attach_money,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 8),
        const Text(
          'Se usa para calcular el costo de tiempo en mesas activas',
          style: TextStyle(color: Colors.white24, fontSize: 11),
        ),
        const SizedBox(height: 24),
        _SaveButton(onPressed: _save, color: primary),
      ],
    );
  }
}

// ─── SECCIÓN APARIENCIA ───────────────────────────────────────────────────────
class _AparienciaSection extends StatelessWidget {
  const _AparienciaSection();

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
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: Icons.palette, title: 'APARIENCIA', color: theme.primaryColor),
        const SizedBox(height: 24),
        const Text('MODO DE PANTALLA', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 12),
        Row(
          children: [
            _ModeCard(
              icon: Icons.dark_mode,
              label: 'Oscuro',
              selected: theme.isDark,
              color: theme.primaryColor,
              onTap: () { if (!theme.isDark) theme.toggleTheme(); },
            ),
            const SizedBox(width: 12),
            _ModeCard(
              icon: Icons.light_mode,
              label: 'Claro',
              selected: !theme.isDark,
              color: theme.primaryColor,
              onTap: () { if (theme.isDark) theme.toggleTheme(); },
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text('COLOR PRINCIPAL', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _palette.map((entry) {
            final (color, name) = entry;
            final isSelected = theme.primaryColor.toARGB32() == color.toARGB32();
            return GestureDetector(
              onTap: () => theme.setPrimaryColor(color),
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
        const SizedBox(height: 8),
        Text('Color actual', style: TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 4),
        Row(
          children: [
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(color: theme.primaryColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              '#${theme.primaryColor.toARGB32().toRadixString(16).toUpperCase().substring(2)}',
              style: const TextStyle(color: Colors.white54, fontSize: 13, fontFamily: 'monospace'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _ModeCard({required this.icon, required this.label, required this.selected, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? color : Colors.white12, width: selected ? 2 : 1),
            color: selected ? color.withValues(alpha: 0.12) : const Color(0xFF1A1A1A),
          ),
          child: Column(
            children: [
              Icon(icon, color: selected ? color : Colors.white38, size: 30),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(color: selected ? color : Colors.white38, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── WIDGETS COMPARTIDOS ──────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;

  const _SectionHeader({required this.icon, required this.title, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 10),
        Text(title, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
      ],
    );
  }
}

class _ConfigField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;

  const _ConfigField({required this.controller, required this.label, required this.icon, this.keyboardType});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  final VoidCallback onPressed;
  final Color color;

  const _SaveButton({required this.onPressed, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.save, color: Colors.white),
        label: const Text('GUARDAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
      ),
    );
  }
}
