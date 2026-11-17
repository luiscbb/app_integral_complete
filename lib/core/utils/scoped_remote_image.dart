import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/private_image_service.dart';

class ScopedRemoteImage extends StatefulWidget {
  const ScopedRemoteImage({
    super.key,
    required this.url,
    required this.error,
    this.placeholder,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.service,
  });

  final String url;
  final Widget error;
  final Widget? placeholder;
  final double? width;
  final double? height;
  final BoxFit fit;
  final PrivateImageService? service;

  @override
  State<ScopedRemoteImage> createState() => _ScopedRemoteImageState();
}

class _ScopedRemoteImageState extends State<ScopedRemoteImage> {
  late final PrivateImageService _service;
  late final StreamSubscription<AuthState> _subscription;
  Future<Uint8List>? _image;
  bool _usesScopedLoader = false;
  Session? _session;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? PrivateImageService.current();
    _subscription = _service.client.auth.onAuthStateChange.listen((event) {
      if (mounted &&
          (event.event == AuthChangeEvent.signedOut ||
              !identical(event.session, _session))) {
        setState(_reload);
      }
    });
    _reload();
  }

  @override
  void didUpdateWidget(ScopedRemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _reload();
  }

  void _reload() {
    _session = _service.client.auth.currentSession;
    final ref = _service.reference(widget.url);
    final legacy = ref != null && _service.isLegacyPublicReference(ref);
    _usesScopedLoader = ref != null && (!legacy || _session != null);
    _image =
        _usesScopedLoader && _session != null
            ? _service.loadRemote(widget.url)
            : null;
    _image?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_usesScopedLoader) {
      return Image.network(
        widget.url,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: (_, error, stack) {
          debugPrint('[ScopedRemoteImage] No se pudo cargar la imagen: $error');
          return widget.error;
        },
      );
    }
    if (_session == null) return widget.error;
    return FutureBuilder<Uint8List>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.placeholder ?? widget.error;
        }
        if (snapshot.hasError) {
          debugPrint(
            '[ScopedRemoteImage] No se pudo cargar la imagen privada: ${snapshot.error}',
          );
          return widget.error;
        }
        if (!snapshot.hasData) return widget.error;
        return Image.memory(
          snapshot.data!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (_, error, stack) {
            debugPrint('[ScopedRemoteImage] Imagen no válida: $error');
            return widget.error;
          },
        );
      },
    );
  }
}
