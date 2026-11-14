import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/storage/preferences_service.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../../inventory/presentation/widgets/product_sale_card.dart';
import '../../../players/data/repositories/player_repository.dart';
import '../../../players/domain/entities/player_stats.dart';
import '../../../sales/data/repositories/sales_repository.dart';
import '../../../sales/data/repositories/stock_reservation_service.dart';
import '../../../sales/domain/entities/sale_item_entity.dart';
import '../../../sales/presentation/services/ticket_service.dart';
import '../../data/personal_client_repository.dart';

class SpecialClientPage extends StatefulWidget {
  const SpecialClientPage({super.key});

  @override
  State<SpecialClientPage> createState() => _SpecialClientPageState();
}

class _PersonalCustomerOption {
  final String key;
  final String name;
  final String detail;

  const _PersonalCustomerOption({
    required this.key,
    required this.name,
    required this.detail,
  });
}

class _SpecialClientPageState extends State<SpecialClientPage> {
  final _clientRepository = PersonalClientRepository();
  final _playerRepository = PlayerRepository();
  final _productRepository = ProductRepository();
  final _salesRepository = SalesRepository();
  final _reservations = StockReservationService();
  final _ticket = TicketService();
  final _prefs = PreferencesService();
  final _searchController = TextEditingController();

  List<ProductEntity> _products = [];
  List<PlayerEntity> _players = [];
  List<PersonalClient> _clients = [];
  final Map<String, PersonalCustomerAccount> _openAccounts = {};
  Map<int, double> _reservedStock = {};
  List<SaleItemEntity> _items = [];
  String? _selectedKey;
  String? _selectedName;
  bool _isLoading = true;
  bool _isSaving = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) {
        setState(() => _search = _searchController.text.trim().toLowerCase());
      }
    });
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final products = await _productRepository.getAll();
      final players = await _playerRepository.getAll();
      final clients = await _clientRepository.getClients();
      final accounts = await _clientRepository.getOpenAccounts();
      _openAccounts.clear();
      for (final account in accounts) {
        _openAccounts[account.clientKey] = account;
        await _reservations.setCustomerReservation(
          account.clientKey,
          _itemsFromMap(account.items, products),
        );
      }
      final reserved = await _reservations.getReservedQuantities();
      if (!mounted) return;
      setState(() {
        _products = products;
        _players = players;
        _clients = clients;
        _reservedStock = reserved;
        if (_selectedKey != null) {
          final account = _openAccounts[_selectedKey];
          _items =
              account == null
                  ? []
                  : _itemsFromMap(account.items, products);
          _selectedName =
              _customerOptions
                  .where((option) => option.key == _selectedKey)
                  .firstOrNull
                  ?.name ??
              _selectedName;
        }
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint(
        '[SpecialClientPage] Could not load point of sale: $error\n$stackTrace',
      );
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage(
          'No se pudo cargar el punto de venta: $error',
          isError: true,
        );
      }
    }
  }

  List<_PersonalCustomerOption> get _customerOptions => [
    for (final player in _players)
      if (player.enrollmentIsActive)
        _PersonalCustomerOption(
          key:
              'player:${player.clientId.isEmpty ? player.id : player.clientId}',
          name: player.displayName,
          detail:
              'Jugador inscrito${player.phone.isEmpty ? '' : ' · ${player.phone}'}',
        ),
    for (final client in _clients)
      _PersonalCustomerOption(
        key: 'client:${client.clientId}',
        name: client.name,
        detail: 'Cliente${client.phone.isEmpty ? '' : ' · ${client.phone}'}',
      ),
  ];

  List<ProductEntity> get _visibleProducts =>
      _products.where((product) {
        if (_search.isNotEmpty &&
            !product.name.toLowerCase().contains(_search)) {
          return false;
        }
        if (_prefs.allowNegativeStockSales) return true;
        final id = product.id;
        return id != null && product.stock - (_reservedStock[id] ?? 0) > 0;
      }).toList();

  double get _total =>
      _items.fold<double>(0, (total, item) => total + item.subtotal);

  int _quantityFor(int? productId) {
    if (productId == null) return 0;
    return _items
        .where((item) => item.productId == productId)
        .fold(0, (total, item) => total + item.quantity.toInt());
  }

  List<SaleItemEntity> _itemsFromMap(
    List<Map<String, dynamic>> savedItems,
    List<ProductEntity> products,
  ) {
    return savedItems
        .map((saved) {
          final productCloudId = saved['product_cloud_id']?.toString();
          final productId = (saved['product_id'] as num?)?.toInt();
          final product =
              products.where((candidate) {
                if (productCloudId != null && productCloudId.isNotEmpty) {
                  return candidate.cloudId == productCloudId;
                }
                return candidate.id == productId;
              }).firstOrNull;
          return SaleItemEntity(
            productId: product?.id,
            productCloudId: productCloudId,
            productName:
                saved['product_name']?.toString() ?? product?.name ?? '',
            price: (saved['price'] as num?)?.toDouble() ?? product?.price ?? 0,
            quantity: (saved['quantity'] as num?)?.toDouble() ?? 0,
          );
        })
        .where((item) => item.quantity > 0)
        .toList();
  }

  List<Map<String, dynamic>> _itemsToMap(List<SaleItemEntity> items) => [
    for (final item in items)
      {
        'product_id': item.productId,
        'product_cloud_id': item.productCloudId,
        'product_name': item.productName,
        'price': item.price,
        'quantity': item.quantity,
      },
  ];

  Future<void> _chooseCustomer() async {
    final selected = await showModalBottomSheet<_PersonalCustomerOption>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final options = _customerOptions;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('SELECCIONAR CLIENTE O JUGADOR'),
                subtitle: Text(
                  'Se conservará una cuenta de consumo abierta por persona.',
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final option in options)
                      ListTile(
                        leading: Icon(
                          option.key.startsWith('player:')
                              ? Icons.sports_esports
                              : Icons.person_outline,
                        ),
                        title: Text(option.name),
                        subtitle: Text(option.detail),
                        trailing:
                            _openAccounts.containsKey(option.key)
                                ? const Chip(label: Text('CONSUMO ABIERTO'))
                                : null,
                        onTap: () => Navigator.pop(context, option),
                      ),
                    if (options.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No hay jugadores o clientes activos.'),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.person_add),
                  label: const Text('ADMINISTRAR CLIENTES'),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    if (selected == null) {
      await _manageClients();
      return;
    }
    final account = _openAccounts[selected.key];
    setState(() {
      _selectedKey = selected.key;
      _selectedName = selected.name;
      _items = account == null ? [] : _itemsFromMap(account.items, _products);
    });
  }

  Future<PersonalClient?> _showClientForm({PersonalClient? client}) async {
    final name = TextEditingController(text: client?.name ?? '');
    final phone = TextEditingController(text: client?.phone ?? '');
    final email = TextEditingController(text: client?.email ?? '');
    final notes = TextEditingController(text: client?.notes ?? '');
    var error = '';
    try {
      return await showDialog<PersonalClient>(
        context: context,
        builder:
            (context) => StatefulBuilder(
              builder:
                  (context, setDialogState) => AlertDialog(
                    title: Text(
                      client == null ? 'AGREGAR CLIENTE' : 'EDITAR CLIENTE',
                    ),
                    content: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextField(
                            controller: name,
                            textCapitalization: TextCapitalization.characters,
                            inputFormatters: [
                              TextInputFormatter.withFunction(
                                (_, value) => value.copyWith(text: value.text.toUpperCase()),
                              ),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Nombre *',
                            ),
                          ),
                          TextField(
                            controller: phone,
                            keyboardType: TextInputType.phone,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(10),
                              TextInputFormatter.withFunction((_, value) {
                                if (value.text.isEmpty) return value;
                                final text = value.text;
                                if (text.length <= 3) {
                                  return value.copyWith(text: text);
                                } else if (text.length <= 6) {
                                  return value.copyWith(
                                    text: '${text.substring(0, 3)}-${text.substring(3)}',
                                    selection: TextSelection.fromPosition(
                                      TextPosition(offset: value.text.length + 1),
                                    ),
                                  );
                                } else {
                                  return value.copyWith(
                                    text: '${text.substring(0, 3)}-${text.substring(3, 6)}-${text.substring(6)}',
                                    selection: TextSelection.fromPosition(
                                      TextPosition(offset: value.text.length + 2),
                                    ),
                                  );
                                }
                              }),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Teléfono (10 dígitos)',
                              hintText: 'XXX-XXX-XXXX',
                            ),
                          ),
                          TextField(
                            controller: email,
                            keyboardType: TextInputType.emailAddress,
                            inputFormatters: [
                              TextInputFormatter.withFunction(
                                (_, value) => value.copyWith(text: value.text.toLowerCase()),
                              ),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Correo',
                            ),
                          ),
                          TextField(
                            controller: notes,
                            maxLines: 2,
                            decoration: const InputDecoration(
                              labelText: 'Notas',
                            ),
                          ),
                          if (error.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                error,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('CANCELAR'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (name.text.trim().isEmpty) {
                            setDialogState(
                              () => error = 'Escribe el nombre del cliente.',
                            );
                            return;
                          }
                          // Remover caracteres de la máscara del teléfono
                          final phoneCleaned = phone.text.replaceAll(RegExp(r'[^\d]'), '');
                          Navigator.pop(
                            context,
                            PersonalClient(
                              id: client?.id,
                              clientId: client?.clientId ?? '',
                              name: name.text.trim().toUpperCase(),
                              phone: phoneCleaned,
                              email: email.text.trim().toLowerCase(),
                              notes: notes.text.trim(),
                            ),
                          );
                        },
                        child: const Text('GUARDAR'),
                      ),
                    ],
                  ),
            ),
      );
    } finally {
      name.dispose();
      phone.dispose();
      email.dispose();
      notes.dispose();
    }
  }

  Future<void> _manageClients() async {
    var clients = await _clientRepository.getClients(includeInactive: true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('CLIENTES FRECUENTES'),
                  content: SizedBox(
                    width: 460,
                    height: 420,
                    child:
                        clients.isEmpty
                            ? const Center(
                              child: Text('Aún no hay clientes guardados.'),
                            )
                            : ListView.builder(
                              itemCount: clients.length,
                              itemBuilder: (context, index) {
                                final client = clients[index];
                                return ListTile(
                                  title: Text(client.name),
                                  subtitle: Text(
                                    '${client.isActive ? 'Activo' : 'Archivado'}'
                                    '${client.phone.isEmpty ? '' : ' · ${client.phone}'}',
                                  ),
                                  leading: const Icon(Icons.person_outline),
                                  trailing: PopupMenuButton<String>(
                                    onSelected: (action) async {
                                      try {
                                        if (action == 'edit') {
                                          final edited = await _showClientForm(
                                            client: client,
                                          );
                                          if (edited != null) {
                                            await _clientRepository.saveClient(
                                              edited,
                                            );
                                          }
                                        } else if (action == 'archive' &&
                                            client.isActive) {
                                          await _clientRepository.archiveClient(
                                            client.clientId,
                                          );
                                        } else if (action == 'restore') {
                                          await _clientRepository.saveClient(
                                            client,
                                          );
                                        }
                                        clients = await _clientRepository
                                            .getClients(includeInactive: true);
                                        if (mounted) {
                                          await _load();
                                          setDialogState(() {});
                                        }
                                      } catch (error, stackTrace) {
                                        debugPrint(
                                          '[SpecialClientPage] Client update failed: '
                                          '$error\n$stackTrace',
                                        );
                                        if (mounted) {
                                          _showMessage(
                                            error.toString(),
                                            isError: true,
                                          );
                                        }
                                      }
                                    },
                                    itemBuilder:
                                        (_) => [
                                          const PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Editar'),
                                          ),
                                          PopupMenuItem(
                                            value:
                                                client.isActive
                                                    ? 'archive'
                                                    : 'restore',
                                            child: Text(
                                              client.isActive
                                                  ? 'Archivar'
                                                  : 'Reactivar',
                                            ),
                                          ),
                                        ],
                                  ),
                                );
                              },
                            ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CERRAR'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final client = await _showClientForm();
                        if (client == null) return;
                        try {
                          await _clientRepository.saveClient(client);
                          clients = await _clientRepository.getClients(
                            includeInactive: true,
                          );
                          if (mounted) {
                            await _load();
                            setDialogState(() {});
                          }
                        } catch (error, stackTrace) {
                          debugPrint(
                            '[SpecialClientPage] Could not save client: $error\n$stackTrace',
                          );
                          if (mounted) {
                            _showMessage(
                              'No se pudo guardar el cliente: $error',
                              isError: true,
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('AGREGAR'),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _addProduct(ProductEntity product) async {
    if (_selectedKey == null || product.id == null) {
      _showMessage(
        'Selecciona un cliente antes de agregar productos.',
        isError: true,
      );
      return;
    }
    final reserved = _reservedStock[product.id!] ?? 0;
    if (!_prefs.allowNegativeStockSales && product.stock - reserved <= 0) {
      _showMessage(
        'Existencias insuficientes: ${product.name}.',
        isError: true,
      );
      return;
    }
    final index = _items.indexWhere((item) => item.productId == product.id);
    setState(() {
      if (index >= 0) {
        _items[index].quantity += 1;
      } else {
        _items.add(
          SaleItemEntity(
            productId: product.id,
            productCloudId: product.cloudId,
            productName: product.name,
            price: product.price,
          ),
        );
      }
    });
    await _saveAccount();
  }

  Future<void> _changeQuantity(int index, int delta) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (delta > 0 &&
        !_prefs.allowNegativeStockSales &&
        item.productId != null) {
      final product =
          _products.where((entry) => entry.id == item.productId).firstOrNull;
      final reserved = _reservedStock[item.productId!] ?? 0;
      if (product == null || product.stock - reserved <= 0) {
        _showMessage(
          'Existencias insuficientes: ${item.productName}.',
          isError: true,
        );
        return;
      }
    }
    setState(() {
      item.quantity += delta;
      if (item.quantity <= 0) _items.removeAt(index);
    });
    await _saveAccount();
  }

  Future<void> _saveAccount() async {
    final key = _selectedKey;
    final name = _selectedName;
    if (key == null || name == null) return;
    setState(() => _isSaving = true);
    try {
      await _clientRepository.saveAccount(
        clientKey: key,
        clientName: name,
        items: _itemsToMap(_items),
      );
      if (_items.isEmpty) {
        _openAccounts.remove(key);
      } else {
        _openAccounts[key] = PersonalCustomerAccount(
          clientKey: key,
          clientName: name,
          items: _itemsToMap(_items),
        );
      }
      await _reservations.setCustomerReservation(key, _items);
      final reserved = await _reservations.getReservedQuantities();
      if (mounted) {
        setState(() {
          _reservedStock = reserved;
          _isSaving = false;
        });
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[SpecialClientPage] Could not save open account: $error\n$stackTrace',
      );
      if (mounted) {
        setState(() => _isSaving = false);
        _showMessage('No se pudo guardar el consumo: $error', isError: true);
      }
    }
  }

  Future<void> _showConsumption() async {
    if (_items.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setSheetState) => SafeArea(
                  child: SizedBox(
                    height: MediaQuery.of(context).size.height * 0.65,
                    child: Column(
                      children: [
                        ListTile(
                          title: Text('CONSUMO · ${_selectedName ?? ''}'),
                          subtitle: Text(
                            '${_items.length} productos · \$${_total.toStringAsFixed(2)}',
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _items.length,
                            itemBuilder: (context, index) {
                              final item = _items[index];
                              return ListTile(
                                title: Text(item.productName),
                                subtitle: Text(
                                  '\$${item.price.toStringAsFixed(2)} c/u',
                                ),
                                trailing: SizedBox(
                                  width: 150,
                                  child: Row(
                                    children: [
                                      IconButton(
                                        onPressed: () async {
                                          await _changeQuantity(index, -1);
                                          if (context.mounted) {
                                            setSheetState(() {});
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.remove_circle_outline,
                                        ),
                                      ),
                                      Text(item.quantity.toInt().toString()),
                                      IconButton(
                                        onPressed: () async {
                                          await _changeQuantity(index, 1);
                                          if (context.mounted) {
                                            setSheetState(() {});
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.add_circle_outline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ),
    );
  }

  Future<(double, String)?> _paymentDialog(double total) async {
    var method = 'Efectivo';
    var paid = total;
    final controller = TextEditingController(text: total.toStringAsFixed(2));
    try {
      return await showDialog<(double, String)>(
        context: context,
        builder:
            (context) => StatefulBuilder(
              builder:
                  (context, setDialogState) => AlertDialog(
                    title: const Text('CERRAR CUENTA'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Total: \$${total.toStringAsFixed(2)}'),
                        const SizedBox(height: 12),
                        DropdownButton<String>(
                          value: method,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                              value: 'Efectivo',
                              child: Text('Efectivo'),
                            ),
                            DropdownMenuItem(
                              value: 'Tarjeta',
                              child: Text('Tarjeta'),
                            ),
                            DropdownMenuItem(
                              value: 'Transferencia',
                              child: Text('Transferencia'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setDialogState(() {
                              method = value;
                              paid = total;
                              controller.text = total.toStringAsFixed(2);
                            });
                          },
                        ),
                        if (method == 'Efectivo')
                          TextField(
                            controller: controller,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Recibido',
                            ),
                            onChanged:
                                (value) => setDialogState(
                                  () => paid = double.tryParse(value) ?? 0,
                                ),
                          ),
                        if (paid < total)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'El monto recibido no cubre el total.',
                              style: TextStyle(color: Colors.redAccent),
                            ),
                          ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('CANCELAR'),
                      ),
                      ElevatedButton(
                        onPressed:
                            paid < total
                                ? null
                                : () => Navigator.pop(context, (paid, method)),
                        child: const Text('COBRAR'),
                      ),
                    ],
                  ),
            ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _checkout() async {
    if (_isSaving || _selectedKey == null || _items.isEmpty) return;
    if (_items.any((item) => item.productId == null)) {
      _showMessage(
        'Hay productos del consumo que no están disponibles en este dispositivo. '
        'Sincroniza el inventario antes de cerrar la cuenta.',
        isError: true,
      );
      return;
    }
    final total = _total;
    final payment = await _paymentDialog(total);
    if (payment == null || !mounted) return;
    setState(() => _isSaving = true);
    final items = List<SaleItemEntity>.from(_items);
    final customerKey = _selectedKey!;
    final customerName = _selectedName ?? '';
    try {
      await _salesRepository.saveSale(
        items: items,
        total: total,
        paid: payment.$1,
        paymentMethod: payment.$2,
        saleType: 'Cuenta personal · $customerName',
        customerKey: customerKey,
      );
      for (final item in items) {
        final product = _products.firstWhere(
          (product) => product.id == item.productId,
        );
        await _productRepository.decreaseStock(product, item.quantity);
      }
      await _clientRepository.saveAccount(
        clientKey: customerKey,
        clientName: customerName,
        items: const [],
      );
      await _reservations.setCustomerReservation(customerKey, const []);
      if (!mounted) return;
      setState(() {
        _items = [];
        _openAccounts.remove(customerKey);
      });
      _ticket.showPreviewSheet(
        context: context,
        items: items,
        total: total,
        paid: payment.$1,
        paymentMethod: payment.$2,
        saleType: 'Cuenta personal · $customerName',
      );
      await _load();
    } catch (error, stackTrace) {
      debugPrint(
        '[SpecialClientPage] Could not close customer account: $error\n$stackTrace',
      );
      if (mounted) {
        _showMessage('No se pudo cerrar la cuenta: $error', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final selected =
        _customerOptions
            .where((option) => option.key == _selectedKey)
            .firstOrNull;
    final products = _visibleProducts;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'CUENTA PERSONAL',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
        ),
        actions: [
          IconButton(
            tooltip: 'Administrar clientes',
            onPressed: _manageClients,
            icon: const Icon(Icons.manage_accounts_outlined),
          ),
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body:
          _isLoading
              ? Center(child: CircularProgressIndicator(color: primary))
              : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _chooseCustomer,
                            icon: Icon(
                              selected?.key.startsWith('player:') == true
                                  ? Icons.sports_esports
                                  : Icons.person_search,
                            ),
                            label: Text(
                              selected?.name ?? 'SELECCIONAR JUGADOR O CLIENTE',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: 'Agregar cliente',
                          onPressed: () async {
                            final client = await _showClientForm();
                            if (client == null) return;
                            try {
                              await _clientRepository.saveClient(client);
                              await _load();
                              if (mounted) _showMessage('Cliente guardado.');
                            } catch (error, stackTrace) {
                              debugPrint(
                                '[SpecialClientPage] Could not save client: $error\n$stackTrace',
                              );
                              if (mounted) {
                                _showMessage(
                                  'No se pudo guardar el cliente: $error',
                                  isError: true,
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.person_add_alt_1),
                        ),
                      ],
                    ),
                  ),
                  if (selected != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _items.isEmpty
                              ? 'Sin consumo pendiente'
                              : 'CUENTA ABIERTA · ${_items.length} productos · '
                                  '\$${_total.toStringAsFixed(2)}',
                          style: TextStyle(
                            color:
                                _items.isEmpty
                                    ? Colors.white54
                                    : Colors.greenAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        hintText: 'Buscar producto...',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                    ),
                  ),
                  Expanded(
                    child:
                        selected == null
                            ? const Center(
                              child: Text(
                                'Selecciona un cliente o jugador para iniciar su consumo.',
                              ),
                            )
                            : products.isEmpty
                            ? const Center(
                              child: Text('No hay productos disponibles.'),
                            )
                            : GridView.builder(
                              padding: const EdgeInsets.all(10),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 190,
                                    mainAxisSpacing: 10,
                                    crossAxisSpacing: 10,
                                    childAspectRatio: 0.9,
                                  ),
                              itemCount: products.length,
                              itemBuilder: (context, index) {
                                final product = products[index];
                                final quantity = _quantityFor(product.id);
                                final reserved =
                                    _reservedStock[product.id] ?? 0;
                                final stockAvailable = product.stock - reserved;
                                final shownStock =
                                    stockAvailable < 0 ? 0.0 : stockAvailable;
                                return GestureDetector(
                                  onTap: () => _addProduct(product),
                                  child: ProductSaleCard(
                                    product: product.copyWith(
                                      stock: shownStock,
                                    ),
                                    quantity: quantity,
                                    onAdd: () => _addProduct(product),
                                    onRemove: () {
                                      final itemIndex = _items.indexWhere(
                                        (item) => item.productId == product.id,
                                      );
                                      if (itemIndex >= 0) {
                                        _changeQuantity(itemIndex, -1);
                                      }
                                    },
                                    allowOutOfStock:
                                        _prefs.allowNegativeStockSales,
                                  ),
                                );
                              },
                            ),
                  ),
                ],
              ),
      bottomNavigationBar:
          selected == null || _items.isEmpty
              ? null
              : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'TOTAL',
                              style: TextStyle(color: Colors.white54),
                            ),
                            Text(
                              '\$${_total.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontWeight: FontWeight.bold,
                                fontSize: 20,
                              ),
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _showConsumption,
                        child: Text('CONSUMO (${_items.length})'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isSaving ? null : _checkout,
                        icon:
                            _isSaving
                                ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.point_of_sale),
                        label: const Text('COBRAR'),
                      ),
                    ],
                  ),
                ),
              ),
    );
  }
}
