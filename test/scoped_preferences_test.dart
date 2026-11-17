import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'account and business preferences remain distinct and persistent',
    () async {
      SharedPreferences.setMockInitialValues({
        'billar_id': 'LEGACY',
        'business_name': 'Legacy business',
        'admin_pin': 'legacy-pin',
      });
      final legacy = PreferencesService();
      await legacy.init();
      var actor = 'A';
      var business = 'X';
      var generation = 0;
      PreferencesService scope(String owner, String billar) {
        final scopeGeneration = generation;
        return legacy.forScope(
          actorId: owner,
          billarId: billar,
          isCurrentScope:
              () =>
                  actor == owner &&
                  business == billar &&
                  generation == scopeGeneration,
        );
      }

      final ax = scope('A', 'X');
      expect(ax.billarId, 'X');
      expect(ax.businessName, 'MI BILLAR');
      expect(ax.adminPin, isEmpty);
      expect(() => ax.legacyPreferencesSnapshot, throwsStateError);
      expect(
        () => ax.forScope(
          actorId: 'B',
          billarId: 'X',
          isCurrentScope: () => true,
        ),
        throwsStateError,
      );
      await ax.setBusinessName('Account A');
      await ax.setAdminPin('pin-a');
      await ax.setTableCount(4);
      await ax.setHourlyRate(12.5);

      actor = 'B';
      generation++;
      expect(() => ax.businessName, throwsStateError);
      await expectLater(ax.setBusinessName('Wrong account'), throwsStateError);
      final bx = scope('B', 'X');
      expect(bx.businessName, 'MI BILLAR');
      expect(bx.adminPin, isEmpty);
      await bx.setBusinessName('Account B');

      actor = 'A';
      business = 'Y';
      generation++;
      final ay = scope('A', 'Y');
      expect(ay.businessName, 'MI BILLAR');
      await ay.setBusinessName('Other business');
      await expectLater(ay.setBillarId('X'), throwsStateError);

      business = 'X';
      generation++;
      expect(() => ax.businessName, throwsStateError);
      await legacy.init();
      final reopened = scope('A', 'X');
      expect(reopened.businessName, 'Account A');
      expect(reopened.adminPin, 'pin-a');
      expect(reopened.tableCount, 4);
      expect(reopened.hourlyRate, 12.5);
      expect(legacy.businessName, 'Legacy business');
      expect(legacy.adminPin, 'legacy-pin');

      actor = 'B';
      generation++;
      expect(scope('B', 'X').businessName, 'Account B');
    },
  );

  test('rejects empty identities', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PreferencesService();
    await prefs.init();
    expect(
      () => prefs.forScope(
        actorId: '',
        billarId: 'X',
        isCurrentScope: () => true,
      ),
      throwsArgumentError,
    );
    expect(
      () => prefs.forScope(
        actorId: 'A',
        billarId: ' ',
        isCurrentScope: () => true,
      ),
      throwsArgumentError,
    );
  });

  test('rejects invalid legacy values before copying any setting', () async {
    SharedPreferences.setMockInitialValues({
      'billar_id': 'X',
      'business_name': 'Original',
      'table_count': 'invalid',
    });
    final legacy = PreferencesService();
    await legacy.init();
    final scoped = legacy.forScope(
      actorId: 'A',
      billarId: 'X',
      isCurrentScope: () => true,
    );
    await expectLater(
      scoped.importVerifiedLegacySettings(
        source: legacy,
        expectedActorId: 'A',
        expectedBillarId: 'X',
        requireOwner: () {},
      ),
      throwsStateError,
    );
    final raw = await SharedPreferences.getInstance();
    expect(
      raw.getKeys().where((key) => key.startsWith('account_scope_v1.')),
      isEmpty,
    );
  });

  test(
    'an interrupted legacy import can be retried without overwriting',
    () async {
      SharedPreferences.setMockInitialValues({
        'billar_id': 'X',
        'business_name': 'Original',
        'table_count': 6,
        'admin_pin': 'test-pin',
      });
      final legacy = PreferencesService();
      await legacy.init();
      final raw = await SharedPreferences.getInstance();
      var actor = 'A';
      var generation = 0;
      var interrupt = true;

      PreferencesService scope() {
        final scopeGeneration = generation;
        return legacy.forScope(
          actorId: 'A',
          billarId: 'X',
          isCurrentScope: () => actor == 'A' && generation == scopeGeneration,
        );
      }

      void requireOwner() {
        if (interrupt &&
            raw.getKeys().any((key) => key.startsWith('account_scope_v1.'))) {
          actor = 'B';
          generation++;
        }
        if (actor != 'A') throw StateError('La cuenta cambió.');
      }

      final interrupted = scope();
      await expectLater(
        interrupted.importVerifiedLegacySettings(
          source: legacy,
          expectedActorId: 'A',
          expectedBillarId: 'X',
          requireOwner: requireOwner,
        ),
        throwsStateError,
      );
      expect(
        raw.getKeys().where(
          (key) => key.endsWith('legacy_import_completed_v1'),
        ),
        isEmpty,
      );
      actor = 'A';
      generation++;
      interrupt = false;
      final resumed = scope();
      await resumed.importVerifiedLegacySettings(
        source: legacy,
        expectedActorId: 'A',
        expectedBillarId: 'X',
        requireOwner: requireOwner,
      );
      expect(resumed.businessName, 'Original');
      expect(resumed.tableCount, 6);
      expect(resumed.adminPin, 'test-pin');
      await resumed.setBusinessName('Updated');
      await resumed.importVerifiedLegacySettings(
        source: legacy,
        expectedActorId: 'A',
        expectedBillarId: 'X',
        requireOwner: requireOwner,
      );
      expect(resumed.businessName, 'Updated');
    },
  );
}
