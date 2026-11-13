import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/preferences_service.dart';

class ProductRealtimeService {
  ProductRealtimeService._();

  static final ProductRealtimeService instance = ProductRealtimeService._();

  final _changes = StreamController<void>.broadcast();
  RealtimeChannel? _channel;
  String? _billarId;

  Stream<void> get changes => _changes.stream;

  void start() {
    final billarId = PreferencesService().billarId;
    if (billarId.isEmpty || (_channel != null && _billarId == billarId)) return;

    stop();
    _billarId = billarId;
    _channel = Supabase.instance.client
        .channel('public:products:$billarId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'products',
          callback: (payload) {
            final record = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
            final eventBillarId = record['billar_id']?.toString();
            if (eventBillarId != null && eventBillarId != billarId) return;
            if (eventBillarId == null) {
              debugPrint(
                '[ProductRealtime] Evento ${payload.eventType} sin billar_id; '
                'se actualizará el catálogo local $billarId',
              );
            } else {
              debugPrint(
                '[ProductRealtime] Evento ${payload.eventType} recibido billar_id=$billarId',
              );
            }
            _changes.add(null);
          },
        )
        .subscribe((status, [error]) {
          debugPrint('[ProductRealtime] status=$status error=$error');
        });
  }

  void stop() {
    final channel = _channel;
    _channel = null;
    _billarId = null;
    if (channel != null) unawaited(channel.unsubscribe());
  }
}
