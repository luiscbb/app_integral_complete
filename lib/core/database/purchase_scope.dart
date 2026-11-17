String purchaseBusinessScope([String? alias]) {
  final column = alias == null ? 'billar_id' : '$alias.billar_id';
  return '$column = ?';
}
