import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/staff_access.dart';

class StaffRoleTemplate {
  StaffRoleTemplate({
    required this.id,
    required this.billarId,
    required this.name,
    required Set<StaffModule> modules,
    required this.revision,
  }) : modules = Set.unmodifiable(modules);

  final String id;
  final String billarId;
  final String name;
  final Set<StaffModule> modules;
  final int revision;

  factory StaffRoleTemplate.fromMap(
    Map<dynamic, dynamic> row,
    String billarId,
  ) {
    final id = row['id'];
    final name = row['name'];
    final revision = row['revision'];
    final rawModules = row['modules'];
    if (id is! String ||
        id.isEmpty ||
        row['billar_id'] != billarId ||
        name is! String ||
        name.trim() != name ||
        name.isEmpty ||
        name.length > 80 ||
        revision is! int ||
        revision < 0 ||
        rawModules is! List) {
      throw const FormatException('La plantilla de rol no es válida.');
    }
    final modules =
        rawModules.isEmpty ? <StaffModule>{} : parseStaffModules(rawModules);
    if (!modules.every(StaffModule.pilotModules.contains)) {
      throw const FormatException(
        'La plantilla contiene permisos no disponibles.',
      );
    }
    return StaffRoleTemplate(
      id: id,
      billarId: billarId,
      name: name,
      modules: modules,
      revision: revision,
    );
  }
}

abstract interface class StaffRoleTemplateStore {
  Future<List<StaffRoleTemplate>> list();
  Future<StaffRoleTemplate> save({
    StaffRoleTemplate? existing,
    required String name,
    required Set<StaffModule> modules,
  });
  Future<void> delete(StaffRoleTemplate template);
}

class StaffRoleTemplateRepository implements StaffRoleTemplateStore {
  const StaffRoleTemplateRepository({
    required SupabaseClient client,
    required String billarId,
    required String token,
    required bool Function() sessionUnchanged,
  }) : _client = client,
       _billarId = billarId,
       _token = token,
       _sessionUnchanged = sessionUnchanged;

  final SupabaseClient _client;
  final String _billarId;
  final String _token;
  final bool Function() _sessionUnchanged;

  void _requireSession() {
    if (!_sessionUnchanged()) {
      throw StateError(
        'La sesión o el billar cambió. Vuelve a abrir el formulario.',
      );
    }
  }

  Future<Object?> _invoke(String function, Map<String, Object?> params) async {
    _requireSession();
    final response = await _client
        .rpc(function, params: {'requested_billar_id': _billarId, ...params})
        .setHeader('Authorization', 'Bearer $_token');
    _requireSession();
    return response;
  }

  @override
  Future<List<StaffRoleTemplate>> list() async {
    final data = await _invoke('staff_role_templates_list', {});
    if (data is! List) {
      throw const FormatException('La lista de roles no es válida.');
    }
    final roles = <StaffRoleTemplate>[];
    final ids = <String>{};
    for (final row in data) {
      if (row is! Map) {
        throw const FormatException('La lista de roles no es válida.');
      }
      final role = StaffRoleTemplate.fromMap(row, _billarId);
      if (!ids.add(role.id)) {
        throw const FormatException('La lista de roles contiene duplicados.');
      }
      roles.add(role);
    }
    return List.unmodifiable(roles);
  }

  @override
  Future<StaffRoleTemplate> save({
    StaffRoleTemplate? existing,
    required String name,
    required Set<StaffModule> modules,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty ||
        cleanName.length > 80 ||
        !modules.every(StaffModule.pilotModules.contains) ||
        (existing != null && existing.billarId != _billarId)) {
      throw StateError(
        'El nombre o los módulos de la plantilla no son válidos.',
      );
    }
    if (modules.isNotEmpty) {
      try {
        parseStaffModules(modules.map((module) => module.id).toList());
      } on FormatException {
        throw StateError(
          'El módulo de servicio debe incluir al menos un permiso operativo.',
        );
      }
    }
    final data = await _invoke('staff_role_template_save', {
      'template_id': existing?.id,
      'expected_revision': existing?.revision,
      'template_name': cleanName,
      'template_modules': modules.map((module) => module.id).toList()..sort(),
    });
    if (data is! Map) {
      throw const FormatException('La respuesta del rol no es válida.');
    }
    final result = StaffRoleTemplate.fromMap(data, _billarId);
    if (result.name != cleanName ||
        !setEquals(result.modules, modules) ||
        (existing == null && result.revision != 0) ||
        (existing != null &&
            (result.id != existing.id ||
                result.revision != existing.revision + 1))) {
      throw const FormatException(
        'La respuesta no coincide con el rol solicitado.',
      );
    }
    return result;
  }

  @override
  Future<void> delete(StaffRoleTemplate template) async {
    if (template.billarId != _billarId) {
      throw StateError('La plantilla no pertenece a este negocio.');
    }
    await _invoke('staff_role_template_delete', {
      'template_id': template.id,
      'expected_revision': template.revision,
    });
  }
}
