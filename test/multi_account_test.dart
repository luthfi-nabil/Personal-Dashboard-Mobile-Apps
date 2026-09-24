import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:personal_dashboard/core/config.dart';
import 'package:personal_dashboard/core/db.dart';
import 'package:personal_dashboard/core/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> _auth(String userId, String username,
        {String? fullName}) =>
    {
      'token': 'token-$username',
      'expires_in': 3600,
      'username': username,
      'user_id': userId,
      'full_name': fullName,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('multiple accounts', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ConfigService.instance.load();
    });

    test('signing in another account keeps the first one switchable',
        () async {
      final config = ConfigService.instance;
      await config.signIn(_auth('id-a', 'alice', fullName: 'Alice Doe'),
          username: 'alice', password: 'pw-a');
      await config.setFeature('health', false);
      await config.signIn(_auth('id-b', 'bob'),
          username: 'bob', password: 'pw-b');

      expect(config.current.userId, 'id-b');
      expect(config.current.displayName, 'bob');
      // Feature flags belong to the account, not the device.
      expect(config.current.features, isEmpty);
      expect(config.accounts.map((a) => a.username), ['alice', 'bob']);

      await config.switchAccount('id-a');
      expect(config.current.userId, 'id-a');
      expect(config.current.authToken, 'token-alice');
      expect(config.current.displayName, 'Alice Doe');
      expect(config.current.features['health'], isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pd-saved-password-v1:id-a'), 'pw-a');
      expect(prefs.getString('pd-saved-password-v1:id-b'), 'pw-b');
    });

    test('logging out opens the next signed-in account', () async {
      final config = ConfigService.instance;
      await config.signIn(_auth('id-a', 'alice'),
          username: 'alice', password: 'pw-a');
      await config.signIn(_auth('id-b', 'bob'),
          username: 'bob', password: 'pw-b');

      await config.logout();
      expect(config.current.isLoggedIn, isTrue);
      expect(config.current.userId, 'id-a');
      expect(config.accounts.map((a) => a.userId), ['id-a']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pd-saved-password-v1:id-b'), isNull);

      await config.logout();
      expect(config.current.isLoggedIn, isFalse);
      expect(config.accounts, isEmpty);
    });

    test('accounts survive a restart', () async {
      final config = ConfigService.instance;
      await config.signIn(_auth('id-a', 'alice'),
          username: 'alice', password: 'pw-a');
      await config.signIn(_auth('id-b', 'bob'),
          username: 'bob', password: 'pw-b');

      await config.load();
      expect(config.current.userId, 'id-b');
      expect(config.accounts.map((a) => a.userId), ['id-a', 'id-b']);
    });

    test('a single-account session from an older build is adopted', () async {
      SharedPreferences.setMockInitialValues({
        'pd-config-v1': const AppConfig(
          username: 'alice',
          userId: 'id-a',
          authToken: 'old-token',
        ).toJson(),
        'pd-saved-password-v1': 'pw-a',
      });
      final config = ConfigService.instance;
      await config.load();

      expect(config.accounts.single.userId, 'id-a');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pd-saved-password-v1:id-a'), 'pw-a');
      expect(prefs.getString('pd-saved-password-v1'), isNull);
    });
  });

  test('group categories are cached per account; display names are shared',
      () async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    final tempDir =
        await Directory.systemTemp.createTemp('personal-dashboard-accounts-');
    await factory.setDatabasesPath(tempDir.path);
    // Start from a fresh file so the test does not depend on others.
    final path = join(tempDir.path, 'personal_dashboard.db');
    if (File(path).existsSync()) File(path).deleteSync();
    await AppDb.instance.init(factory);

    await AppDb.instance.replaceGroupCategories(const [
      GroupCategory(id: 'c1', groupId: 'g1', name: 'Groceries'),
    ], 'id-a');
    await AppDb.instance.replaceGroupCategories(const [
      GroupCategory(id: 'c2', groupId: 'g2', name: 'Fuel'),
    ], 'id-b');
    expect((await AppDb.instance.getGroupCategories('id-a')).single.name,
        'Groceries');
    expect(
        (await AppDb.instance.getGroupCategories('id-b')).single.name, 'Fuel');

    await AppDb.instance
        .putDisplayNames(['alice', 'bob'], {'alice': 'Alice Doe'});
    expect(await AppDb.instance.getDisplayNames(), {'alice': 'Alice Doe'});
    // Alice cleared her name.
    await AppDb.instance.putDisplayNames(['Alice'], const {});
    expect(await AppDb.instance.getDisplayNames(), isEmpty);
  });
}
