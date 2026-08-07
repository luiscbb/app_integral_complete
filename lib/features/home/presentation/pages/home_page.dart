import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/widgets/module_card.dart';
import '../../../../features/home/presentation/widgets/home_header.dart';
import '../../../../features/home/presentation/widgets/home_layout.dart';

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

  static final _modules = [
    _Module('VENTA\nRÁPIDA',    Icons.flash_on_rounded,         Color(0xFFE53935), AppRoutes.quickSale,    'Ventas'),
    _Module('MESAS\nBILLAR',    Icons.table_bar_rounded,        Color(0xFF1E88E5), AppRoutes.billiardTables, 'Ventas'),
    _Module('INVENTARIO',       Icons.inventory_2_rounded,      Color(0xFF43A047), AppRoutes.inventory,    'Admin'),
    _Module('COMPRAS',          Icons.shopping_cart_rounded,    Color(0xFFFB8C00), AppRoutes.purchases,    'Admin'),
    _Module('INFORMES',         Icons.bar_chart_rounded,        Color(0xFF8E24AA), AppRoutes.reports,      'Admin'),
    _Module('JUGADORES',        Icons.sports_esports_rounded,   Color(0xFF00ACC1), AppRoutes.playersHub,   'Juego'),
    _Module('COMENSALES',       Icons.restaurant_rounded,       Color(0xFFE91E63), AppRoutes.dineIn,       'Ventas'),
    _Module('TORNEOS',          Icons.emoji_events_rounded,     Color(0xFFFF5722), AppRoutes.tournaments,  'Juego'),
    _Module('CONFIGURACIÓN',    Icons.settings_suggest_rounded, Color(0xFF78909C), AppRoutes.config,       'Admin'),
  ];

  @override
  void initState() {
    super.initState();
    _subscribeToSettingsChanges();
  }

  @override
  void dispose() {
    _settingsChannel?.unsubscribe();
    _searchCtrl.dispose();
    super.dispose();
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
    final logoUrl = settings['logo_url']?.toString() ?? _prefs.logoUrl;

    debugPrint('[HomePage] Aplicando settings. logoUrl: "$logoUrl"');

    await _prefs.setBusinessName(settings['business_name']?.toString() ?? _prefs.businessName);
    await _prefs.setBillarId(settings['billar_id']?.toString() ?? _prefs.billarId);
    await _prefs.setTableCount(tableCount);
    await _prefs.setHourlyRate((settings['hourly_rate'] as num?)?.toDouble() ?? _prefs.hourlyRate);
    await _prefs.setLogoUrl(logoUrl);

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

  List<_Module> get _filteredModules {
    final query = _searchCtrl.text.trim().toLowerCase();
    return _modules.where((m) {
      final matchesCategory = _selectedCategory == 'Todos' || m.category == _selectedCategory;
      final matchesSearch = query.isEmpty || m.label.replaceAll('\n', ' ').toLowerCase().contains(query);
      return matchesCategory && matchesSearch;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
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
      destinations: _modules.map((m) => NavigationRailDestination(
        icon: Icon(m.icon),
        label: Text(m.label.replaceAll('\n', ' ')),
      )).toList(),
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
              onSearchClear: () => setState(() { _searchCtrl.clear(); _isSearching = false; }),
            ),
            const Divider(color: Colors.white10, thickness: 1, indent: 20, endIndent: 20),
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

class _Module {
  final String label;
  final IconData icon;
  final Color color;
  final String route;
  final String category;
  const _Module(this.label, this.icon, this.color, this.route, this.category);
}
