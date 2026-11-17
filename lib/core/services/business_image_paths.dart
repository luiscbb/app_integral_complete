import 'package:supabase_flutter/supabase_flutter.dart';

String businessImagePath(String billarId, String folder, String fileName) {
  for (final part in [billarId, folder, fileName]) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.contains('/') ||
        part.contains(r'\') ||
        part.trim() != part) {
      throw ArgumentError('La ruta de la imagen no es válida.');
    }
  }
  return '$billarId/$folder/$fileName';
}

String? publicStorageObjectPath(
  SupabaseClient client,
  String bucket,
  String value,
) {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
  final base = Uri.parse(client.storage.from(bucket).getPublicUrl(''));
  if (uri.scheme != base.scheme ||
      uri.host != base.host ||
      uri.port != base.port ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  final prefix =
      base.pathSegments.where((segment) => segment.isNotEmpty).toList();
  final segments = uri.pathSegments;
  if (segments.length <= prefix.length) return null;
  for (var i = 0; i < prefix.length; i++) {
    if (segments[i] != prefix[i]) return null;
  }
  final object = segments.skip(prefix.length).toList();
  if (object.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains(r'\'),
  )) {
    return null;
  }
  return object.join('/');
}
