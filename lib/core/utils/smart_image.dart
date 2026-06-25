import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class SmartImage extends StatelessWidget {
  final String? imagePath;
  final double? size;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final BoxFit fit;
  final IconData placeholderIcon;

  const SmartImage({
    super.key,
    this.imagePath,
    this.size,
    this.width,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.inventory_2,
  });

  @override
  Widget build(BuildContext context) {
    final double finalWidth = width ?? size ?? double.infinity;
    final double finalHeight = height ?? size ?? double.infinity;

    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(10),
      child: Container(
        width: finalWidth,
        height: finalHeight,
        color: Colors.white.withValues(alpha: 0.05),
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (imagePath == null || imagePath!.isEmpty) {
      return Icon(placeholderIcon, color: Colors.white24, size: (size ?? 40) * 0.6);
    }
    if (imagePath!.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: imagePath!,
        fit: fit,
        memCacheWidth: 300,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red),
          ),
        ),
        errorWidget: (_, _, _) => _error(),
      );
    }
    return Image.file(
      File(imagePath!),
      fit: fit,
      cacheWidth: 200,
      errorBuilder: (_, _, _) => _error(),
    );
  }

  Widget _error() => const Icon(Icons.broken_image, color: Colors.redAccent, size: 24);
}
