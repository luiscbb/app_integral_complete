import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/preferences_service.dart';
import 'private_image_service.dart';

Future<Uint8List?> loadBusinessLogo(
  PreferencesService preferences, {
  bool remoteFirst = false,
  PrivateImageService? imageService,
}) async {
  Future<Uint8List?> local() async {
    if (preferences.logoPath.isEmpty) return null;
    final file = File(preferences.logoPath);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } on FileSystemException catch (error, stack) {
      debugPrint(
        '[BusinessLogo] No se pudo leer el logo local: $error\n$stack',
      );
      return null;
    }
  }

  Future<({Uint8List? bytes, bool allowLocalFallback})> remote() async {
    if (preferences.logoUrl.isEmpty) {
      return (bytes: null, allowLocalFallback: true);
    }
    try {
      return (
        bytes: await (imageService ?? PrivateImageService.current()).loadRemote(
          preferences.logoUrl,
        ),
        allowLocalFallback: true,
      );
    } on StorageException catch (error, stack) {
      debugPrint(
        '[BusinessLogo] Acceso remoto al logo denegado: $error\n$stack',
      );
      return (bytes: null, allowLocalFallback: false);
    } on Exception catch (error, stack) {
      debugPrint('[BusinessLogo] No se pudo descargar el logo: $error\n$stack');
      return (bytes: null, allowLocalFallback: true);
    }
  }

  if (!remoteFirst) {
    final bytes = await local();
    if (bytes != null) return bytes;
  }
  final result = await remote();
  if (result.bytes != null || !remoteFirst || !result.allowLocalFallback) {
    return result.bytes;
  }
  return local();
}
