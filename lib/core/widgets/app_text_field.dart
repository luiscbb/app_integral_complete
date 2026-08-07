import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData? icon;
  final bool isNumber;
  final bool obscure;
  final Function(String)? onChanged;
  final VoidCallback? onTap;
  final String? hint;
  final Widget? suffixIcon;
  final bool enabled;
  final FocusNode? focusNode;
  final bool selectAllOnTap;
  final int? maxLines;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputType? keyboardType;

  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.icon,
    this.isNumber = false,
    this.obscure = false,
    this.onChanged,
    this.onTap,
    this.hint,
    this.suffixIcon,
    this.enabled = true,
    this.focusNode,
    this.selectAllOnTap = false,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onTap: () {
          if (selectAllOnTap) {
            controller.selection = TextSelection(
              baseOffset: 0,
              extentOffset: controller.text.length,
            );
          }
          onTap?.call();
        },
        onChanged: onChanged,
        obscureText: obscure,
        enabled: enabled,
        maxLines: maxLines,
        textCapitalization: textCapitalization,
        inputFormatters: inputFormatters,
        style: const TextStyle(color: Colors.white),
        keyboardType:
            keyboardType ??
            (isNumber ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon != null ? Icon(icon) : null,
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }
}
