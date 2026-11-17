import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/services/product_realtime_service.dart';
import '../../../../core/storage/account_storage.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/widgets/module_card.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../../features/home/presentation/widgets/home_header.dart';
import '../../../../features/home/presentation/widgets/home_layout.dart';
import '../widgets/home_modules.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _prefs = PreferencesService();
  int _selectedIndex = 0;
  String _selectedCategory = 'Todos';
  final TextEditingController _searchCtrl = TextEditingController();
  bool _isSearching = false;
  RealtimeChannel? _settingsChannel;
  int _stockConflictCount = 0;
  bool get _hasRetiredScope =>
      AccountStorage.instance.requiresRestart &&
      !AccountStorage.instance.isActive;

  static const _modules = homeModules;

  @override
  void initState() {
    super.initState();
    if (_hasRetiredScope) return;
    _subscribeToSettingsChanges();
    ProductRealtimeService.instance.start();
    ProductRepository.conflictChanges.addListener(_loadStockConflictCount);
    _loadStockConflictCount();
  }

  @override
  void dispose() {
    _settingsChannel?.unsubscribe();
    ProductRealtimeService.instance.stop();
    ProductRepository.conflictChanges.removeListener(_loadStockConflictCount);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStockConflictCount() async {
    try {
      final conflicts = await ProductRepository().getStockConflicts();
      if (mounted) setState(() => _stockConflictCount = conflicts.length);
    } catch (e) {
      debugPrint('[HomePage] Error consultando conflictos de inventario: $e');
    }
  }
  void _subscribeToSettingsChanges() {
    final user = Supabase.instance.client.auth.currentUser;
    debugPrint('[HomePage] subscribeSettings user=${user?.id}');
    if (user == null) return;

    _settingsChannel = Supabase.instance.client
        .channel('public:billar_settings')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'billar_settings',
          callback: (payload) async {
            final newRecord = payload.newRecord;
            debugPrint('[HomePage] Realtime cambio en billar_settings: $newRecord');
            if (newRecord.isEmpty) return;
            // Filtrar manualmente por user_id para evitar restricciones de filtros en Realtime.
            final recordUserId = newRecord['user_id']?.toString();
            if (recordUserId != user.id) {
              debugPrint('[HomePage] Cambio descartado, no pertenece al usuario actual');
              return;
            }
            await _applyRemoteSettings(newRecord);
          },
        )
        .subscribe((status, [error]) {
          debugPrint('[HomePage] Realtime status: $status error: $error');
        });
  }

  Future<void> _applyRemoteSettings(Map<String, dynamic> settings) async {
    final tableCount = (settings['table_count'] as num?)?.toInt() ?? _prefs.tableCount;
    final primaryColor = (settings['primary_color'] as num?)?.toInt();
    final remoteLogoUrl = ConfigRemoteRepository.normalizeLogoUrl(settings['logo_url']?.toString());
    final logoUrl = remoteLogoUrl.isNotEmpty ? remoteLogoUrl : _prefs.logoUrl;

    debugPrint('[HomePage] Aplicando settings. logoUrl: "$logoUrl"');

    await _prefs.setBusinessName(settings['business_name']?.toString() ?? _prefs.businessName);
    await _prefs.setBillarId(settings['billar_id']?.toString() ?? _prefs.billarId);
    await _prefs.setTableCount(tableCount);
    await _prefs.setHourlyRate((settings['hourly_rate'] as num?)?.toDouble() ?? _prefs.hourlyRate);
    await _prefs.setAllowNegativeStockSales(
      settings['allow_negative_stock_sales'] as bool? ?? _prefs.allowNegativeStockSales,
    );
    await _prefs.setLogoUrl(logoUrl);
    await _prefs.setBusinessAddress(
      settings['business_address']?.toString() ?? _prefs.businessAddress,
    );
    await _prefs.setBusinessStreet(
      settings['business_street']?.toString() ?? _prefs.businessStreet,
    );
    await _prefs.setBusinessExtNumber(
      settings['business_ext_number']?.toString() ?? _prefs.businessExtNumber,
    );
    await _prefs.setBusinessIntNumber(
      settings['business_int_number']?.toString() ?? _prefs.businessIntNumber,
    );
    await _prefs.setBusinessColony(
      settings['business_colony']?.toString() ?? _prefs.businessColony,
    );
    await _prefs.setBusinessZipCode(
      settings['business_zip_code']?.toString() ?? _prefs.businessZipCode,
    );
    await _prefs.setBusinessCity(settings['business_city']?.toString() ?? _prefs.businessCity);
    await _prefs.setBusinessState(settings['business_state']?.toString() ?? _prefs.businessState);
    await _prefs.setBusinessPhone(settings['business_phone']?.toString() ?? _prefs.businessPhone);
    await _prefs.setBusinessWhatsapp(
      settings['business_whatsapp']?.toString() ?? _prefs.businessWhatsapp,
    );
    await _prefs.setBusinessSlogan(
      settings['business_slogan']?.toString() ?? _prefs.businessSlogan,
    );
    await _prefs.setBusinessWebsite(
      settings['business_website']?.toString() ?? _prefs.businessWebsite,
    );
    await _prefs.setTicketFarewell(
      settings['ticket_farewell']?.toString() ?? _prefs.ticketFarewell,
    );

    final socials = settings['social_networks'];
    if (socials is Map) {
      await _prefs.setSocialNetworks(
        socials.map((key, value) => MapEntry(key.toString(), value.toString())),
      );
    } else if (socials is String && socials.isNotEmpty) {
      try {
        final decoded = jsonDecode(socials);
        if (decoded is Map) {
          await _prefs.setSocialNetworks(
            decoded.map((key, value) => MapEntry(key.toString(), value.toString())),
          );
        }
      } on FormatException catch (e) {
        debugPrint('[HomePage] social_networks inválido en configuración remota: $e');
      }
    }

    if (primaryColor != null && mounted) {
      final color = Color(0xFF000000 | (primaryColor.toInt() & 0x00FFFFFF));
      await _prefs.setPrimaryColorValue(color.toARGB32());
      if (mounted) {
        context.read<ThemeProvider>().setPrimaryColor(color);
      }
    }

    if (mounted) setState(() {});
  }

  void _navigate(int index) async {
    setState(() => _selectedIndex = index);
    await Navigator.pushNamed(context, _modules[index].route);
    if (mounted && _modules[index].route == AppRoutes.config) setState(() {});
  }

  List<HomeModule> get _filteredModules {
    final query = _searchCtrl.text.trim().toLowerCase();
    return _modules.where((m) {
      final matchesCategory = _selectedCategory == 'Todos' || m.category == _selectedCategory;
      final matchesSearch =
          query.isEmpty || m.label.replaceAll('\n', ' ').toLowerCase().contains(query);
      return matchesCategory && matchesSearch;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasRetiredScope) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 900;

    final categories = ['Todos'] + _modules.map((m) => m.category).toSet().toList();

    return HomeLayout(
      isDesktop: isDesktop,
      extendedRail: size.width > 1200,
      selectedIndex: _selectedIndex,
      onDestinationSelected: _navigate,
      destinations:
          _modules
              .map(
                (m) => NavigationRailDestination(
                  icon: Icon(m.icon),
                  label: Text(m.label.replaceAll('\n', ' ')),
                ),
              )
              .toList(),
      railLeading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            ClipOval(
              child: Image.asset(
                'assets/baumar_8_personal-sf.png',
                width: 48,
                height: 48,
                fit: BoxFit.cover,
              ),
            ),
            if (size.width > 1200) ...[
              const SizedBox(height: 6),
              Text(
                'BAUMAR POS',
                style: TextStyle(color: primary, fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            HomeHeader(
              businessName: _prefs.businessName,
              userName: _prefs.userName,
              logoPath: _prefs.logoPath,
              logoUrl: _prefs.logoUrl,
              primaryColor: primary,
              isDesktop: isDesktop,
              searchController: _searchCtrl,
              isSearching: _isSearching,
              onSearchToggle: () => setState(() => _isSearching = !_isSearching),
              onSearchChanged: (_) => setState(() {}),
              onSearchClear:
                  () => setState(() {
                    _searchCtrl.clear();
                    _isSearching = false;
                  }),
            ),
            const Divider(color: Colors.white10, thickness: 1, indent: 20, endIndent: 20),
            if (_stockConflictCount > 0)
              ListTile(
                leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                title: Text('$_stockConflictCount productos requieren revisión de inventario'),
                trailing: TextButton(
                  onPressed: () => Navigator.pushNamed(context, AppRoutes.inventory),
                  child: const Text('Revisar'),
                ),
              ),
            if (!_isSearching) ...[
              SizedBox(
                height: 40,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: categories.length,
                  itemBuilder: (_, i) {
                    final sel = categories[i] == _selectedCategory;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(categories[i]),
                        selected: sel,
                        onSelected: (_) => setState(() => _selectedCategory = categories[i]),
                        selectedColor: primary.withValues(alpha: 0.2),
                        checkmarkColor: primary,
                        side: BorderSide(color: sel ? primary : Colors.white12),
                        labelStyle: TextStyle(
                          color: sel ? primary : Colors.white54,
                          fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(20),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 210,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1,
                ),
                itemCount: _filteredModules.length,
                itemBuilder: (_, i) {
                  final m = _filteredModules[i];
                  final originalIndex = _modules.indexOf(m);
                  return ModuleCard(
                    label: m.label,
                    icon: m.icon,
                    color: m.color,
                    onTap: () => _navigate(originalIndex),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
