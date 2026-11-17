const staffPilotEnabled = bool.fromEnvironment('STAFF_PILOT_ENABLED');

enum StaffModule {
  quickSale('quick_sale', 'Venta rápida'),
  billiardTables('billiard_tables', 'Mesas de billar'),
  dineIn('dine_in', 'Comandas'),
  personalAccount('personal_account', 'Cuenta personal'),
  inventory('inventory', 'Inventario'),
  purchases('purchases', 'Compras'),
  reports('reports', 'Informes'),
  players('players', 'Jugadores y torneos'),
  settings('settings', 'Configuración');

  const StaffModule(this.id, this.label);

  final String id;
  final String label;

  static const pilotModules = {
    StaffModule.quickSale,
    StaffModule.inventory,
    StaffModule.purchases,
  };
}

Set<StaffModule> parseStaffModules(Object? modules) {
  if (modules is! List || modules.isEmpty) {
    throw const FormatException('Los módulos del personal no son válidos.');
  }
  final selected = <StaffModule>{};
  for (final id in modules) {
    final matches = StaffModule.values.where((module) => module.id == id);
    if (matches.length != 1 || !selected.add(matches.single)) {
      throw const FormatException('Los módulos del personal no son válidos.');
    }
  }
  return Set.unmodifiable(selected);
}

String normalizeStaffUsername(String value) => value.trim().toLowerCase();

bool isValidStaffUsername(String value) {
  final username = normalizeStaffUsername(value);
  return RegExp(r'^[a-z0-9][a-z0-9._-]{2,31}$').hasMatch(username);
}

String staffUsernameToAuthEmail(String value) {
  final username = normalizeStaffUsername(value);
  if (!isValidStaffUsername(username)) {
    throw ArgumentError('El usuario no tiene un formato válido.');
  }
  final encoded =
      username.codeUnits
          .map((unit) => unit.toRadixString(16).padLeft(2, '0'))
          .join();
  return '$encoded@staff.baumar.invalid';
}

class StaffAccountDraft {
  StaffAccountDraft({
    required this.fullName,
    required this.username,
    required this.jobTitle,
    required Set<StaffModule> modules,
  }) : modules = Set.unmodifiable(modules);

  final String fullName;
  final String username;
  final String jobTitle;
  final Set<StaffModule> modules;
}

class StaffAccount {
  const StaffAccount({
    required this.userId,
    required this.billarId,
    required this.draft,
    required this.isActive,
    required this.mustChangePassword,
    required this.revision,
  });

  final String userId;
  final String billarId;
  final StaffAccountDraft draft;
  final bool isActive;
  final bool mustChangePassword;
  final int revision;

  factory StaffAccount.fromMap(Map<dynamic, dynamic> row) {
    final userId = row['user_id'];
    final billarId = row['billar_id'];
    final username = row['username'];
    final name = row['full_name'];
    final jobTitle = row['job_title'];
    final modules = row['allowed_modules'];
    final active = row['is_active'];
    final mustChange = row['must_change_password'];
    final revision = row['staff_revision'];
    if (userId is! String ||
        userId.isEmpty ||
        billarId is! String ||
        billarId.isEmpty ||
        username is! String ||
        !isValidStaffUsername(username) ||
        username != normalizeStaffUsername(username) ||
        name is! String ||
        name.trim().isEmpty ||
        jobTitle is! String ||
        jobTitle.trim().isEmpty ||
        modules is! List ||
        modules.isEmpty ||
        active is! bool ||
        mustChange is! bool ||
        revision is! int ||
        revision < 0) {
      throw const FormatException('La información del personal no es válida.');
    }
    final selected = parseStaffModules(modules);
    return StaffAccount(
      userId: userId,
      billarId: billarId,
      draft: StaffAccountDraft(
        username: username,
        fullName: name,
        jobTitle: jobTitle,
        modules: selected,
      ),
      isActive: active,
      mustChangePassword: mustChange,
      revision: revision,
    );
  }
}
