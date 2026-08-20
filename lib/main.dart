import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/db.dart';
import 'core/config.dart';
import 'core/background_sync.dart';
import 'core/notifications.dart';
import 'core/sync.dart';
import 'core/seed.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop SQLite support
  DatabaseFactory factory;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    factory = databaseFactoryFfi;
  } else {
    factory = databaseFactory;
  }

  await AppDb.instance.init(factory);
  await ConfigService.instance.load();
  await seedIfEmpty();
  await SyncService.instance.start();

  // Reminders and the out-of-process sync job both outlive this isolate, so
  // they are set up before the first frame: the OS may invoke the worker at
  // any point after registration, including while the app is closed.
  await NotificationService.instance.init();
  await BackgroundSyncService.init();
  await BackgroundSyncService.apply(ConfigService.instance.current);

  runApp(const ProviderScope(child: PersonalDashboardApp()));
}
