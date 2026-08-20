import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'db.dart';
import 'models.dart';
import 'routine_schedule.dart';
import 'utils.dart';

/// Local notifications for routine transactions that are coming due.
///
/// The whole surface is a no-op off Android: that is the only platform wired
/// up for background work (see [BackgroundSyncService]), and firing reminders
/// the app cannot keep up to date would be worse than firing none.
///
/// Reminders are *derived*, never stored. [syncRoutineReminders] throws away
/// the previous schedule and rebuilds it from the current routines, so a
/// payment, a deletion or a changed reminder time all take effect by simply
/// calling it again. Both the UI isolate and the background worker do exactly
/// that, which is why it has to be cheap and idempotent.
class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  static const _channelId = 'routine_reminders';
  static const _channelName = 'Routine reminders';
  static const _channelDescription =
      'Reminders for routine transactions that are due.';

  /// Notification ids are handed out sequentially from here. Nothing else in
  /// the app schedules notifications, so the band is ours alone; keeping it
  /// well away from 0 leaves room for other kinds later.
  static const _idBase = 8000000;

  /// How many ids the last schedule used, so the next rebuild knows exactly
  /// what to cancel. Persisted because the rebuild often happens in a fresh
  /// isolate that never saw the previous one.
  static const _slotCountKey = 'pd-reminder-slots-v1';

  /// Safety valve. Android caps how many alarms an app may have pending, and
  /// a reminder list this long is a bug rather than a use case.
  static const _maxScheduled = 100;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Serialises rebuilds. Each one reads the previous slot count, cancels that
  /// many notifications and writes a new count; two running at once could
  /// interleave those steps and strand notifications that nothing will ever
  /// cancel. Several call sites can fire at nearly the same moment - a config
  /// change and the data refresh it triggers, for instance - so they queue
  /// here instead.
  Future<void> _queue = Future.value();

  /// Invoked when the user taps a reminder. Set by the app so it can route to
  /// the routine screen; left null in the background isolate, where there is
  /// no UI to route.
  void Function(String? payload)? onSelect;

  /// Android is the only platform this feature targets.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Prepares the timezone database and the notification channel. Safe to
  /// call more than once and from any isolate; only the first call per
  /// isolate does work.
  Future<void> init() async {
    if (_ready || !isSupported) return;

    tzdata.initializeTimeZones();
    try {
      final local = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(local.identifier));
    } catch (_) {
      // An unknown zone name would make every zonedSchedule call throw, so
      // fall back to UTC and keep reminders working, if offset by the
      // device's real offset.
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) =>
          onSelect?.call(response.payload),
    );

    await _android?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.defaultImportance,
    ));

    _ready = true;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Asks for POST_NOTIFICATIONS (Android 13+). Returns whether reminders may
  /// actually be shown. On older versions the permission is implicit and this
  /// resolves to true without prompting.
  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    await init();
    final granted = await _android?.requestNotificationsPermission();
    return granted ?? true;
  }

  /// The payload of a notification that launched the app from cold, or null.
  /// Consumed once so a later call does not re-navigate.
  Future<String?> takeLaunchPayload() async {
    if (!isSupported) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse?.payload;
  }

  /// Rebuilds the entire reminder schedule from [routines].
  ///
  /// Cancels whatever was scheduled before and, when reminders are switched
  /// on, schedules one notification per active, unmuted routine at the time
  /// [reminderFireTime] works out. Muted ids come from the local
  /// `routine_reminders` table.
  ///
  /// Never throws: a reminder that cannot be scheduled must not take down the
  /// sync that asked for it.
  Future<void> syncRoutineReminders({
    required List<RoutineTransaction> routines,
    required AppConfig config,
    DateTime? now,
  }) {
    if (!isSupported) return Future.value();
    return _enqueue(() => _syncRoutineReminders(
          routines: routines,
          config: config,
          now: now,
        ));
  }

  /// Runs [action] after whatever is already queued, whether that finished
  /// cleanly or not.
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _queue.then((_) => action(), onError: (_) => action());
    _queue = next;
    return next;
  }

  Future<void> _syncRoutineReminders({
    required List<RoutineTransaction> routines,
    required AppConfig config,
    DateTime? now,
  }) async {
    try {
      await init();
      await _cancelPrevious();
      if (!config.remindersEnabled) {
        await _saveSlotCount(0);
        return;
      }

      final muted = await AppDb.instance.getMutedRoutineIds(config.userId);
      final at = now ?? DateTime.now();
      final schedule = dueSchedule(routines)
          .where((due) => !muted.contains(due.routine.id))
          .take(_maxScheduled)
          .toList();

      // Claim the whole range up front. If scheduling fails half way through,
      // an over-count only makes the next rebuild cancel a few ids that were
      // never used - harmless - whereas an under-count would strand live
      // notifications that nothing would ever cancel.
      await _saveSlotCount(schedule.length);

      var slot = 0;
      for (final due in schedule) {
        final fireAt = reminderFireTime(
          due,
          now: at,
          leadDays: config.reminderLeadDays,
          hour: config.reminderHour,
          minute: config.reminderMinute,
        );
        await _schedule(
          id: _idBase + slot,
          fireAt: fireAt,
          title: _titleFor(due, at),
          body: _bodyFor(due, at, config.currency),
          payload: 'routine:${due.routine.id}',
        );
        slot++;
      }
    } catch (error, stack) {
      debugPrint('Reminder scheduling failed: $error\n$stack');
    }
  }

  /// Drops every scheduled reminder. Used when the feature is switched off or
  /// the user signs out.
  Future<void> cancelAllReminders() {
    if (!isSupported) return Future.value();
    return _enqueue(() async {
      try {
        await init();
        await _cancelPrevious();
        await _saveSlotCount(0);
      } catch (_) {
        // Nothing worth surfacing: the schedule is rebuilt from scratch anyway.
      }
    });
  }

  Future<void> _schedule({
    required int id,
    required DateTime fireAt,
    required String title,
    required String body,
    required String payload,
  }) async {
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(fireAt, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
      // Inexact on purpose. A bill reminder does not need alarm-clock
      // precision, and SCHEDULE_EXACT_ALARM is a restricted permission that
      // Google only grants apps whose core purpose is alarms.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }

  Future<void> _cancelPrevious() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_slotCountKey) ?? 0;
    for (var slot = 0; slot < count; slot++) {
      await _plugin.cancel(_idBase + slot);
    }
  }

  Future<void> _saveSlotCount(int count) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_slotCountKey, count);
  }

  String _titleFor(RoutineDue due, DateTime now) =>
      due.isOverdue(now) ? 'Overdue: ${due.routine.itemName}' : 'Due: ${due.routine.itemName}';

  String _bodyFor(RoutineDue due, DateTime now, String currency) {
    final amount = fmtRp(due.routine.price, currency);
    final days = due.daysUntil(now);
    final when = switch (days) {
      0 => 'due today',
      1 => 'due tomorrow',
      < 0 => 'overdue by ${-days} ${-days == 1 ? 'day' : 'days'}',
      _ => 'due in $days days',
    };
    return '$amount - $when (${due.routine.categoryName})';
  }
}
