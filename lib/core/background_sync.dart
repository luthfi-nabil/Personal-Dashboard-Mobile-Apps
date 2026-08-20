import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import 'config.dart';
import 'db.dart';
import 'models.dart';
import 'notifications.dart';
import 'repo.dart';
import 'sync.dart';

/// Periodic sync that keeps running once the app is closed.
///
/// [SyncService] already syncs on a timer, but that timer lives in the UI
/// isolate and dies with the last frame. This registers an Android
/// WorkManager job instead, so the OS wakes the app roughly every
/// [AppConfig.backgroundSyncMinutes] to flush the offline write queue, pull
/// fresh data into the local cache, and rebuild the routine reminders from
/// what it found.
///
/// **What Android actually guarantees.** WorkManager will not run periodic
/// work more often than every 15 minutes, and the interval is a floor rather
/// than a schedule: Doze, battery saver and per-vendor process killers can
/// stretch a 30-minute period into hours on a phone that is asleep in a
/// pocket. Reminders are unaffected by this - they are handed to the alarm
/// manager up front and fire on time regardless of when a sync last ran.
class BackgroundSyncService {
  BackgroundSyncService._();

  static const _uniqueName = 'pd-background-sync';
  static const _taskName = 'pd-background-sync';

  /// WorkManager's own floor for periodic work.
  static const _minFrequency = Duration(minutes: 15);

  static const lastRunKey = 'pd-background-sync-last-run-v1';

  /// Android only - see the class docs on [NotificationService.isSupported]
  /// for why the rest of the platforms are left alone.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Registers the callback the OS invokes on a fresh engine. Must run in
  /// `main()` before any task is registered.
  static Future<void> init() async {
    if (!isSupported) return;
    await Workmanager().initialize(backgroundSyncDispatcher);
  }

  /// Brings the registered job in line with [cfg]: scheduled while background
  /// sync is on and someone is signed in, cancelled otherwise.
  ///
  /// Uses `update` so changing the interval actually takes effect; `keep`
  /// would silently leave an old, shorter period running.
  static Future<void> apply(AppConfig cfg) async {
    if (!isSupported) return;
    if (!cfg.backgroundSyncEnabled || !cfg.isLoggedIn) {
      await cancel();
      return;
    }
    final requested = Duration(minutes: cfg.backgroundSyncMinutes);
    final frequency = requested < _minFrequency ? _minFrequency : requested;
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      _taskName,
      frequency: frequency,
      // Nothing here works without the API, so let the OS pick a moment when
      // there is a connection rather than burning a wakeup on a timeout.
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      initialDelay: frequency,
    );
  }

  static Future<void> cancel() async {
    if (!isSupported) return;
    await Workmanager().cancelByUniqueName(_uniqueName);
  }

  /// When the background worker last completed, for display in Settings.
  static Future<DateTime?> lastRun() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final ms = prefs.getInt(lastRunKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }
}

/// Entry point the OS calls on a background engine.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((taskName, inputData) => runBackgroundSync());
}

/// One background pass: flush, pull, re-derive reminders.
///
/// Always reports success. A periodic task that returns `false` is retried on
/// WorkManager's backoff schedule, which for a sync that failed because the
/// server is down just means burning wakeups - the next period is only
/// minutes away and will try again anyway.
Future<bool> runBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // This isolate may be reused between runs, and SharedPreferences caches
    // its values per isolate, so anything the UI wrote since the last run is
    // invisible until the cache is dropped. Every read below - the foreground
    // flag, the config, the saved token - depends on this.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // The user asked for this to run only while the app is closed. It is also
    // what keeps two isolates off the same SQLite file.
    if (await AppForegroundFlag.isForeground()) return true;

    if (!AppDb.instance.isInitialized) {
      await AppDb.instance.init(databaseFactory);
    }
    await ConfigService.instance.load();
    final cfg = ConfigService.instance.current;
    if (!cfg.isLoggedIn) return true;

    // Push whatever is queued locally. syncNow() leaves the remote read to
    // its `onRefresh` hook, which only the UI isolate sets, so the pull is
    // done explicitly below.
    await SyncService.instance.syncNow();
    await Repo.instance.refreshRemote();

    final data = await Repo.instance.cached();
    await NotificationService.instance.syncRoutineReminders(
      routines: data.routineTransactions,
      config: ConfigService.instance.current,
    );

    await prefs.setInt(
        BackgroundSyncService.lastRunKey, DateTime.now().millisecondsSinceEpoch);
  } catch (error, stack) {
    debugPrint('Background sync failed: $error\n$stack');
  }
  return true;
}

/// Whether the app is currently on screen, shared with the background isolate
/// through SharedPreferences.
///
/// The flag alone is not enough: a process killed while in the foreground
/// never gets to clear it, which would disable background sync forever. So
/// the UI also writes a heartbeat, and a flag older than [_staleAfter] is
/// treated as "not in the foreground" regardless of what it says.
class AppForegroundFlag {
  AppForegroundFlag._();

  static const _key = 'pd-app-foreground-v1';
  static const _beatKey = 'pd-app-foreground-beat-v1';
  static const _staleAfter = Duration(minutes: 5);

  static Future<void> set(bool inForeground) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, inForeground);
    await prefs.setInt(_beatKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// Refreshes the timestamp without changing the flag. Called on a timer
  /// while the app is on screen.
  static Future<void> beat() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_key) != true) return;
    await prefs.setInt(_beatKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<bool> isForeground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.getBool(_key) != true) return false;
    final beat = prefs.getInt(_beatKey);
    if (beat == null) return false;
    final age = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(beat));
    return age < _staleAfter;
  }
}
