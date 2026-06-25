import 'package:flutter/material.dart';

enum _TournamentFormat { single, double, roundRobin, groups, swiss }

class TournamentsPage extends StatefulWidget {
  const TournamentsPage({super.key});

  @override
  State<TournamentsPage> createState() => _TournamentsPageState();
}

class _TournamentsPageState extends State<TournamentsPage> {
  _TournamentFormat _format = _TournamentFormat.single;
  final _nameCtrl = TextEditingController();
  final _playersCtrl = TextEditingController(text: '8');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _playersCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'TORNEOS',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.emoji_events_outlined),
            tooltip: 'Historial',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Historial de torneos próximamente')),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('FORMATO', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 2)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _TournamentFormat.values.map((f) {
                final sel = _format == f;
                return ChoiceChip(
                  label: Text(_formatLabel(f)),
                  selected: sel,
                  selectedColor: primary.withValues(alpha: 0.25),
                  checkmarkColor: primary,
                  side: BorderSide(color: sel ? primary : Colors.white12),
                  labelStyle: TextStyle(
                    color: sel ? primary : Colors.white54,
                    fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                  ),
                  onSelected: (_) => setState(() => _format = f),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Nombre del Torneo',
                prefixIcon: const Icon(Icons.edit),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _playersCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Jugadores',
                prefixIcon: const Icon(Icons.people_outline),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                icon: const Icon(Icons.add_circle_outline, color: Colors.white),
                label: const Text(
                  'CREAR TORNEO',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1),
                ),
                onPressed: _crearTorneo,
              ),
            ),
            const Spacer(),
            _buildEmptyState(),
          ],
        ),
      ),
    );
  }

  String _formatLabel(_TournamentFormat f) {
    return switch (f) {
      _TournamentFormat.single => 'Eliminación Simple',
      _TournamentFormat.double => 'Doble Eliminación',
      _TournamentFormat.roundRobin => 'Round Robin',
      _TournamentFormat.groups => 'Grupos',
      _TournamentFormat.swiss => 'Suizo',
    };
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.emoji_events_outlined, size: 64, color: Colors.white.withValues(alpha: 0.06)),
          const SizedBox(height: 16),
          Text(
            'Sin torneos activos',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 15),
          ),
        ],
      ),
    );
  }

  void _crearTorneo() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingresa un nombre para el torneo')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Torneo "$name" creado (${_formatLabel(_format)})')),
    );
  }
}
