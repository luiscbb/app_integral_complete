import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/database/database_helper.dart';
import '../../../../features/sales/data/repositories/billiard_table_repository.dart';

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  int _selectedSection = 0;
  final _negocioKey = GlobalKey<_NegocioSectionState>();
  final _impresionKey = GlobalKey<_ImpresionSectionState>();

  static const _sections = [
    (Icons.store, 'Negocio'),
    (Icons.print, 'Impresión'),
    (Icons.table_bar, 'Billar/Comanda'),
    (Icons.palette, 'Apariencia'),
    (Icons.logout, 'Sesión'),
  ];

  VoidCallback? get _currentSaveAction {
    switch (_selectedSection) {
      case 0:
        return _negocioKey.currentState?._save;
      case 1:
        return _impresionKey.currentState?._save;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'CONFIGURACIÓN',
          style: TextStyle(color: primary, fontWeight: FontWeight.bold, letterSpacing: 1.5),
        ),
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
                final isLogout = i == _sections.length - 1;
                final itemColor = isLogout ? const Color(0xFFE53935) : primary;
                return GestureDetector(
                  onTap: () => setState(() => _selectedSection = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: selected ? itemColor.withValues(alpha: 0.15) : Colors.transparent,
                      border: Border.all(
                        color: selected ? itemColor : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          _sections[i].$1,
                          color:
                              selected
                                  ? itemColor
                                  : (isLogout
                                      ? const Color(0xFFE53935).withValues(alpha: 0.6)
                                      : Colors.white38),
                          size: 26,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _sections[i].$2,
                          style: TextStyle(
                            color:
                                selected
                                    ? itemColor
                                    : (isLogout
                                        ? const Color(0xFFE53935).withValues(alpha: 0.6)
                                        : Colors.white38),
                            fontSize: 10,
                            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(width: 1, color: Colors.white10),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 900;
                return Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child:
                              [
                                _NegocioSection(key: _negocioKey, isWide: isWide),
                                _ImpresionSection(key: _impresionKey, isWide: isWide),
                                const _BillarSection(),
                                const _AparienciaSection(),
                                const _SesionSection(),
                              ][_selectedSection],
                        ),
                      ),
                    ),
                    if ((isWide && _selectedSection <= 1))
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: _SaveButton(
                          onPressed: _currentSaveAction ?? () {},
                          color: primary,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── SECCIÓN NEGOCIO ──────────────────────────────────────────────────────────
class _NegocioSection extends StatefulWidget {
  final bool isWide;
  const _NegocioSection({super.key, required this.isWide});
  @override
  State<_NegocioSection> createState() => _NegocioSectionState();
}

class _NegocioSectionState extends State<_NegocioSection> {
  final _prefs = PreferencesService();
  late final TextEditingController _businessCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _billarIdCtrl;
  late final TextEditingController _streetCtrl;
  late final TextEditingController _extNumberCtrl;
  late final TextEditingController _intNumberCtrl;
  late final TextEditingController _colonyCtrl;
  late final TextEditingController _zipCodeCtrl;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _stateCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _whatsappCtrl;
  late final TextEditingController _sloganCtrl;
  late final TextEditingController _websiteCtrl;
  late final TextEditingController _farewellCtrl;
  late final TextEditingController _facebookCtrl;
  late final TextEditingController _instagramCtrl;
  late final TextEditingController _tiktokCtrl;
  String? _logoPath;
  String? _logoUrl;
  bool _uploadingLogo = false;

  @override
  void initState() {
    super.initState();
    _businessCtrl = TextEditingController(text: _prefs.businessName);
    _userCtrl = TextEditingController(text: _prefs.userName);
    _billarIdCtrl = TextEditingController(text: _prefs.billarId);
    _streetCtrl = TextEditingController(text: _prefs.businessStreet);
    _extNumberCtrl = TextEditingController(text: _prefs.businessExtNumber);
    _intNumberCtrl = TextEditingController(text: _prefs.businessIntNumber);
    _colonyCtrl = TextEditingController(text: _prefs.businessColony);
    _zipCodeCtrl = TextEditingController(text: _prefs.businessZipCode);
    _cityCtrl = TextEditingController(text: _prefs.businessCity);
    _stateCtrl = TextEditingController(text: _prefs.businessState);
    _addressCtrl = TextEditingController(text: _prefs.businessAddress);
    _phoneCtrl = TextEditingController(text: _prefs.businessWhatsapp);
    _whatsappCtrl = TextEditingController(text: _prefs.businessWhatsapp);
    _sloganCtrl = TextEditingController(text: _prefs.businessSlogan);
    _websiteCtrl = TextEditingController(text: _prefs.businessWebsite);
    _farewellCtrl = TextEditingController(text: _prefs.ticketFarewell);
    final socials = _prefs.socialNetworks;
    _facebookCtrl = TextEditingController(text: socials['facebook'] ?? '');
    _instagramCtrl = TextEditingController(text: socials['instagram'] ?? '');
    _tiktokCtrl = TextEditingController(text: socials['tiktok'] ?? '');
    _logoPath = _prefs.logoPath.isNotEmpty ? _prefs.logoPath : null;
    _logoUrl = _prefs.logoUrl.isNotEmpty ? _prefs.logoUrl : null;
  }

  @override
  void dispose() {
    _businessCtrl.dispose();
    _userCtrl.dispose();
    _billarIdCtrl.dispose();
    _streetCtrl.dispose();
    _extNumberCtrl.dispose();
    _intNumberCtrl.dispose();
    _colonyCtrl.dispose();
    _zipCodeCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _whatsappCtrl.dispose();
    _sloganCtrl.dispose();
    _websiteCtrl.dispose();
    _farewellCtrl.dispose();
    _facebookCtrl.dispose();
    _instagramCtrl.dispose();
    _tiktokCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        setState(() {
          _logoPath = path;
          _logoUrl = null;
        });
      }
      return;
    }

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
              onTap: () {
                Navigator.pop(context);
                _pickFrom(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_library, color: primary),
              title: const Text('Galería', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickFrom(ImageSource.gallery);
              },
            ),
          ],
        );
      },
    );
  }

  Future<String?> _uploadLogoToStorage(String localPath) async {
    try {
      setState(() => _uploadingLogo = true);
      final file = File(localPath);
      debugPrint('[ConfigPage] Intentando subir logo desde: $localPath');
      if (!await file.exists()) {
        debugPrint('[ConfigPage] ERROR: archivo local no existe');
        return null;
      }
      final bytes = await file.readAsBytes();
      debugPrint('[ConfigPage] Tamaño de imagen: ${bytes.length} bytes');
      final fileName = 'logo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final path = 'logos/$fileName';
      await Supabase.instance.client.storage
          .from('product_images')
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
          );
      final url = Supabase.instance.client.storage.from('product_images').getPublicUrl(path);
      debugPrint('[ConfigPage] Logo subido. URL: $url');
      return url;
    } catch (e, st) {
      debugPrint('[ConfigPage] Error subiendo logo: $e');
      debugPrint('[ConfigPage] Stack: $st');
      return null;
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  Future<void> _pickFrom(ImageSource source) async {
    final img = await ImagePicker().pickImage(source: source, imageQuality: 70);
    if (img != null) {
      setState(() {
        _logoPath = img.path;
        _logoUrl = null;
      });
    }
  }

  Future<void> _save() async {
    await _prefs.setBusinessName(_businessCtrl.text.trim());
    await _prefs.setUserName(_userCtrl.text.trim());
    await _prefs.setBusinessStreet(_streetCtrl.text.trim());
    await _prefs.setBusinessExtNumber(_extNumberCtrl.text.trim());
    await _prefs.setBusinessIntNumber(_intNumberCtrl.text.trim());
    await _prefs.setBusinessColony(_colonyCtrl.text.trim());
    await _prefs.setBusinessZipCode(_zipCodeCtrl.text.trim());
    await _prefs.setBusinessCity(_cityCtrl.text.trim());
    await _prefs.setBusinessState(_stateCtrl.text.trim());
    await _prefs.setBusinessAddress(_addressCtrl.text.trim());
    await _prefs.setBusinessPhone(_phoneCtrl.text.trim());
    await _prefs.setBusinessWhatsapp(_phoneCtrl.text.trim());
    await _prefs.setBusinessSlogan(_sloganCtrl.text.trim());
    await _prefs.setBusinessWebsite(_websiteCtrl.text.trim());
    await _prefs.setTicketFarewell(_farewellCtrl.text.trim());
    await _prefs.setSocialNetworks({
      if (_facebookCtrl.text.trim().isNotEmpty) 'facebook': _facebookCtrl.text.trim(),
      if (_instagramCtrl.text.trim().isNotEmpty) 'instagram': _instagramCtrl.text.trim(),
      if (_tiktokCtrl.text.trim().isNotEmpty) 'tiktok': _tiktokCtrl.text.trim(),
    });
    // billar_id ya no se edita aqui, se genero en InitialSetup y es inamovible
    if (_logoPath != null) {
      await _prefs.setLogoPath(_logoPath!);
      final uploadedUrl = await _uploadLogoToStorage(_logoPath!);
      if (uploadedUrl != null) {
        _logoUrl = uploadedUrl;
      }
    }
    if (_logoUrl != null) await _prefs.setLogoUrl(_logoUrl!);

    debugPrint('[ConfigPage] Guardado logoPath: ${_prefs.logoPath}');
    debugPrint('[ConfigPage] Guardado logoUrl: ${_prefs.logoUrl}');

    // Sincronizar con Supabase si hay sesion activa
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final remote = ConfigRemoteRepository();
        final res = await remote.upsertSettings(
          billarId: _prefs.billarId,
          businessName: _prefs.businessName,
          tableCount: _prefs.tableCount,
          hourlyRate: _prefs.hourlyRate,
          primaryColor: _prefs.primaryColorValue,
          businessAddress: _prefs.businessAddress,
          businessStreet: _prefs.businessStreet,
          businessExtNumber: _prefs.businessExtNumber,
          businessIntNumber: _prefs.businessIntNumber,
          businessColony: _prefs.businessColony,
          businessZipCode: _prefs.businessZipCode,
          businessCity: _prefs.businessCity,
          businessState: _prefs.businessState,
          businessPhone: _prefs.businessPhone,
          businessWhatsapp: _prefs.businessWhatsapp,
          businessSlogan: _prefs.businessSlogan,
          businessWebsite: _prefs.businessWebsite,
          ticketFarewell: _prefs.ticketFarewell,
          socialNetworks: _prefs.socialNetworks,
          logoUrl: _prefs.logoUrl,
        );
        debugPrint('[ConfigPage] Respuesta upsertSettings: $res');
      }
    } catch (e, st) {
      debugPrint('[ConfigPage] Error sincronizando config: $e');
      debugPrint('[ConfigPage] Stack: $st');
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Datos del negocio guardados'), backgroundColor: Colors.green),
      );
      Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.home, (route) => false);
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
            onTap: _uploadingLogo ? null : _pickLogo,
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: primary.withValues(alpha: 0.5), width: 2),
                color: const Color(0xFF1A1A1A),
              ),
              clipBehavior: Clip.antiAlias,
              child:
                  _uploadingLogo
                      ? Center(child: CircularProgressIndicator(color: primary, strokeWidth: 2))
                      : _logoPath != null && File(_logoPath!).existsSync()
                      ? Image.file(File(_logoPath!), fit: BoxFit.cover)
                      : _logoUrl != null
                      ? Image.network(
                          _logoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, err, st) => Icon(Icons.add_a_photo, color: primary, size: 32),
                        )
                      : Icon(Icons.add_a_photo, color: primary, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Center(
          child: Text('Logo del negocio', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ),
        const SizedBox(height: 20),
        _ConfigField(
          controller: _businessCtrl,
          label: 'Nombre del negocio',
          icon: Icons.store,
          textCapitalization: TextCapitalization.sentences,
        ),
        _ConfigField(
          controller: _userCtrl,
          label: 'Nombre del cajero / atendedor',
          icon: Icons.person,
          textCapitalization: TextCapitalization.sentences,
        ),
        // DIRECCION
        const SizedBox(height: 8),
        const Text(
          'DIRECCION',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        _ConfigField(
          controller: _streetCtrl,
          label: 'Calle',
          icon: Icons.signpost_outlined,
          textCapitalization: TextCapitalization.sentences,
        ),
        Row(
          children: [
            Expanded(
              child: _ConfigField(
                controller: _extNumberCtrl,
                label: 'No. Exterior',
                icon: Icons.numbers_outlined,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ConfigField(
                controller: _intNumberCtrl,
                label: 'No. Interior',
                icon: Icons.numbers_outlined,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
          ],
        ),
        _ConfigField(
          controller: _colonyCtrl,
          label: 'Colonia',
          icon: Icons.location_city_outlined,
          textCapitalization: TextCapitalization.sentences,
        ),
        Row(
          children: [
            Expanded(
              child: _ConfigField(
                controller: _zipCodeCtrl,
                label: 'Codigo Postal',
                icon: Icons.local_post_office_outlined,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ConfigField(
                controller: _cityCtrl,
                label: 'Ciudad',
                icon: Icons.location_on_outlined,
                textCapitalization: TextCapitalization.sentences,
              ),
            ),
          ],
        ),
        _ConfigField(
          controller: _stateCtrl,
          label: 'Estado',
          icon: Icons.map_outlined,
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: 8),
        const Text(
          'CONTACTO',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        _PhoneField(controller: _phoneCtrl, label: 'WhatsApp', icon: Icons.chat),
        _ConfigField(controller: _websiteCtrl, label: 'Pagina web', icon: Icons.language_outlined),
        const SizedBox(height: 8),
        const Text(
          'TICKET / IDENTIDAD',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        _ConfigField(controller: _sloganCtrl, label: 'Eslogan', icon: Icons.textsms_outlined, textCapitalization: TextCapitalization.sentences),
        _ConfigField(
          controller: _farewellCtrl,
          label: 'Mensaje de despedida (ej: Gracias por su compra)',
          icon: Icons.favorite_border,
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: 8),
        const Text(
          'REDES SOCIALES',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        _ConfigField(controller: _facebookCtrl, label: 'Facebook', icon: Icons.facebook, textCapitalization: TextCapitalization.none),
        _ConfigField(
          controller: _instagramCtrl,
          label: 'Instagram',
          icon: Icons.camera_alt_outlined,
          textCapitalization: TextCapitalization.none,
        ),
        _ConfigField(controller: _tiktokCtrl, label: 'TikTok', icon: Icons.music_video_outlined, textCapitalization: TextCapitalization.none),
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
        if (widget.isWide)
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: _SaveButton(onPressed: _save, color: primary),
          )
        else ...[
          const SizedBox(height: 32),
          _SaveButton(onPressed: _save, color: primary),
        ],
      ],
    );
  }
}

// ─── SECCIÓN IMPRESIÓN ────────────────────────────────────────────────────────
class _ImpresionSection extends StatefulWidget {
  final bool isWide;
  const _ImpresionSection({super.key, required this.isWide});
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
        const SnackBar(
          content: Text('Configuración de impresión guardada'),
          backgroundColor: Colors.green,
        ),
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
        const Text(
          'ANCHO DE PAPEL',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        Row(
          children:
              ['58mm', '80mm'].map((w) {
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
                          border: Border.all(
                            color: sel ? primary : Colors.white12,
                            width: sel ? 2 : 1,
                          ),
                          color: sel ? primary.withValues(alpha: 0.12) : const Color(0xFF1A1A1A),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.receipt_long,
                              color: sel ? primary : Colors.white24,
                              size: 32,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              w,
                              style: TextStyle(
                                color: sel ? primary : Colors.white38,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              w == '58mm' ? 'Ticket pequeño' : 'Ticket estándar',
                              style: TextStyle(
                                color: sel ? Colors.white54 : Colors.white24,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
        ),
        if (widget.isWide)
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: _SaveButton(onPressed: _save, color: primary),
          )
        else ...[
          const SizedBox(height: 32),
          _SaveButton(onPressed: _save, color: primary),
        ],
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
  final _repo = BilliardTableRepository();
  final _nameCtrl = TextEditingController();
  late final TextEditingController _rateCtrl;
  String _newTableType = 'Billar';

  @override
  void initState() {
    super.initState();
    _rateCtrl = TextEditingController(
      text: _prefs.hourlyRate > 0 ? _prefs.hourlyRate.toStringAsFixed(2) : '',
    );
  }

  @override
  void dispose() {
    _rateCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _loadTables() async {
    var tables = await _repo.getAll(billarId: _prefs.billarId);
    if (tables.isEmpty && _prefs.tableCount > 0) {
      final db = await DatabaseHelper.instance.database;
      for (int i = 1; i <= _prefs.tableCount; i++) {
        await db.insert('billiard_tables', {
          'id': i,
          'billar_id': _prefs.billarId,
          'name': 'Mesa Billar $i',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': '[]',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      tables = await _repo.getAll(billarId: _prefs.billarId);
    }
    return tables.map((t) => Map<String, dynamic>.from(t)).toList();
  }

  Future<void> _addTable() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Escribe un nombre para la mesa'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.table_bar, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            const Text('CREAR MESA', style: TextStyle(color: Color(0xFFFB8C00), fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('¿Confirmas crear esta mesa?', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            _DetailRow(label: 'Nombre', value: name),
            _DetailRow(label: 'Tipo', value: _newTableType),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFB8C00),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.check, color: Colors.white, size: 18),
            label: const Text('CREAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final tables = await _loadTables();
      final maxId =
          tables.isEmpty ? 0 : tables.map((t) => t['id'] as int).reduce((a, b) => a > b ? a : b);
      final newId = maxId + 1;
      await _repo.insert(
        id: newId,
        billarId: _prefs.billarId,
        name: name,
        tableType: _newTableType,
      );
      _nameCtrl.clear();
      setState(() => _newTableType = 'Billar');
      await _syncCount();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Mesa "$name" creada'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al crear mesa: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _removeTable(int id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text('Eliminar mesa', style: TextStyle(color: Colors.white)),
            content: Text('¿Eliminar Mesa $id?', style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Eliminar', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    await _repo.delete(id);
    setState(() {});
    await _syncCount();
  }

  Future<void> _editTableName(int id, String currentName) async {
    final ctrl = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text('EDITAR NOMBRE', style: TextStyle(color: Color(0xFFFB8C00))),
            content: TextField(
              controller: ctrl,
              style: const TextStyle(color: Colors.white),
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Nombre de la mesa',
                labelStyle: TextStyle(color: Colors.white38),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFB8C00)),
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('GUARDAR', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
    );
    if (newName == null || newName.isEmpty || newName == currentName) return;
    await _repo.updateWithoutSync(id: id, name: newName);
    await _repo.syncAllToCloud();
    setState(() {});
  }

  Future<void> _syncCount() async {
    final tables = await _loadTables();
    _prefs.tableCount = tables.length;
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        final remote = ConfigRemoteRepository();
        await remote.upsertSettings(
          billarId: _prefs.billarId,
          businessName: _prefs.businessName,
          tableCount: tables.length,
          hourlyRate: double.tryParse(_rateCtrl.text) ?? 0.0,
        );
      }
    } catch (_) {}
  }

  Future<void> _saveRate() async {
    final rate = double.tryParse(_rateCtrl.text) ?? 0.0;
    if (rate <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ingresa una tarifa válida'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.attach_money, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            const Text('GUARDAR TARIFA', style: TextStyle(color: Color(0xFFFB8C00), fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('¿Confirmas guardar esta tarifa por hora?', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            _DetailRow(label: 'Tarifa', value: '\$${rate.toStringAsFixed(2)}/hr'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFB8C00),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.check, color: Colors.white, size: 18),
            label: const Text('GUARDAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _prefs.setHourlyRate(rate);
    await _syncCount();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tarifa por hora guardada'), backgroundColor: Colors.green),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: Icons.table_bar, title: 'BILLAR / COMANDAS', color: primary),
        const SizedBox(height: 24),
        const Text(
          'TARIFA POR HORA',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        _ConfigField(
          controller: _rateCtrl,
          label: 'Precio por hora (\$)',
          icon: Icons.attach_money,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
          onSubmitted: (_) => _saveRate(),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: primary),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: Icon(Icons.save, color: primary),
            label: Text('GUARDAR TARIFA', style: TextStyle(color: primary, fontWeight: FontWeight.bold)),
            onPressed: () {
              // Forzar cierre de teclado y quitar foco del campo antes de guardar.
              FocusScope.of(context).unfocus();
              Future.delayed(const Duration(milliseconds: 50), _saveRate);
            },
          ),
        ),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white10),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CREAR MESA',
                style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
              ),
              const SizedBox(height: 12),
              _ConfigField(
                controller: _nameCtrl,
                label: 'Nombre de la mesa',
                icon: Icons.table_bar,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _addTable(),
              ),
              const SizedBox(height: 8),
              const Text(
                'TIPO DE MESA',
                style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children:
                    ['Billar', 'Comanda'].map((type) {
                      final selected = _newTableType == type;
                      return ChoiceChip(
                        label: Text(type),
                        selected: selected,
                        selectedColor: primary.withValues(alpha: 0.3),
                        backgroundColor: Colors.white10,
                        side: BorderSide(color: selected ? primary : Colors.white24),
                        labelStyle: TextStyle(
                          color: selected ? primary : Colors.white70,
                          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                        ),
                        onSelected: (_) => setState(() => _newTableType = type),
                      );
                    }).toList(),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primary,
                    side: BorderSide(color: primary),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('AGREGAR MESA', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _addTable,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'MESAS EXISTENTES',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _loadTables(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: Colors.white24));
            }
            final tables = snapshot.data ?? [];
            if (tables.isEmpty) {
              return const Text(
                'No hay mesas. Usa el formulario de arriba para crear la primera.',
                style: TextStyle(color: Colors.white24, fontSize: 12),
              );
            }
            return Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: tables.length,
                separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
                itemBuilder: (_, i) {
                  final t = tables[i];
                  final id = t['id'] as int;
                  final type = t['table_type'] as String? ?? 'Billar';
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Icon(
                          type == 'Comanda' ? Icons.restaurant_menu : Icons.table_bar,
                          color: primary,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t['name'] as String? ?? 'Mesa $id',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                '#$id · $type',
                                style: const TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.white38, size: 20),
                          onPressed: () => _editTableName(id, t['name'] as String? ?? 'Mesa $id'),
                          tooltip: 'Editar nombre',
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                          onPressed: () => _removeTable(id),
                          tooltip: 'Eliminar mesa',
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

class _TableRow extends StatefulWidget {
  final Map<String, dynamic> table;
  final ValueChanged<String> onNameChanged;
  final VoidCallback onDelete;

  const _TableRow({required this.table, required this.onNameChanged, required this.onDelete});

  @override
  State<_TableRow> createState() => _TableRowState();
}

class _TableRowState extends State<_TableRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.table['name'] as String? ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final id = widget.table['id'] as int;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Text('#$id', style: TextStyle(color: primary, fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: 'Mesa Billar $id',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onSubmitted: widget.onNameChanged,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
            onPressed: widget.onDelete,
            tooltip: 'Eliminar mesa',
          ),
        ],
      ),
    );
  }
}

// ─── SECCIÓN APARIENCIA ───────────────────────────────────────────────────────
class _TableListEditor extends StatefulWidget {
  final VoidCallback onChanged;
  final Color primaryColor;
  const _TableListEditor({required this.onChanged, required this.primaryColor});

  @override
  State<_TableListEditor> createState() => _TableListEditorState();
}

class _TableListEditorState extends State<_TableListEditor> {
  final _repo = BilliardTableRepository();

  Future<List<Map<String, dynamic>>> _load() async {
    final prefs = PreferencesService();
    var tables = await _repo.getAll(billarId: prefs.billarId);
    if (tables.isEmpty && prefs.tableCount > 0) {
      final db = await DatabaseHelper.instance.database;
      for (int i = 1; i <= prefs.tableCount; i++) {
        await db.insert('billiard_tables', {
          'id': i,
          'billar_id': prefs.billarId,
          'name': 'Mesa $i',
          'table_type': prefs.defaultTableType,
          'is_occupied': 0,
          'orders': '[]',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      tables = await _repo.getAll(billarId: prefs.billarId);
    }
    return tables.map((t) => Map<String, dynamic>.from(t)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _load(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: Colors.white24));
        }
        final tables = snapshot.data ?? [];
        if (tables.isEmpty) {
          return const Text(
            'No hay mesas. Ajusta el número arriba y guarda.',
            style: TextStyle(color: Colors.white24, fontSize: 12),
          );
        }
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white10),
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: tables.length,
            separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
            itemBuilder: (_, i) {
              final t = tables[i];
              final id = t['id'] as int;
              return ListTile(
                leading: Text(
                  '#$id',
                  style: TextStyle(
                    color: widget.primaryColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                title: Text(
                  t['name'] as String? ?? 'Mesa $id',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              );
            },
          ),
        );
      },
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
        const Text(
          'MODO DE PANTALLA',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _ModeCard(
              icon: Icons.dark_mode,
              label: 'Oscuro',
              selected: theme.isDark,
              color: theme.primaryColor,
              onTap: () {
                if (!theme.isDark) theme.toggleTheme();
              },
            ),
            const SizedBox(width: 12),
            _ModeCard(
              icon: Icons.light_mode,
              label: 'Claro',
              selected: !theme.isDark,
              color: theme.primaryColor,
              onTap: () {
                if (theme.isDark) theme.toggleTheme();
              },
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          'COLOR PRINCIPAL',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children:
              _palette.map((entry) {
                final (color, name) = entry;
                final isSelected = theme.primaryColor.toARGB32() == color.toARGB32();
                return GestureDetector(
                  onTap: () => theme.setPrimaryColor(color),
                  child: Tooltip(
                    message: name,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow:
                            isSelected
                                ? [
                                  BoxShadow(
                                    color: color.withValues(alpha: 0.6),
                                    blurRadius: 12,
                                    spreadRadius: 2,
                                  ),
                                ]
                                : [],
                      ),
                      child:
                          isSelected
                              ? const Icon(Icons.check, color: Colors.white, size: 22)
                              : null,
                    ),
                  ),
                );
              }).toList(),
        ),
        const SizedBox(height: 28),
        const Text(
          'ESTILO DE COLORES',
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 12),
        _buildCardStyleOption(
          theme: theme,
          style: CardStyle.gradient,
          icon: Icons.gradient,
          title: 'Degradado',
          subtitle: 'Fondo con degradado sutil del color',
        ),
        const SizedBox(height: 10),
        _buildCardStyleOption(
          theme: theme,
          style: CardStyle.outlined,
          icon: Icons.crop_square,
          title: 'Contorno de color',
          subtitle: 'Fondo neutro con borde del color dominante',
        ),
        const SizedBox(height: 10),
        _buildCardStyleOption(
          theme: theme,
          style: CardStyle.solidWhite,
          icon: Icons.format_color_fill,
          title: 'Sólido blanco',
          subtitle: 'Fondo de color con icono y texto en blanco',
        ),
        const SizedBox(height: 8),
        Text('Color actual', style: TextStyle(color: Colors.white38, fontSize: 11)),

        const SizedBox(height: 4),
        Row(
          children: [
            Container(
              width: 20,
              height: 20,
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

  Widget _buildCardStyleOption({
    required ThemeProvider theme,
    required CardStyle style,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = theme.cardStyle == style;
    return GestureDetector(
      onTap: () => theme.setCardStyle(style),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? theme.primaryColor : Colors.white12,
            width: selected ? 2 : 1,
          ),
          color: selected ? theme.primaryColor.withValues(alpha: 0.12) : const Color(0xFF1A1A1A),
        ),
        child: Row(
          children: [
            Icon(icon, color: selected ? theme.primaryColor : Colors.white38, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: selected ? theme.primaryColor : Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? theme.primaryColor : Colors.white38,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

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
              Text(
                label,
                style: TextStyle(
                  color: selected ? color : Colors.white38,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── SECCIÓN SESIÓN ───────────────────────────────────────────────────────────
class _SesionSection extends StatefulWidget {
  const _SesionSection();
  @override
  State<_SesionSection> createState() => _SesionSectionState();
}

class _SesionSectionState extends State<_SesionSection> {
  final _prefs = PreferencesService();
  bool _loading = false;

  Future<void> _confirmLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.logout, color: Color(0xFFE53935)),
                SizedBox(width: 10),
                Text('Cerrar sesión', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: const Text(
              'Las mesas activas y todos los datos del negocio se mantendrán en el dispositivo.\n\nSe intentará sincronizar antes de cerrar.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Cerrar sesión', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
    );

    if (confirm != true || !mounted) return;

    setState(() => _loading = true);
    try {
      // Intentar sincronizar pendientes si hay conexión
      await SyncService().syncAllPending();
      // Cerrar sesión en Supabase
      await Supabase.instance.client.auth.signOut();
      // Limpiar solo el nombre de usuario local
      await _prefs.clearSession();
    } catch (_) {
      // Si falla el signOut (sin conexión), igual limpiamos localmente
      await _prefs.clearSession();
    } finally {
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(icon: Icons.person, title: 'SESIÓN ACTIVA', color: Color(0xFFE53935)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: const Color(0xFF1A1A1A),
            border: Border.all(color: Colors.white10),
          ),
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: Color(0xFF2A2A2A),
                radius: 24,
                child: Icon(Icons.person, color: Colors.white54, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _prefs.userName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      user?.email ?? 'Sin conexión activa',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Las mesas activas y los datos del negocio se conservan al cerrar sesión.',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _loading ? null : _confirmLogout,
            icon:
                _loading
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                    : const Icon(Icons.logout, color: Colors.white),
            label: Text(
              _loading ? 'Cerrando sesión...' : 'CERRAR SESIÓN',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ),
        ),
      ],
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
        Text(
          title,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

class _ConfigField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization textCapitalization;
  final void Function(String)? onSubmitted;

  const _ConfigField({
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.sentences,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        textCapitalization: textCapitalization,
        onTap: () {
          if (controller.text.isEmpty) return;
          controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
        },
        onSubmitted: onSubmitted,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
      ),
    );
  }
}

class _PhoneField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  const _PhoneField({required this.controller, required this.label, required this.icon});

  @override
  State<_PhoneField> createState() => _PhoneFieldState();
}

class _PhoneFieldState extends State<_PhoneField> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: widget.controller,
        keyboardType: TextInputType.phone,
        maxLength: 12, // 10 dígitos + 2 guiones de la máscara
        buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          _PhoneMaskFormatter(),
        ],
        onTap: () {
          if (widget.controller.text.isEmpty) return;
          widget.controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: widget.controller.text.length,
          );
        },
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: '000-000-0000',
          prefixIcon: Icon(
            widget.icon,
            color: widget.icon == Icons.chat ? Colors.green : Colors.white60,
          ),
        ),
      ),
    );
  }
}

class _PhoneMaskFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 10) {
      return oldValue;
    }
    String masked;
    if (digits.length >= 7) {
      masked = '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
    } else if (digits.length >= 4) {
      masked = '${digits.substring(0, 3)}-${digits.substring(3)}';
    } else {
      masked = digits;
    }
    final selectionIndex = masked.length;
    return TextEditingValue(
      text: masked,
      selection: TextSelection.collapsed(offset: selectionIndex),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              '$label:',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
        ],
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
        label: const Text(
          'GUARDAR',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
        ),
      ),
    );
  }
}
