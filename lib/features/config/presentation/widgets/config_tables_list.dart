import 'package:flutter/material.dart';

class ConfigTablesList extends StatelessWidget {
  const ConfigTablesList({
    super.key,
    required this.tables,
    required this.primaryColor,
    required this.onEdit,
    required this.onRemove,
  });

  final List<Map<String, dynamic>> tables;
  final Color primaryColor;
  final void Function(int id, String name) onEdit;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    if (tables.isEmpty) {
      return const Text(
        'No hay mesas. Usa el formulario de arriba para crear la primera.',
        style: TextStyle(color: Colors.white24, fontSize: 12),
      );
    }

    final gameTables = <Map<String, dynamic>>[];
    final orderTables = <Map<String, dynamic>>[];
    for (final table in tables) {
      (table['table_type'] == 'Comanda' ? orderTables : gameTables).add(table);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _group('MESAS DE JUEGO', gameTables, 'No hay mesas de juego.'),
        const SizedBox(height: 24),
        _group('MESAS DE COMANDA', orderTables, 'No hay mesas de comanda.'),
      ],
    );
  }

  Widget _group(
    String title,
    List<Map<String, dynamic>> group,
    String emptyMessage,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        if (group.isEmpty)
          Text(
            emptyMessage,
            style: const TextStyle(color: Colors.white24, fontSize: 12),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: group.length,
              separatorBuilder:
                  (_, _) => const Divider(color: Colors.white10, height: 1),
              itemBuilder: (_, index) {
                final table = group[index];
                final id = table['id'] as int;
                final name = table['name'] as String? ?? 'Mesa $id';
                final type = table['table_type'] as String? ?? 'Billar';
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        type == 'Comanda'
                            ? Icons.restaurant_menu
                            : Icons.table_bar,
                        color: primaryColor,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              '#$id · $type',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.edit,
                          color: Colors.white38,
                          size: 20,
                        ),
                        onPressed: () => onEdit(id, name),
                        tooltip: 'Editar nombre',
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.redAccent,
                          size: 20,
                        ),
                        onPressed: () => onRemove(id),
                        tooltip: 'Eliminar mesa',
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
