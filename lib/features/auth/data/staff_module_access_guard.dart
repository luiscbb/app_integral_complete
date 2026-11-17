import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/sync_session.dart';
import '../domain/staff_access.dart';
import 'auth_access_repository.dart';

Future<void> requireStaffModuleAccess({
  required SupabaseClient client,
  required SyncSession session,
  required void Function(SyncSession) requireSession,
  required StaffModule module,
}) async {
  requireSession(session);
  final account =
      await AuthAccessRepository(
        client: client,
        enableStaffForIntegration: true,
      ).resolveCurrentAccount();
  requireSession(session);
  if (account.kind != AccountKind.staff ||
      account.billarId != session.billarId ||
      account.mustChangePassword ||
      !account.allowedModules.contains(module)) {
    throw StateError(
      'La cuenta no tiene permiso activo para usar ${module.label}.',
    );
  }
}
