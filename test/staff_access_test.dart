import 'package:app_integral_complete/features/auth/data/auth_access_repository.dart';
import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes and validates a staff username', () {
    expect(normalizeStaffUsername('  CAJERO.01  '), 'cajero.01');
    expect(isValidStaffUsername('  CAJERO.01  '), isTrue);
    expect(isValidStaffUsername('ab'), isFalse);
    expect(isValidStaffUsername('a' * 33), isFalse);
    expect(isValidStaffUsername('cajero@ejemplo.com'), isFalse);
    expect(isValidStaffUsername('cajero con espacio'), isFalse);
    expect(isValidStaffUsername('_cajero'), isFalse);
  });

  test(
    'staff usernames map consistently to distinct valid authentication addresses',
    () {
      final first = staffUsernameToAuthEmail('  CAJERO..01  ');
      expect(first, '63616a65726f2e2e3031@staff.baumar.invalid');
      expect(first, staffUsernameToAuthEmail('cajero..01'));
      expect(first, isNot(staffUsernameToAuthEmail('cajero.01')));
      expect(first, matches(RegExp(r'^[a-zA-Z0-9_-]+@[a-z.]+$')));
      final longest = staffUsernameToAuthEmail('a' * 32).split('@').first;
      expect(longest.length, 64);
      expect(() => staffUsernameToAuthEmail('ab'), throwsArgumentError);
    },
  );

  test('staff account data rejects unknown modules and invalid revisions', () {
    final data = <String, dynamic>{
      'user_id': 'staff-1',
      'billar_id': 'A',
      'username': 'cajero',
      'full_name': 'Ana',
      'job_title': 'Caja',
      'allowed_modules': ['quick_sale'],
      'is_active': true,
      'must_change_password': false,
      'staff_revision': 1,
    };
    expect(StaffAccount.fromMap(data).draft.modules, {StaffModule.quickSale});
    expect(
      () => StaffAccount.fromMap({
        ...data,
        'allowed_modules': ['admin'],
      }),
      throwsFormatException,
    );
    expect(
      () => StaffAccount.fromMap({
        ...data,
        'allowed_modules': ['quick_sale', 'quick_sale'],
      }),
      throwsFormatException,
    );
    expect(
      () => StaffAccount.fromMap({...data, 'staff_revision': -1}),
      throwsFormatException,
    );
    expect(
      () => StaffAccount.fromMap({...data, 'username': 'CAJERO'}),
      throwsFormatException,
    );
  });

  test(
    'service permissions require their module and remain separate actions',
    () {
      expect(
        parseStaffModules([
          'billiard_tables',
          'billiard_tables_open',
          'billiard_tables_consume',
        ]),
        {
          StaffModule.billiardTables,
          StaffModule.billiardTablesOpen,
          StaffModule.billiardTablesConsume,
        },
      );
      expect(
        () => parseStaffModules(['billiard_tables_open']),
        throwsFormatException,
      );
      expect(
        () => parseStaffModules(['billiard_tables']),
        throwsFormatException,
      );
      expect(
        () => parseStaffModules([
          'billiard_tables',
          'billiard_tables_open',
          'billiard_tables_open',
        ]),
        throwsFormatException,
      );
    },
  );

  test('service module access requires an operational child permission', () {
    final incomplete = AccountAccess(
      kind: AccountKind.staff,
      billarId: 'A',
      allowedModules: {StaffModule.billiardTables},
    );
    expect(incomplete.hasModule(StaffModule.billiardTables), isFalse);

    final waiter = AccountAccess(
      kind: AccountKind.staff,
      billarId: 'A',
      allowedModules: {
        StaffModule.billiardTables,
        StaffModule.billiardTablesOpen,
        StaffModule.billiardTablesConsume,
      },
    );
    expect(waiter.hasModule(StaffModule.billiardTables), isTrue);
    expect(waiter.hasModule(StaffModule.billiardTablesCharge), isFalse);
  });

  test(
    'role recommendations keep service permissions within their pilot scope',
    () {
      final waiter = StaffRoleRecommendation.waiter.modules;
      expect(
        waiter,
        containsAll({
          StaffModule.billiardTablesOpen,
          StaffModule.billiardTablesConsume,
          StaffModule.dineInOpen,
          StaffModule.dineInConsume,
        }),
      );
      expect(waiter, isNot(contains(StaffModule.billiardTablesCharge)));
      expect(waiter, isNot(contains(StaffModule.dineInViewAll)));

      final cashier = StaffRoleRecommendation.cashier.modules;
      expect(
        cashier,
        containsAll({
          StaffModule.quickSale,
          StaffModule.billiardTablesCharge,
          StaffModule.billiardTablesViewAll,
          StaffModule.dineInCharge,
          StaffModule.dineInViewAll,
        }),
      );
      expect(cashier, isNot(contains(StaffModule.billiardTablesOpen)));
      expect(cashier, isNot(contains(StaffModule.dineInConsume)));
      expect(StaffRoleRecommendation.supervisor.modules, cashier);
    },
  );
}
