import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'config.dart';
import 'db.dart';
import 'repo.dart';

enum SyncStatus { idle, syncing, done, error }

/// Tracks connectivity and periodically asks the app to refresh data from
/// transaction-api / health-api. Writes normally go straight through, but if
/// the API is unreachable (timeout / connection failure) [Repo] queues them
/// locally ("local mode" - see [pendingCount]); this service retries that
/// queue whenever the device reconnects or the periodic sync timer fires.
class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  bool _online = true;
  bool get isOnline => _online;

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  SyncStatus _status = SyncStatus.idle;
  SyncStatus get status => _status;

  /// Number of records saved locally because the API was unreachable
  /// and not yet pushed to the server. `pendingCount > 0` means the app is
  /// in "local mode" for those writes.
  int _pendingCount = 0;
  int get pendingCount => _pendingCount;
  bool get localMode => _pendingCount > 0;

  /// Set by the app (typically `appDataProvider`'s notifier) to refresh
  /// cached data. Safe to call repeatedly; errors are reported via [status].
  Future<void> Function()? onRefresh;

  /// Set by the app to refresh the visible cache after a write is queued
  /// locally while offline.
  Future<void> Function()? onLocalDataChanged;

  final _listeners = <void Function(SyncStatus)>[];
  void addListener(void Function(SyncStatus) l) => _listeners.add(l);
  void removeListener(void Function(SyncStatus) l) => _listeners.remove(l);
  void _emit(SyncStatus s) {
    _status = s;
    for (final l in _listeners) {
      l(s);
    }
  }

  final _pendingListeners = <void Function(int)>[];
  void addPendingListener(void Function(int) l) => _pendingListeners.add(l);
  void removePendingListener(void Function(int) l) =>
      _pendingListeners.remove(l);

  /// Called by [Repo] whenever a record is queued or flushed locally.
  void updatePendingCount(int count) {
    if (_pendingCount == count) return;
    _pendingCount = count;
    for (final l in _pendingListeners) {
      l(count);
    }
  }

  Future<void> start() async {
    final results = await Connectivity().checkConnectivity();
    _online = results.any((r) => r != ConnectivityResult.none);

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final wasOnline = _online;
      _online = results.any((r) => r != ConnectivityResult.none);
      if (!wasOnline && _online) syncNow();
    });

    ConfigService.instance.addListener(_restartTimer);
    _restartTimer();

    await _refreshPendingCount(ConfigService.instance.current.userId);
    if (_pendingCount > 0 && _online) syncNow();
  }

  void _restartTimer() {
    _timer?.cancel();
    final cfg = ConfigService.instance.current;
    _refreshPendingCount(cfg.userId);
    if (!cfg.isLoggedIn || !cfg.autoSync) return;
    _timer = Timer.periodic(Duration(seconds: cfg.syncIntervalSec), (_) {
      if (_online) syncNow();
    });
  }

  Future<void> _refreshPendingCount(String userId) async {
    final pending = await AppDb.instance.getPendingWriteCount(userId);
    if (ConfigService.instance.current.userId == userId) {
      updatePendingCount(pending);
    }
  }

  /// Pushes everything queued locally and then asks the app to re-read the
  /// server via [onRefresh].
  ///
  /// Returns `false` when the whole body was skipped - a sync was already in
  /// flight, or the device is offline / signed out - so a caller that must be
  /// sure the server was actually read (the manual Refresh button) can do the
  /// remote read itself instead of silently doing nothing.
  Future<bool> syncNow() async {
    if (_status == SyncStatus.syncing) return false;
    final cfg = ConfigService.instance.current;
    if (!cfg.isLoggedIn || !_online) return false;

    _emit(SyncStatus.syncing);
    try {
      // Flags toggled while the API was unreachable go up first, so the
      // refresh below reads back what this device already shows.
      await ConfigService.instance.pushPendingFeatures();
      await Repo.instance.syncPendingOptions();
      await Repo.instance.syncPendingTransactions();
      await Repo.instance.syncPendingDetailChecks();
      await Repo.instance.syncPendingDeletes();
      await Repo.instance.syncPendingPlanningWrites();
      await Repo.instance.syncPendingHealthWrites();
      await onRefresh?.call();
      _emit(SyncStatus.done);
      return true;
    } catch (_) {
      _emit(SyncStatus.error);
      return true;
    }
  }

  void dispose() {
    _timer?.cancel();
    _connSub?.cancel();
    ConfigService.instance.removeListener(_restartTimer);
  }
}
