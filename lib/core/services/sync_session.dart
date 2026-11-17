import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/preferences_service.dart';

typedef SyncSession = ({
  String actorId,
  String billarId,
  String token,
  Session authSession,
  int scopeGeneration,
});

class SyncSessionGuard {
  const SyncSessionGuard(this.client, this.preferences);

  final SupabaseClient client;
  final PreferencesService preferences;

  SyncSession capture() {
    final session = client.auth.currentSession;
    final billarId = preferences.billarId;
    if (session == null ||
        session.user.id.isEmpty ||
        session.accessToken.isEmpty ||
        billarId.trim().isEmpty) {
      throw StateError('Se requiere una sesión y un billar válidos.');
    }
    return (
      actorId: session.user.id,
      billarId: billarId,
      token: session.accessToken,
      authSession: session,
      scopeGeneration: preferences.scopeGeneration,
    );
  }

  void require(SyncSession expected) {
    final session = client.auth.currentSession;
    if (preferences.billarId != expected.billarId ||
        preferences.scopeGeneration != expected.scopeGeneration ||
        !identical(session, expected.authSession) ||
        session?.user.id != expected.actorId ||
        session?.accessToken != expected.token) {
      throw StateError('La sesión o el billar cambió durante la operación.');
    }
  }
}
