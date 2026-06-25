import 'package:flutter/material.dart';

class SyncStatusBanner extends StatelessWidget {
  final Stream<bool> connectionStream;
  final Future<int> Function() pendingCount;

  const SyncStatusBanner({super.key, required this.connectionStream, required this.pendingCount});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: connectionStream,
      initialData: false,
      builder: (context, snapshot) {
        final online = snapshot.data ?? false;
        return Card(
          elevation: 1,
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            child: Row(
              children: [
                Icon(
                  online ? Icons.cloud_done : Icons.cloud_off,
                  color: online ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        online ? 'Conexión disponible' : 'Sin conexión',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      FutureBuilder<int>(
                        future: pendingCount(),
                        builder: (context, pendingSnapshot) {
                          final pending = pendingSnapshot.data ?? 0;
                          return Text(
                            pending > 0
                                ? 'Ventas pendientes por sincronizar: $pending'
                                : 'No hay ventas pendientes',
                            style: Theme.of(context).textTheme.bodyMedium,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
