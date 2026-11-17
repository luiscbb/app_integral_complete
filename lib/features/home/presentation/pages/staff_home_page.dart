import 'package:flutter/material.dart';

import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/widgets/module_card.dart';
import '../widgets/home_header.dart';
import '../widgets/home_layout.dart';
import '../widgets/home_modules.dart';

class StaffHomePage extends StatefulWidget {
  const StaffHomePage({
    super.key,
    required this.branding,
    required this.allowedRoutes,
    required this.username,
    required this.onRefresh,
    required this.onSignOut,
  });

  final BusinessBranding branding;
  final Set<String> allowedRoutes;
  final String username;
  final VoidCallback onRefresh;
  final VoidCallback onSignOut;

  @override
  State<StaffHomePage> createState() => _StaffHomePageState();
}

class _StaffHomePageState extends State<StaffHomePage> {
  final _search = TextEditingController();
  bool _isSearching = false;
  int _selectedIndex = 0;
  String _category = 'Todos';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final modules =
        homeModules
            .where((module) => widget.allowedRoutes.contains(module.route))
            .toList();
    final query = _search.text.trim().toLowerCase();
    final filtered =
        modules
            .where(
              (module) =>
                  (_category == 'Todos' || module.category == _category) &&
                  module.label
                      .replaceAll('\n', ' ')
                      .toLowerCase()
                      .contains(query),
            )
            .toList();
    final categories = ['Todos', ...modules.map((m) => m.category).toSet()];
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width > 900;
    final primary = widget.branding.primaryColor;
    final theme = Theme.of(context);
    final color = primary == null ? theme.colorScheme.primary : Color(primary);
    void navigate(HomeModule module) {
      setState(() => _selectedIndex = modules.indexOf(module));
      Navigator.pushNamed(context, module.route);
    }

    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(primary: color),
      ),
      child: HomeLayout(
        isDesktop: desktop && modules.length > 1,
        extendedRail: width > 1200,
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => navigate(modules[index]),
        destinations: [
          for (final module in modules)
            NavigationRailDestination(
              icon: Icon(module.icon),
              label: Text(module.label.replaceAll('\n', ' ')),
            ),
        ],
        body: SafeArea(
          child: Column(
            children: [
              HomeHeader(
                businessName: widget.branding.businessName,
                userName: widget.username,
                logoPath: '',
                logoUrl: widget.branding.logoUrl,
                primaryColor: color,
                isDesktop: desktop,
                searchController: _search,
                isSearching: _isSearching,
                onSearchToggle: () => setState(() => _isSearching = true),
                onSearchChanged: (_) => setState(() {}),
                onSearchClear:
                    () => setState(() {
                      _search.clear();
                      _isSearching = false;
                    }),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Actualizar permisos',
                    onPressed: widget.onRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Cerrar sesión',
                    onPressed: widget.onSignOut,
                    icon: const Icon(Icons.logout),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
              const Divider(color: Colors.white10, indent: 20, endIndent: 20),
              if (_isSearching && !desktop)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: 'Buscar módulo...',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    for (final category in categories)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(category),
                          selected: _category == category,
                          onSelected:
                              (_) => setState(() => _category = category),
                          selectedColor: color.withValues(alpha: 0.2),
                          checkmarkColor: color,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child:
                    filtered.isEmpty
                        ? const Center(
                          child: Text(
                            'No hay módulos disponibles para esta selección.',
                          ),
                        )
                        : GridView.builder(
                          padding: const EdgeInsets.all(20),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 210,
                                mainAxisSpacing: 16,
                                crossAxisSpacing: 16,
                                childAspectRatio: 1,
                              ),
                          itemCount: filtered.length,
                          itemBuilder: (_, index) {
                            final module = filtered[index];
                            return ModuleCard(
                              label: module.label,
                              icon: module.icon,
                              color: module.color,
                              onTap: () => navigate(module),
                            );
                          },
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
