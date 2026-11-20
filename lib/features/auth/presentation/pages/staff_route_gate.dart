import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/account_storage.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../inventory/presentation/pages/staff_inventory_page.dart';
import '../../../home/presentation/pages/staff_home_page.dart';
import '../../../players/presentation/pages/player_access_pages.dart';
import '../../../quick_sale/presentation/pages/staff_quick_sale_page.dart';
import '../../../purchases/presentation/pages/staff_purchases_page.dart';
import '../../../reports/presentation/pages/staff_reports_page.dart';
import '../../../sales/presentation/pages/staff_table_service_page.dart';
import '../../data/auth_access_repository.dart';
import '../../domain/staff_access.dart';
import 'managed_account_sign_out.dart';

const _staffModuleRoutes = {
  StaffModule.quickSale: AppRoutes.quickSale,
  StaffModule.billiardTablesOpen: AppRoutes.billiardTables,
  StaffModule.billiardTablesConsume: AppRoutes.billiardTables,
  StaffModule.billiardTablesCharge: AppRoutes.billiardTables,
  StaffModule.billiardTablesViewAll: AppRoutes.billiardTables,
  StaffModule.dineInOpen: AppRoutes.dineIn,
  StaffModule.dineInConsume: AppRoutes.dineIn,
  StaffModule.dineInCharge: AppRoutes.dineIn,
  StaffModule.dineInViewAll: AppRoutes.dineIn,
  StaffModule.inventory: AppRoutes.inventory,
  StaffModule.purchases: AppRoutes.purchases,
  StaffModule.reportsSales: AppRoutes.reports,
  StaffModule.reportsPurchases: AppRoutes.reports,
  StaffModule.reportsCashFlow: AppRoutes.reports,
  StaffModule.reportsKardex: AppRoutes.reports,
  StaffModule.reportsProfit: AppRoutes.reports,
};

class StaffRouteGate extends StatefulWidget {
  const StaffRouteGate({
    super.key,
    required this.routeName,
    this.enableForIntegration = false,
  });

  final String? routeName;
  final bool enableForIntegration;

  @override
  State<StaffRouteGate> createState() => _StaffRouteGateState();
}

class _StaffRouteGateState extends State<StaffRouteGate>
    with WidgetsBindingObserver {
  StreamSubscription<AuthState>? _authChanges;
  AccountAccess? _account;
  BusinessBranding? _branding;
  String? _error;
  int _request = 0;
  bool _loading = false;

  Set<StaffModule> get _routeModules => {
    for (final entry in _staffModuleRoutes.entries)
      if (entry.value == widget.routeName) entry.key,
  };

  @override
  void initState() {
    super.initState();
    if (!widget.enableForIntegration) return;
    WidgetsBinding.instance.addObserver(this);
    _authChanges = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      unawaited(_verify());
    });
    unawaited(_verify());
  }

  Future<void> _verify() async {
    if (!mounted) return;
    final request = ++_request;
    setState(() {
      _account = null;
      _branding = null;
      _error = null;
      _loading = true;
    });
    try {
      if (!AccountStorage.instance.isActive) {
        throw StateError(
          'El almacenamiento de la cuenta no está activo. Reinicia la aplicación.',
        );
      }
      final client = Supabase.instance.client;
      final guard = SyncSessionGuard(client, PreferencesService());
      final session = guard.capture();
      final account =
          await AuthAccessRepository(
            client: client,
            enableStaffForIntegration: true,
          ).resolveCurrentAccount();
      guard.require(session);
      if (account.kind != AccountKind.staff ||
          account.billarId != session.billarId) {
        throw StateError(
          'La cuenta de personal no tiene acceso activo a este billar.',
        );
      }
      final modules = _routeModules;
      if (modules.isNotEmpty &&
          !account.mustChangePassword &&
          !modules.any(account.hasModule)) {
        throw StateError(
          'No tienes permiso para usar ${widget.routeName == AppRoutes.reports ? 'informes' : modules.single.label.toLowerCase()}.',
        );
      }
      final portal =
          widget.routeName == AppRoutes.staffPortal ||
          widget.routeName == AppRoutes.changeTemporaryPassword;
      final branding =
          portal && !account.mustChangePassword
              ? await ConfigRemoteRepository().fetchStaffBranding()
              : null;
      guard.require(session);
      if (mounted && request == _request) {
        setState(() {
          _account = account;
          _branding = branding;
        });
      }
    } on StateError catch (error, stack) {
      _deny(request, error, stack);
    } on Exception catch (error, stack) {
      _deny(request, error, stack);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _deny(int request, Object error, StackTrace stack) {
    log('Acceso de personal rechazado', error: error, stackTrace: stack);
    if (mounted && request == _request) {
      setState(() => _error = error.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_verify());
  }

  @override
  void dispose() {
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_authChanges?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enableForIntegration) {
      return _blocked('El acceso de personal aún no está habilitado.');
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) return _blocked(_error!, retry: true);
    final account = _account;
    if (account == null) return _blocked('No se pudo verificar el acceso.');
    if (account.mustChangePassword) {
      return const ChangeTemporaryPasswordPage(enableStaffForIntegration: true);
    }
    if (widget.routeName == AppRoutes.billiardTables) {
      return StaffTableServicePage(
        tableType: 'Billar',
        allowedModules: account.allowedModules,
        enableForIntegration: true,
      );
    }
    if (widget.routeName == AppRoutes.dineIn) {
      return StaffTableServicePage(
        tableType: 'Comanda',
        allowedModules: account.allowedModules,
        enableForIntegration: true,
      );
    }
    if (widget.routeName == AppRoutes.quickSale) {
      return const StaffQuickSalePage(enableForIntegration: true);
    }
    if (widget.routeName == AppRoutes.inventory) {
      return const StaffInventoryPage(enableForIntegration: true);
    }
    if (widget.routeName == AppRoutes.purchases) {
      return const StaffPurchasesPage(enableForIntegration: true);
    }
    if (widget.routeName == AppRoutes.reports) {
      return StaffReportsPage(
        enableForIntegration: true,
        allowedReports:
            account.allowedModules
                .where((module) => module.parent == StaffModule.reports)
                .toSet(),
      );
    }
    if (widget.routeName == AppRoutes.staffPortal ||
        widget.routeName == AppRoutes.changeTemporaryPassword) {
      return _portal(account);
    }
    return _blocked('Esta ruta aún no está habilitada para personal.');
  }

  Widget _blocked(String message, {bool retry = false}) => Scaffold(
    appBar: AppBar(title: const Text('ACCESO DE PERSONAL')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            if (retry)
              TextButton(onPressed: _verify, child: const Text('REINTENTAR')),
            TextButton(
              onPressed: () => signOutManagedAccount(context),
              child: const Text('CERRAR SESIÓN'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _portal(AccountAccess account) {
    final branding = _branding;
    if (branding == null) {
      return _blocked(
        'No se pudo cargar la identidad del negocio.',
        retry: true,
      );
    }
    return StaffHomePage(
      branding: branding,
      username: account.username,
      allowedRoutes: {
        for (final entry in _staffModuleRoutes.entries)
          if (account.hasModule(entry.key)) entry.value,
      },
      onRefresh: _verify,
      onSignOut: () => signOutManagedAccount(context),
    );
  }
}
