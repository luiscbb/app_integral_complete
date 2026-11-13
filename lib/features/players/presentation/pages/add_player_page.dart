import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/formatters/phone_mask_formatter.dart';
import '../../domain/entities/player_stats.dart';
import '../providers/players_provider.dart';

class AddPlayerPage extends StatefulWidget {
  final PlayersProvider playersProvider;
  final PlayerEntity? player;

  const AddPlayerPage({
    super.key,
    required this.playersProvider,
    this.player,
  });

  @override
  State<AddPlayerPage> createState() => _AddPlayerPageState();
}

class _AddPlayerPageState extends State<AddPlayerPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _nickCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late int _handicap;
  String? _avatarPath;
  bool _isSaving = false;

  bool get _isEditing => widget.player != null;

  @override
  void initState() {
    super.initState();
    final player = widget.player;
    _nameCtrl = TextEditingController(text: player?.name.toUpperCase() ?? '');
    _nickCtrl = TextEditingController(text: player?.nickname.toUpperCase() ?? '');
    _emailCtrl = TextEditingController(text: player?.email ?? '');
    _phoneCtrl = TextEditingController(text: player?.phone ?? '');
    _handicap = player?.handicap ?? 1;
    _avatarPath = player?.avatar;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nickCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      String? pickedPath;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        if (source == ImageSource.camera) {
          _showMessage('La cámara no está disponible en esta versión de escritorio.');
          return;
        }
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: false,
        );
        pickedPath = result?.files.single.path;
      } else {
        final picked = await ImagePicker().pickImage(
          source: source,
          imageQuality: 85,
          maxWidth: 1200,
          maxHeight: 1200,
        );
        pickedPath = picked?.path;
      }

      if (pickedPath != null && mounted) {
        setState(() => _avatarPath = pickedPath);
      }
    } catch (e, st) {
      debugPrint('[AddPlayerPage] Error seleccionando foto: $e\n$st');
      _showMessage(
        source == ImageSource.camera
            ? 'No se pudo acceder a la cámara.'
            : 'No se pudo seleccionar la foto.',
      );
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      if (_isEditing) {
        final updated = widget.player!.copyWith(
          name: _nameCtrl.text.trim().toUpperCase(),
          nickname: _nickCtrl.text.trim().toUpperCase(),
          email: _emailCtrl.text.trim().toLowerCase(),
          phone: _phoneCtrl.text.trim(),
          handicap: _handicap,
        );
        final temporaryPassword =
            await widget.playersProvider.updateRegistration(
          updated,
          newAvatarPath: _avatarPath == widget.player!.avatar ? null : _avatarPath,
        );
        if (temporaryPassword != null && mounted) {
          final linkedPlayer = widget.playersProvider.players.firstWhere(
            (item) => item.id == updated.id,
            orElse: () => updated,
          );
          await _showCredentials(
            linkedPlayer,
            temporaryPassword,
          );
        }
        if (mounted) Navigator.pop(context, true);
        return;
      }

      final result = await widget.playersProvider.add(
        name: _nameCtrl.text.trim().toUpperCase(),
        email: _emailCtrl.text.trim().toLowerCase(),
        phone: _phoneCtrl.text.trim(),
        nickname: _nickCtrl.text.trim().toUpperCase(),
        handicap: _handicap,
        avatarPath: _avatarPath ?? '',
      );
      if (!mounted) return;
      await _showCredentials(result.player, result.temporaryPassword);
      if (mounted) Navigator.pop(context, true);
    } catch (e, st) {
      debugPrint('[AddPlayerPage] Error guardando jugador: $e\n$st');
      _showMessage('No se pudo guardar: ${_errorMessage(e)}');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _showCredentials(
    PlayerEntity player,
    String temporaryPassword,
  ) async {
    var copied = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('ACCESO PROVISIONAL'),
          content: SelectableText(
            'Jugador: ${player.name}\n'
            'Código: ${player.playerCode}\n'
            'Correo: ${player.email}\n'
            'Contraseña temporal: $temporaryPassword\n\n'
            'Entrégala al jugador. La app le pedirá cambiarla en su primer inicio.',
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text:
                        'Código: ${player.playerCode}\nCorreo: ${player.email}\n'
                        'Contraseña temporal: $temporaryPassword',
                  ),
                );
                setDialogState(() => copied = true);
              },
              icon: Icon(copied ? Icons.check : Icons.copy),
              label: Text(copied ? 'COPIADO' : 'COPIAR ACCESO'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CERRAR'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  String _errorMessage(Object error) {
    final text = error.toString();
    return text.startsWith('StateError: ')
        ? text.substring('StateError: '.length)
        : text;
  }

  Widget _buildAvatar() {
    final path = _avatarPath;
    ImageProvider? image;
    if (path != null && path.isNotEmpty) {
      final uri = Uri.tryParse(path);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        image = NetworkImage(path);
      } else {
        image = FileImage(File(path));
      }
    }
    return CircleAvatar(
      radius: 46,
      backgroundColor: Colors.white12,
      backgroundImage: image,
      child: image == null
          ? const Icon(Icons.person, size: 44, color: Colors.white54)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'EDITAR JUGADOR' : 'NUEVO JUGADOR'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          children: [
            Center(child: _buildAvatar()),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('CÁMARA'),
                    onPressed: _isSaving
                        ? null
                        : () => _pickImage(ImageSource.camera),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.photo_outlined),
                    label: const Text('GALERÍA'),
                    onPressed: _isSaving
                        ? null
                        : () => _pickImage(ImageSource.gallery),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (_, value) => value.copyWith(text: value.text.toUpperCase()),
                ),
              ],
              decoration: const InputDecoration(labelText: 'Nombre completo'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Ingresa el nombre completo'
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _nickCtrl,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (_, value) => value.copyWith(text: value.text.toUpperCase()),
                ),
              ],
              decoration: const InputDecoration(labelText: 'Nickname'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Correo del jugador',
                helperText: 'Se usará para iniciar sesión y debe ser único.',
              ),
              validator: (value) {
                final email = value?.trim() ?? '';
                if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
                  return 'Ingresa un correo válido';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                PhoneMaskFormatter(),
              ],
              decoration: const InputDecoration(
                labelText: 'Teléfono',
                hintText: '000-000-0000',
                prefixIcon: Icon(Icons.phone),
              ),
              validator: (value) {
                final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
                return digits.length == 10
                    ? null
                    : 'Ingresa un teléfono de 10 dígitos';
              },
            ),
            const SizedBox(height: 22),
            Text(
              'NIVEL / HANDICAP: $_handicap',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                letterSpacing: 1.2,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (index) {
                final value = index + 1;
                return IconButton(
                  tooltip: 'Handicap $value',
                  icon: Icon(
                    value <= _handicap
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: value <= _handicap ? Colors.amber : Colors.white24,
                    size: 32,
                  ),
                  onPressed: _isSaving
                      ? null
                      : () => setState(() => _handicap = value),
                );
              }),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _isSaving ? null : _save,
                child: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(_isEditing ? 'GUARDAR CAMBIOS' : 'REGISTRAR JUGADOR'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
