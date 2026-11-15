import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:localspot/api.dart';
import 'package:localspot/main.dart';
import 'package:localspot/models.dart';
import 'package:localspot/state.dart';
import 'package:localspot/widgets.dart';

void main() {
  Map<String, dynamic> profile({String? role}) => {
    'id': 910001,
    'name': 'Test account',
    'email': 'test@example.test',
    if (role != null) 'role': role,
    'owned_store_ids': [910001],
    'member_store_ids': <int>[],
    'store_grants': <Map<String, dynamic>>[],
  };

  test('profile role values are normalized without a customer fallback', () {
    expect(userFromJson(profile(role: ' OWNER ')).role, AppRole.owner);
    expect(userFromJson(profile(role: 'Customer')).role, AppRole.customer);
    expect(userFromJson(profile(role: 'STAFF')).role, AppRole.staff);
    expect(userFromJson(profile(role: 'Admin')).role, AppRole.admin);
    expect(() => userFromJson(profile()), throwsFormatException);
    expect(
      () => userFromJson(profile(role: 'store-owner')),
      throwsFormatException,
    );
  });

  testWidgets(
    'unverified authenticated profile cannot reach owner navigation',
    (tester) async {
      final app =
          AppState(seedDemoData: false)
            ..apiOnline = true
            ..currentUser = UserAccount(
              id: 910001,
              name: 'Test account',
              email: 'test@example.test',
              password: '',
              role: AppRole.owner,
              ownedStoreIds: [910001],
            )
            ..authProfileStatus = AuthProfileStatus.failed
            ..authProfileError = 'Profile request failed.';

      await tester.pumpWidget(
        AppScope(
          notifier: app,
          child: const MaterialApp(home: LocalSpotShell()),
        ),
      );
      expect(find.text('Could not verify account profile'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('360° tour'), findsNothing);
    },
  );

  testWidgets('loaded owner profile opens owner workspace', (tester) async {
    final app =
        AppState(seedDemoData: false)
          ..apiOnline = true
          ..currentUser = UserAccount(
            id: 910001,
            name: 'Test account',
            email: 'test@example.test',
            password: '',
            role: AppRole.owner,
            ownedStoreIds: [910001],
          )
          ..authProfileStatus = AuthProfileStatus.loaded;

    await tester.pumpWidget(
      AppScope(notifier: app, child: const MaterialApp(home: LocalSpotShell())),
    );
    expect(find.text('Store owner workspace'), findsOneWidget);
  });
}
