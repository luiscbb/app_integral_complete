import 'dart:io';
import 'package:flutter/material.dart';

class HomeHeader extends StatelessWidget {
  final String businessName;
  final String userName;
  final String logoPath;
  final Color primaryColor;
  final bool isDesktop;
  final TextEditingController searchController;
  final bool isSearching;
  final VoidCallback onSearchToggle;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchClear;

  const HomeHeader({
    super.key,
    required this.businessName,
    required this.userName,
    required this.logoPath,
    required this.primaryColor,
    required this.isDesktop,
    required this.searchController,
    required this.isSearching,
    required this.onSearchToggle,
    required this.onSearchChanged,
    required this.onSearchClear,
  });

  @override
  Widget build(BuildContext context) {
    if (isDesktop) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'PANEL DE CONTROL — $businessName',
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            if (isSearching)
              SizedBox(
                width: 240,
                child: TextField(
                  controller: searchController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Buscar módulo...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    prefixIcon: const Icon(Icons.search, color: Colors.white38),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white38),
                      onPressed: onSearchClear,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  onChanged: onSearchChanged,
                ),
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Usuario: $userName', style: const TextStyle(color: Colors.white54)),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.search, color: Colors.white54),
                    onPressed: onSearchToggle,
                  ),
                ],
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: primaryColor.withValues(alpha: 0.5), width: 2),
            ),
            child: CircleAvatar(
              radius: 28,
              backgroundColor: const Color(0xFF1A1A1A),
              backgroundImage: logoPath.isNotEmpty ? FileImage(File(logoPath)) : null,
              child: logoPath.isEmpty
                  ? Icon(Icons.sports_bar_outlined, color: primaryColor, size: 26)
                  : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  businessName,
                  style: const TextStyle(
                    color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(Icons.person, size: 12, color: primaryColor),
                    const SizedBox(width: 5),
                    Text(userName, style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                  ],
                ),
              ],
            ),
          ),
          if (isSearching)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white54),
              onPressed: onSearchClear,
            )
          else
            IconButton(
              icon: const Icon(Icons.search, color: Colors.white54),
              onPressed: onSearchToggle,
            ),
        ],
      ),
    );
  }
}
