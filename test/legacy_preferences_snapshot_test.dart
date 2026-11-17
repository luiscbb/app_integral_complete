import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preserves existing settings before subsequent account changes',
    () async {
      SharedPreferences.setMockInitialValues({
        'billar_id': 'BILLAR_ORIGINAL',
        'business_name': 'Billar original',
        'table_count': 6,
        'is_first_run': false,
        'admin_pin': '1234',
        'unrelated_session_key': 'not part of business settings',
      });
      final prefs = PreferencesService();
      await prefs.init();

      final original = prefs.legacyPreferencesSnapshot!;
      expect(original['billar_id'], 'BILLAR_ORIGINAL');
      expect(original['business_name'], 'Billar original');
      expect(original['table_count'], 6);
      expect(original, isNot(contains('admin_pin')));
      expect(original, isNot(contains('unrelated_session_key')));

      await prefs.setBillarId('OTHER_BILLAR');
      await prefs.setBusinessName('Other business');
      await prefs.init();
      expect(prefs.legacyPreferencesSnapshot, original);
      expect(prefs.billarId, 'OTHER_BILLAR');
    },
  );

  test('does not save an empty snapshot before first setup', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PreferencesService();
    await prefs.init();
    expect(prefs.legacyPreferencesSnapshot, isNull);

    await prefs.setBillarId('NEW_BILLAR');
    await prefs.setIsFirstRun(false);
    await prefs.ensureLegacyPreferencesSnapshot();
    expect(prefs.legacyPreferencesSnapshot!['billar_id'], 'NEW_BILLAR');
  });

  test('preserves session name before clearing it', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PreferencesService();
    await prefs.init();
    await prefs.setBillarId('BILLAR_ORIGINAL');
    await prefs.setUserName('Original');
    await prefs.clearSession();
    expect(prefs.legacyPreferencesSnapshot!['user_name'], 'Original');
    expect(prefs.legacyPreferencesSnapshot!['billar_id'], 'BILLAR_ORIGINAL');
  });

  test('does not replace a corrupt snapshot with current settings', () async {
    SharedPreferences.setMockInitialValues({
      'legacy_settings_snapshot_v1': '[]',
      'billar_id': 'BILLAR_CURRENT',
    });
    final prefs = PreferencesService();
    await prefs.init();
    expect(() => prefs.legacyPreferencesSnapshot, throwsStateError);
  });
}
