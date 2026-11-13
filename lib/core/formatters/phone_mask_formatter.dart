import 'package:flutter/services.dart';

class PhoneMaskFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 10) return oldValue;

    final masked = digits.length >= 7
        ? '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}'
        : digits.length >= 4
        ? '${digits.substring(0, 3)}-${digits.substring(3)}'
        : digits;
    return TextEditingValue(
      text: masked,
      selection: TextSelection.collapsed(offset: masked.length),
    );
  }
}
