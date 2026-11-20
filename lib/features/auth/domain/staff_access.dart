const staffPilotEnabled = bool.fromEnvironment('STAFF_PILOT_ENABLED');

enum StaffModule {
  quickSale('quick_sale', 'Venta rápida'),
  billiardTables('billiard_tables', 'Mesas de billar'),
  billiardTablesOpen('billiard_tables_open', 'Abrir e iniciar tiempo'),
  billiardTablesConsume('billiard_tables_consume', 'Anotar consumos'),
  billiardTablesCharge('billiard_tables_charge', 'Cobrar o cerrar'),
  billiardTablesViewAll('billiard_tables_view_all', 'Ver servicios de otros'),
  dineIn('dine_in', 'Comandas'),
  dineInOpen('dine_in_open', 'Abrir comanda'),
  dineInConsume('dine_in_consume', 'Anotar consumos'),
  dineInCharge('dine_in_charge', 'Cobrar o cerrar'),
  dineInViewAll('dine_in_view_all', 'Ver servicios de otros'),
  personalAccount('personal_account', 'Cuenta personal'),
  inventory('inventory', 'Inventario'),
  purchases('purchases', 'Compras'),
  cashOperations('cash_operations', 'Caja y turnos'),
  reports('reports', 'Informes'),
  reportsSales('reports_sales', 'Informes de ventas'),
  reportsPurchases('reports_purchases', 'Informes de compras'),
  reportsCashFlow('reports_cash_flow', 'Informes de flujo de caja'),
  reportsKardex('reports_kardex', 'Kardex'),
  reportsProfit('reports_profit', 'Informes de utilidad'),
  players('players', 'Jugadores y torneos'),
  settings('settings', 'Configuración');

  const StaffModule(this.id, this.label);

  final String id;
  final String label;

  StaffModule? get parent => switch (this) {
    billiardTablesOpen ||
    billiardTablesConsume ||
    billiardTablesCharge ||
    billiardTablesViewAll => billiardTables,
    dineInOpen || dineInConsume || dineInCharge || dineInViewAll => dineIn,
    reportsSales ||
    reportsPurchases ||
    reportsCashFlow ||
    reportsKardex ||
    reportsProfit => reports,
    _ => null,
  };

  Map<String, StaffModule> get sectionPermissions => switch (this) {
    billiardTables => const {
      'Iniciar tiempo': billiardTablesOpen,
      'Anotar consumos': billiardTablesConsume,
      'Cobrar o cerrar': billiardTablesCharge,
      'Ver servicios de otros': billiardTablesViewAll,
    },
    dineIn => const {
      'Abrir comanda': dineInOpen,
      'Anotar consumos': dineInConsume,
      'Cobrar o cerrar': dineInCharge,
      'Ver servicios de otros': dineInViewAll,
    },
    reports => const {
      'Ventas': reportsSales,
      'Compras': reportsPurchases,
      'Flujo de caja': reportsCashFlow,
      'Kardex': reportsKardex,
      'Utilidad': reportsProfit,
    },
    _ => const {},
  };

  bool get isOperationalPermission =>
      parent == billiardTables || parent == dineIn;

  bool get canAssignWhole =>
      sectionPermissions.isEmpty
          ? pilotModules.contains(this)
          : sectionPermissions.values.every(pilotModules.contains);

  List<String> get sections => switch (this) {
    quickSale => const ['Catálogo y carrito', 'Cobro y comprobante'],
    billiardTables => const [
      'Iniciar tiempo',
      'Anotar consumos',
      'Cobrar o cerrar',
      'Ver servicios de otros',
      'Traspasar servicio',
    ],
    dineIn => const [
      'Abrir comanda',
      'Anotar consumos',
      'Cobrar o cerrar',
      'Ver servicios de otros',
      'Traspasar servicio',
    ],
    personalAccount => const [
      'Abrir cuenta',
      'Anotar consumos',
      'Cobrar o cerrar',
      'Ver servicios de otros',
      'Traspasar servicio',
    ],
    inventory => const ['Consulta de productos y existencias'],
    purchases => const [
      'Registro e historial de compras',
      'Condiciones y forma de pago',
      'Gestión de proveedores',
    ],
    cashOperations => const [
      'Apertura y cierre de turno',
      'Retiros y gastos',
      'Conceptos de movimientos',
      'Cortes y comprobantes',
    ],
    reports => const [
      'Ventas',
      'Compras',
      'Flujo de caja',
      'Kardex',
      'Utilidad',
    ],
    reportsSales ||
    reportsPurchases ||
    reportsCashFlow ||
    reportsKardex ||
    reportsProfit ||
    billiardTablesOpen ||
    billiardTablesConsume ||
    billiardTablesCharge ||
    billiardTablesViewAll ||
    dineInOpen ||
    dineInConsume ||
    dineInCharge ||
    dineInViewAll => const [],
    players => const ['Jugadores', 'Partidas', 'Torneos'],
    settings => const [
      'Datos del negocio',
      'Impresión de tickets',
      'Mesas de billar y comanda',
      'Ventas e inventario',
      'Apariencia',
      'Personal (solo administrador)',
    ],
  };

  static const pilotModules = {
    StaffModule.quickSale,
    StaffModule.billiardTables,
    StaffModule.billiardTablesOpen,
    StaffModule.billiardTablesConsume,
    StaffModule.billiardTablesCharge,
    StaffModule.billiardTablesViewAll,
    StaffModule.dineIn,
    StaffModule.dineInOpen,
    StaffModule.dineInConsume,
    StaffModule.dineInCharge,
    StaffModule.dineInViewAll,
    StaffModule.inventory,
    StaffModule.purchases,
    StaffModule.reportsSales,
    StaffModule.reportsPurchases,
    StaffModule.reportsCashFlow,
    StaffModule.reportsKardex,
    StaffModule.reportsProfit,
  };
}

enum StaffRoleRecommendation {
  waiter(
    'Mesero',
    {
      StaffModule.billiardTables,
      StaffModule.billiardTablesOpen,
      StaffModule.billiardTablesConsume,
      StaffModule.dineIn,
      StaffModule.dineInOpen,
      StaffModule.dineInConsume,
    },
    'Mesas y comandas propias: abrir y anotar consumos, sin cobrar ni ver '
        'servicios de otros. El traspaso sigue pendiente.',
  ),
  cashier(
    'Cajero',
    {
      StaffModule.quickSale,
      StaffModule.billiardTables,
      StaffModule.billiardTablesCharge,
      StaffModule.billiardTablesViewAll,
      StaffModule.dineIn,
      StaffModule.dineInCharge,
      StaffModule.dineInViewAll,
    },
    'Venta rápida y cobro de mesas y comandas visibles, incluidos servicios '
        'de otros. No incluye abrir ni anotar consumos.',
  ),
  supervisor(
    'Encargado',
    {
      StaffModule.quickSale,
      StaffModule.billiardTables,
      StaffModule.billiardTablesCharge,
      StaffModule.billiardTablesViewAll,
      StaffModule.dineIn,
      StaffModule.dineInCharge,
      StaffModule.dineInViewAll,
    },
    'Venta rápida, consulta y cobro de mesas y comandas, incluidos servicios '
        'de otros. El traspaso sigue pendiente y no se asigna.',
  ),
  administrator(
    'Administrador',
    {},
    'Esta recomendación no concede acceso de administrador. '
        'El acceso administrativo se controla por separado.',
  );

  const StaffRoleRecommendation(this.title, this.modules, this.description);

  final String title;
  final Set<StaffModule> modules;
  final String description;
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
  for (final parent in [StaffModule.billiardTables, StaffModule.dineIn]) {
    final hasParent = selected.contains(parent);
    final hasPermission = selected.any(
      (module) => module.isOperationalPermission && module.parent == parent,
    );
    if (hasParent != hasPermission) {
      throw const FormatException(
        'Cada módulo operativo debe incluir al menos un permiso propio.',
      );
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
