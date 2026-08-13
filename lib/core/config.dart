import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features.dart';
import 'models.dart';
import 'remote_api.dart';

class ConfigService {
  static final ConfigService instance = ConfigService._();
  ConfigService._();

  static const _key = 'pd-config-v1';
  static const _passKey = 'pd-saved-password-v1';

  /// Feature ids that were toggled locally but not yet accepted by
  /// transaction-api. Survives a restart, so a flag flipped while offline is
  /// pushed on the next successful sync.
  static const _pendingFeaturesKey = 'pd-pending-feature-sync-v1';
  AppConfig _current = const AppConfig();
  AppConfig get current => _current;

  final _listeners = <void Function()>[];
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in _listeners) {
      l();
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) _current = AppConfig.fromJson(raw);
  }

  Future<void> save(AppConfig cfg) async {
    _current = cfg;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, cfg.toJson());
    _notify();
  }

  // ── Feature flags ───────────────────────────────────────────────────────
  /// Switches an optional feature on or off. The local value is written
  /// first, so the switch responds instantly and keeps working with no API
  /// connection; the server copy is updated in the background and retried
  /// later if the push fails.
  Future<void> setFeature(String featureId, bool enabled) async {
    await save(_current.withFeature(featureId, enabled));
    final prefs = await SharedPreferences.getInstance();
    final pending = (prefs.getStringList(_pendingFeaturesKey) ?? const [])
        .toSet()
      ..add(featureId);
    await prefs.setStringList(_pendingFeaturesKey, pending.toList());
    unawaited(pushPendingFeatures());
  }

  /// Best-effort push of every locally-changed flag to transaction-api.
  /// Ids that fail stay queued; nothing here ever throws, because losing the
  /// server round-trip must not stop the toggle from working.
  Future<void> pushPendingFeatures() async {
    if (!_current.isLoggedIn) return;
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingFeaturesKey) ?? const [];
    if (pending.isEmpty) return;

    final api = RemoteApi(_current);
    final remaining = <String>[];
    for (final id in pending) {
      final feature = AppFeatures.byId(id);
      // The flag was removed in a newer build - drop it from the queue.
      if (feature == null) continue;
      try {
        await api.putSetting(
          feature.settingKey,
          _current.isFeatureEnabled(id).toString(),
        );
      } catch (_) {
        remaining.add(id);
      }
    }
    await prefs.setStringList(_pendingFeaturesKey, remaining);
  }

  /// Applies the feature flags carried by a `GET /api/user/settings`
  /// response. Flags still queued for push are skipped, so a change made
  /// offline is never overwritten by the older server value.
  Future<void> applyRemoteSettings(List<Map<String, dynamic>> settings) async {
    final prefs = await SharedPreferences.getInstance();
    final pending =
        (prefs.getStringList(_pendingFeaturesKey) ?? const []).toSet();

    final next = <String, bool>{..._current.features};
    var changed = false;
    for (final row in settings) {
      final id = AppFeatures.idForSettingKey(
          row['app_setting_key']?.toString() ?? '');
      if (id == null || pending.contains(id)) continue;
      final raw = row['app_setting_value']?.toString().toLowerCase().trim();
      final enabled = raw == 'true' || raw == '1';
      if (next[id] != enabled) {
        next[id] = enabled;
        changed = true;
      }
    }
    if (changed) await save(_current.copyWith(features: next));
  }

  Future<void> savePassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_passKey, password);
  }

  Future<String?> _getSavedPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_passKey);
  }

  /// Re-authenticates using stored credentials and saves the new token.
  /// Returns true if a fresh token was obtained, false otherwise.
  Future<bool> tryRefreshToken() async {
    final username = _current.username;
    final password = await _getSavedPassword();
    if (username.isEmpty || password == null || password.isEmpty) return false;
    try {
      final auth =
          await RemoteApi(_current).login(username: username, password: password);
      final expiresIn = (auth['expires_in'] as num?)?.toInt();
      final expiresAt = expiresIn == null || expiresIn <= 0
          ? ''
          : DateTime.now()
              .add(Duration(seconds: expiresIn))
              .toIso8601String();
      await save(_current.copyWith(
        authToken: auth['token'] as String? ?? '',
        tokenExpiresAt: expiresAt,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Clears the login-api session (JWT, user id) while keeping server URLs
  /// and app preferences (theme, currency, etc.) intact.
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_passKey);
    // Drop unpushed flag changes so they cannot land on the next account
    // that signs in on this device.
    await prefs.remove(_pendingFeaturesKey);
    await save(_current.copyWith(
      authToken: '',
      tokenExpiresAt: '',
      userId: '',
    ));
  }
}

/// Bridges [ConfigService]'s listener callbacks to a [ChangeNotifier] so
/// `go_router` can be told to re-run its `redirect` whenever the login
/// session changes (e.g. after login or logout).
class ConfigListenable extends ChangeNotifier {
  ConfigListenable() {
    ConfigService.instance.addListener(notifyListeners);
  }

  @override
  void dispose() {
    ConfigService.instance.removeListener(notifyListeners);
    super.dispose();
  }
}
