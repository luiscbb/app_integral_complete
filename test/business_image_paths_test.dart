import 'package:app_integral_complete/core/services/business_image_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final client = SupabaseClient('https://example.supabase.co', 'test-key');

  test('constructs paths rooted in the business', () {
    expect(
      businessImagePath('billar-1', 'products', 'image.jpg'),
      'billar-1/products/image.jpg',
    );
    for (final invalid in ['', '.', '..', 'a/b', r'a\b', ' a']) {
      expect(
        () => businessImagePath(invalid, 'products', 'image.jpg'),
        throwsArgumentError,
      );
    }
  });

  test('only extracts paths from the configured bucket and origin', () {
    final url = client.storage
        .from('product_images')
        .getPublicUrl('billar-1/products/foto especial.jpg');
    expect(
      publicStorageObjectPath(client, 'product_images', url),
      'billar-1/products/foto especial.jpg',
    );
    expect(
      publicStorageObjectPath(
        client,
        'product_images',
        url.replaceFirst('example.supabase.co', 'evil.example'),
      ),
      isNull,
    );
    expect(publicStorageObjectPath(client, 'promo_images', url), isNull);
    expect(
      publicStorageObjectPath(client, 'product_images', '$url%2Fother'),
      isNull,
    );
  });
}
