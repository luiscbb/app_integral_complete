import 'dart:convert';

import 'package:app_integral_complete/features/auth/data/staff_role_template_repository.dart';
import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'templates validate responses, requests and session isolation',
    () async {
      var sessionValid = true;
      var changeDuringRequest = false;
      var calls = 0;
      Object? response = [
        {
          'id': 'role-1',
          'billar_id': 'A',
          'name': 'Mesero',
          'modules': <String>[],
          'revision': 0,
        },
      ];
      final requests = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        httpClient: MockClient((request) async {
          calls++;
          expect(request.headers['authorization'], 'Bearer session-token');
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (changeDuringRequest) sessionValid = false;
          return http.Response(
            jsonEncode(response),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final repository = StaffRoleTemplateRepository(
        client: client,
        billarId: 'A',
        token: 'session-token',
        sessionUnchanged: () => sessionValid,
      );
      try {
        final roles = await repository.list();
        expect(roles.single.modules, isEmpty);
        expect(requests.last['requested_billar_id'], 'A');

        response = {
          'id': 'role-1',
          'billar_id': 'A',
          'name': 'Caja',
          'modules': ['quick_sale'],
          'revision': 1,
        };
        final updated = await repository.save(
          existing: roles.single,
          name: ' Caja ',
          modules: {StaffModule.quickSale},
        );
        expect(updated.revision, 1);
        expect(requests.last['template_id'], 'role-1');
        expect(requests.last['expected_revision'], 0);
        expect(requests.last['template_modules'], ['quick_sale']);

        response = [
          {
            'id': 'role-2',
            'billar_id': 'B',
            'name': 'Otro',
            'modules': ['quick_sale'],
            'revision': 0,
          },
        ];
        await expectLater(repository.list(), throwsFormatException);
        response = [
          {
            'id': 'role-2',
            'billar_id': 'A',
            'name': 'Mesero',
            'modules': ['personal_account'],
            'revision': 0,
          },
        ];
        await expectLater(repository.list(), throwsFormatException);
        final beforeInvalid = calls;
        await expectLater(
          repository.save(
            name: 'Mesero',
            modules: {StaffModule.billiardTables},
          ),
          throwsStateError,
        );
        expect(calls, beforeInvalid);
        changeDuringRequest = true;
        response = <Object>[];
        await expectLater(repository.list(), throwsStateError);
        final beforeStale = calls;
        await expectLater(repository.delete(updated), throwsStateError);
        expect(calls, beforeStale);
      } finally {
        await client.dispose();
      }
    },
  );
}
