import 'dart:async';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../auth/data/staff_module_access_guard.dart';
import '../../../auth/domain/staff_access.dart';
import '../../../sales/domain/entities/sale_item_entity.dart';
import '../../data/staff_quick_sale_checkout.dart';
import '../../data/staff_quick_sale_outbox.dart';
import '../../data/staff_sale_cache.dart';
import '../../data/staff_sale_catalog_repository.dart';
import '../../domain/entities/staff_sale_product.dart';

typedef StaffSaleReceipt =
    ({
      int localId,
      int remoteId,
      double total,
      double paid,
      String paymentMethod,
      List<SaleItemEntity> items,
    });

class StaffQuickSaleController extends ChangeNotifier {
  StaffQuickSaleController({
    required this.client,
    required this.cache,
    required this.captureSession,
  }) {
    _authChanges = client.auth.onAuthStateChange.listen((event) {
      if (_scope != null &&
          (event.event == AuthChangeEvent.signedOut ||
              client.auth.currentUser?.id != _scope!.actorId)) {
        _products = [];
        _cart = {};
        _receipt = null;
        _ready = false;
        _error = 'La sesión cambió. Vuelve a iniciar sesión.';
        _notify();
      }
    });
  }

  final SupabaseClient client;
  final StaffSaleCache cache;
  final SyncSession Function() captureSession;
  late final StreamSubscription<AuthState> _authChanges;
  SyncSession? _scope;
  bool _disposed = false;
  bool _busy = false;
  bool _ready = false;
  bool _pending = false;
  String? _error;
  List<StaffSaleProduct> _products = [];
  Map<int, int> _cart = {};
  StaffSaleReceipt? _receipt;
  int? _confirmedSaleId;
  bool _confirmedDuringOperation = false;

  bool get busy => _busy;
  bool get ready => _ready;
  bool get pending => _pending;
  String? get error => _error;
  List<StaffSaleProduct> get products => List.unmodifiable(_products);
  Map<int, int> get cart => Map.unmodifiable(_cart);
  StaffSaleReceipt? get receipt => _receipt;
  int? get confirmedSaleId => _confirmedSaleId;
  StaffQuickSaleOutbox get _outbox => StaffQuickSaleOutbox.staffCache(cache);

  double get total {
    final products = {for (final product in _products) product.id: product};
    var result = 0.0;
    for (final entry in _cart.entries) {
      final product = products[entry.key];
      if (product == null) {
        throw StateError('El carrito contiene un producto sin catálogo.');
      }
      result += product.price * entry.value;
    }
    return result;
  }

  SyncSession _capture() {
    final session = captureSession();
    final scope = _scope;
    if (scope != null &&
        (scope.actorId != session.actorId ||
            scope.billarId != session.billarId ||
            scope.scopeGeneration != session.scopeGeneration)) {
      throw StateError('La cuenta o el billar de la pantalla cambió.');
    }
    _scope ??= session;
    cache.requireSession(session);
    return session;
  }

  Future<void> _authorize(SyncSession session) => requireStaffModuleAccess(
    client: client,
    session: session,
    requireSession: cache.requireSession,
    module: StaffModule.quickSale,
  );

  Future<void> _readLocal(SyncSession session) async {
    final products = await cache.catalog(session);
    final cart = await cache.cart(session);
    final pending = await _outbox.pending(session);
    cache.requireSession(session);
    if (cart.keys.any((id) => !products.any((product) => product.id == id))) {
      throw StateError(
        'El carrito local requiere revisión; falta su catálogo.',
      );
    }
    _products = products;
    _cart = cart;
    _pending = pending != null;
    _ready = true;
  }

  Future<void> load() => _run(() async {
    _ready = false;
    final session = _capture();
    await _authorize(session);
    final pending = await _outbox.pending(session);
    if (pending == null) {
      final products = await StaffSaleCatalogRepository(
        client,
        cache.requireSession,
      ).load(session);
      await cache.replaceCatalog(session, products);
    }
    await _readLocal(session);
  });

  Future<void> setQuantity(int productId, int quantity) => _run(() async {
    if (!_ready || _pending || quantity < 0) {
      throw StateError('El carrito no se puede modificar en este momento.');
    }
    final session = _capture();
    await _authorize(session);
    final product =
        _products.where((product) => product.id == productId).single;
    if (quantity > (_cart[productId] ?? 0) && !product.isActive) {
      throw StateError('El producto ya no está disponible.');
    }
    final updated = Map<int, int>.of(_cart);
    if (quantity == 0) {
      updated.remove(productId);
    } else {
      updated[productId] = quantity;
    }
    await cache.saveCart(session, updated);
    await _readLocal(session);
  });

  Future<void> checkout({
    required double paid,
    required String paymentMethod,
    required double expectedTotal,
    required Map<int, int> expectedCart,
  }) => _run(() async {
    if (!_ready ||
        _pending ||
        _cart.isEmpty ||
        total != expectedTotal ||
        !mapEquals(_cart, expectedCart)) {
      throw StateError(
        'El carrito cambió; revisa la venta antes de confirmar.',
      );
    }
    _receipt = null;
    _confirmedSaleId = null;
    final session = _capture();
    final items = <StaffQuickSaleItem>[];
    for (final entry in _cart.entries) {
      final product = _products.singleWhere(
        (product) => product.id == entry.key,
      );
      if (!product.isActive) {
        throw StateError('Retira del carrito los productos no disponibles.');
      }
      items.add(
        StaffQuickSaleItem(
          productId: product.id,
          productName: product.name,
          quantity: entry.value.toDouble(),
          price: product.price,
        ),
      );
    }
    final id = await StaffQuickSaleCheckout(client, _outbox).checkout(
      session: session,
      saleDate: DateTime.now().toIso8601String(),
      paymentMethod: paymentMethod,
      total: expectedTotal,
      paid: paid,
      items: items,
    );
    _confirmedSaleId = id;
    _confirmedDuringOperation = true;
    await _readReceipt(session, id);
    await _readLocal(session);
  });

  Future<void> recover() => _run(() async {
    _receipt = null;
    _confirmedSaleId = null;
    final session = _capture();
    final id = await StaffQuickSaleCheckout(client, _outbox).recover(session);
    if (id == null) {
      throw StateError('No hay una venta pendiente para recuperar.');
    }
    _confirmedSaleId = id;
    _confirmedDuringOperation = true;
    await _readReceipt(session, id);
    await _readLocal(session);
  });

  Future<void> refreshReceipt() => _run(() async {
    final session = _capture();
    await _authorize(session);
    final id = _confirmedSaleId;
    if (id == null) throw StateError('No hay un comprobante confirmado.');
    await _readReceipt(session, id);
  });

  Future<void> _readReceipt(SyncSession session, int id) async {
    final sales = await cache.database.query(
      'sales_history',
      where: 'id = ? AND billar_id = ? AND synced = 1',
      whereArgs: [id, session.billarId],
    );
    final details = await cache.database.query(
      'sale_details',
      where: 'sale_id = ?',
      whereArgs: [id],
      orderBy: 'id',
    );
    cache.requireSession(session);
    final sale = sales.single;
    _receipt = (
      localId: id,
      remoteId: int.parse(sale['cloud_id'] as String),
      total: (sale['total'] as num).toDouble(),
      paid: (sale['paid'] as num).toDouble(),
      paymentMethod: sale['payment_method'] as String,
      items:
          details
              .map(
                (detail) => SaleItemEntity(
                  productId: detail['product_id'] as int?,
                  productName: detail['product_name'] as String,
                  quantity: (detail['quantity'] as num).toDouble(),
                  price: (detail['price_at_sale'] as num).toDouble(),
                ),
              )
              .toList(),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _confirmedDuringOperation = false;
    _notify();
    try {
      await action();
    } on StateError catch (error, stack) {
      _fail(error, stack);
    } on Exception catch (error, stack) {
      _fail(error, stack);
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _fail(Object error, StackTrace stack) {
    log(
      'Error en venta de personal',
      name: 'StaffQuickSale',
      error: error,
      stackTrace: stack,
    );
    _ready = false;
    _error =
        !_confirmedDuringOperation
            ? error.toString()
            : 'La venta #$_confirmedSaleId está confirmada, pero no se pudo '
                'actualizar la pantalla: $error';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_authChanges.cancel());
    super.dispose();
  }
}
