import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/storage/account_storage.dart';

Future<void> signOutManagedAccount(BuildContext context) async {
  AccountStorage.instance.retire();
  Object? error;
  try {
    await Supabase.instance.client.auth.signOut();
  } catch (e, stack) {
    error = e;
    debugPrint(
      '[AccountAccess] No se pudo cerrar completamente la sesión: $e\n$stack',
    );
  }
  if (context.mounted) {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
    if (error != null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'No se pudo confirmar el cierre remoto. Cierra y vuelve a abrir la aplicación.',
          ),
        ),
      );
    }
  }
}
