import 'package:flutter/material.dart';

class HomeLayout extends StatelessWidget {
  final bool isDesktop;
  final bool extendedRail;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationRailDestination> destinations;
  final Widget? railLeading;
  final Widget body;

  const HomeLayout({
    super.key,
    required this.isDesktop,
    required this.extendedRail,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.railLeading,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Row(
        children: [
          if (isDesktop)
            NavigationRail(
              selectedIndex: selectedIndex,
              extended: extendedRail,
              leading: railLeading,
              onDestinationSelected: onDestinationSelected,
              destinations: destinations,
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
