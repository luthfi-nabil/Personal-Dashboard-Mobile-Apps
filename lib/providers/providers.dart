import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/background_sync.dart';
import '../core/db.dart';
import '../core/models.dart';
import '../core/notifications.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/sync.dart';

// ── App data ────────────────────────────────────────────────────────────────
class AppDataNotifier extends AutoDisposeAsyncNotifier<AppData> {
  @override
  Future<AppData> build() async {
    // Rebuild the cached/remote data view whenever the active account
    // changes. Without this dependency, the provider survives logout/login
    // and can keep showing the previous user's AppData.
    ref.watch(configProvider.select((cfg) => cfg.userId));
    SyncService.instance.onRefresh = refreshRemote;
    SyncService.instance.onLocalDataChanged = refreshCached;
    ref.onDispose(() {
      SyncService.instance.onRefresh = null;
      SyncService.instance.onLocalDataChanged = null;
      _reminderDebounce?.cancel();
    });
    final cached = await Repo.instance.cached();
    _scheduleReminders(cached);
    unawaited(SyncService.instance.syncNow());
    return cached;
  }

  Timer? _reminderDebounce;

  /// Rebuilds the routine reminders from the data that was just loaded.
  ///
  /// Every write path in the app ends in [refreshCached] or [refreshRemote],
  /// so hooking in here means paying a routine, adding one, muting one or
  /// pulling from the server all re-derive the schedule without each call
  /// site having to remember to. Debounced because a single user action can
  /// trigger several of those in a row, and each rebuild is a batch of
  /// platform calls.
  void _scheduleReminders(AppData data) {
    if (!NotificationService.isSupported) return;
    _reminderDebounce?.cancel();
    _reminderDebounce = Timer(const Duration(seconds: 1), () {
      unawaited(NotificationService.instance.syncRoutineReminders(
        routines: data.routineTransactions,
        config: ConfigService.instance.current,
      ));
    });
  }

  /// Post-write refresh: show what was just saved, then push it if that has
  /// any chance of working.
  ///
  /// When the write itself just proved the API unreachable, syncing now would
  /// only replay the same failure across every queue and the follow-up fetch,
  /// leaving the Save button spinning for a minute or more. The record is
  /// already queued locally, so the periodic sync picks it up instead.
  ///
  /// [force] skips that shortcut for syncs the user asked for by hand, which
  /// always deserve a real attempt.
  Future<void> refresh({bool force = false}) async {
    await refreshCached();
    if (!force && !SyncService.instance.canReachApi) return;
    await SyncService.instance.syncNow();
  }

  Future<void> refreshCached() async {
    try {
      final data = await Repo.instance.cached();
      state = AsyncValue.data(data);
      _scheduleReminders(data);
    } catch (_) {
      // Keep the last visible data instead of replacing the screen with an
      // error state after a local write. Explicit full refresh still reports
      // sync/API failures through SyncService.
      if (!state.hasValue) {
        rethrow;
      }
    }
  }

  Future<void> refreshRemote() async {
    final remote = await Repo.instance.refreshRemote();
    if (remote != null) {
      state = AsyncValue.data(remote);
      _scheduleReminders(remote);
    }
  }

  /// Backs the manual Refresh button: push anything queued, then make sure the
  /// server was actually re-read.
  ///
  /// [SyncService.syncNow] skips its whole body when a periodic sync is already
  /// in flight, which is exactly the moment a user reaches for the button - so
  /// when it reports that it did nothing, the remote read is done here instead.
  /// That is why tapping Refresh always pulls, rather than sometimes appearing
  /// to do nothing.
  Future<RefreshOutcome> refreshFromServer() async {
    await refreshCached();
    if (!SyncService.instance.isOnline) return RefreshOutcome.offline;
    try {
      if (await SyncService.instance.syncNow()) {
        return SyncService.instance.status == SyncStatus.error
            ? RefreshOutcome.failed
            : RefreshOutcome.refreshed;
      }
      final remote = await Repo.instance.refreshRemote();
      if (remote == null) return RefreshOutcome.offline;
      state = AsyncValue.data(remote);
      return RefreshOutcome.refreshed;
    } catch (_) {
      // The cached data stays on screen; the outcome drives the message.
      return RefreshOutcome.failed;
    }
  }
}

/// What a manual refresh managed to do, so the caller can say so plainly
/// instead of leaving the user guessing whether anything happened.
enum RefreshOutcome { refreshed, offline, failed }

final appDataProvider =
    AsyncNotifierProvider.autoDispose<AppDataNotifier, AppData>(
  AppDataNotifier.new,
);

// ── Config ───────────────────────────────────────────────────────────────────
class ConfigNotifier extends Notifier<AppConfig> {
  @override
  AppConfig build() {
    ConfigService.instance.addListener(_onExternalChange);
    ref.onDispose(
        () => ConfigService.instance.removeListener(_onExternalChange));
    return ConfigService.instance.current;
  }

  /// Keeps this provider in sync when [ConfigService] is updated directly
  /// (e.g. [ConfigService.logout] called from [Repo] after a `401`).
  ///
  /// Logout takes exactly this path rather than [update], so the
  /// reconciliation below is what stops the previous account's reminders from
  /// going on firing after someone signs out.
  void _onExternalChange() {
    final previous = state;
    final next = ConfigService.instance.current;
    state = next;
    _reconcile(previous, next);
  }

  /// Saving always notifies [ConfigService]'s listeners, so the reconciliation
  /// runs via [_onExternalChange] rather than here - doing both would rebuild
  /// the notification schedule twice for every single change.
  Future<void> update(AppConfig cfg) async {
    await ConfigService.instance.save(cfg);
    state = cfg;
  }

  /// Brings the two things that live outside the widget tree - an
  /// OS-registered sync job and a set of pending alarms - in line with the
  /// config. Both persist across launches, so they only ever change when
  /// something tells them to.
  void _reconcile(AppConfig previous, AppConfig next) {
    final signedOut = previous.isLoggedIn && !next.isLoggedIn;
    final accountChanged = previous.userId != next.userId;

    if (previous.backgroundSyncEnabled != next.backgroundSyncEnabled ||
        previous.backgroundSyncMinutes != next.backgroundSyncMinutes ||
        previous.isLoggedIn != next.isLoggedIn) {
      unawaited(BackgroundSyncService.apply(next));
    }

    if (signedOut) {
      // The routines these reminders describe belong to an account this
      // device can no longer read. Drop them rather than leaving stale
      // notifications to surface someone else's bills.
      unawaited(NotificationService.instance.cancelAllReminders());
      return;
    }

    if (accountChanged ||
        previous.remindersEnabled != next.remindersEnabled ||
        previous.reminderHour != next.reminderHour ||
        previous.reminderMinute != next.reminderMinute ||
        previous.reminderLeadDays != next.reminderLeadDays) {
      unawaited(_applyReminders(next));
    }
  }

  Future<void> _applyReminders(AppConfig cfg) async {
    if (!cfg.remindersEnabled) {
      await NotificationService.instance.cancelAllReminders();
      return;
    }
    final data = await Repo.instance.cached();
    await NotificationService.instance.syncRoutineReminders(
      routines: data.routineTransactions,
      config: cfg,
    );
  }
}

final configProvider =
    NotifierProvider<ConfigNotifier, AppConfig>(ConfigNotifier.new);

// ── Routine reminders ────────────────────────────────────────────────────────
/// Routines the user has muted, so the routine screen can show which ones
/// stay quiet. Scoped to the signed-in user and rebuilt on account change;
/// invalidate it after toggling a mute.
final mutedRoutineIdsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
  final userId = ref.watch(configProvider.select((cfg) => cfg.userId));
  return AppDb.instance.getMutedRoutineIds(userId);
});

// ── Sync status ───────────────────────────────────────────────────────────────
final StateProvider<SyncStatus> syncStatusProvider =
    StateProvider<SyncStatus>((ref) {
  SyncService.instance.addListener((s) {
    ref.read(syncStatusProvider.notifier).state = s;
  });
  return SyncService.instance.status;
});

/// Number of records saved locally because the API was unreachable
/// ("local mode") and not yet pushed to the server.
final StateProvider<int> pendingSyncCountProvider = StateProvider<int>((ref) {
  SyncService.instance.addPendingListener((count) {
    ref.read(pendingSyncCountProvider.notifier).state = count;
  });
  return SyncService.instance.pendingCount;
});
