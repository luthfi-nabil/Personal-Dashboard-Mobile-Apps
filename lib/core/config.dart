import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features.dart';
import 'models.dart';
import 'remote_api.dart';

/// One account signed in on this device. The active one is mirrored in
/// [ConfigService.current]; the others wait here with their session so the
/// user can switch back without typing the password again.
///
/// Only the session and the per-account feature flags are kept - server URLs
/// and look-and-feel settings belong to the device and are shared.
@immutable
class SavedAccount {
  final String userId;
  final String username;
  final String fullName;
  final String email;
  final String phoneNumber;
  final String telegramUsername;
  final String authToken;
  final String tokenExpiresAt;
  final Map<String, bool> features;

  const SavedAccount({
    required this.userId,
    required this.username,
    this.fullName = '',
    this.email = '',
    this.phoneNumber = '',
    this.telegramUsername = '',
    this.authToken = '',
    this.tokenExpiresAt = '',
    this.features = const {},
  });

  /// The session part of [cfg].
  factory SavedAccount.fromConfig(AppConfig cfg) => SavedAccount(
        userId: cfg.userId,
        username: cfg.username,
        fullName: cfg.fullName,
        email: cfg.email,
        phoneNumber: cfg.phoneNumber,
        telegramUsername: cfg.telegramUsername,
        authToken: cfg.authToken,
        tokenExpiresAt: cfg.tokenExpiresAt,
        features: cfg.features,
      );

  /// [cfg] (device settings) signed in as this account.
  AppConfig applyTo(AppConfig cfg) => cfg.copyWith(
        userId: userId,
        username: username,
        fullName: fullName,
        email: email,
        phoneNumber: phoneNumber,
        telegramUsername: telegramUsername,
        authToken: authToken,
        tokenExpiresAt: tokenExpiresAt,
        features: features,
      );

  String get displayName =>
      fullName.trim().isNotEmpty ? fullName.trim() : username;

  factory SavedAccount.fromJson(Map<String, dynamic> m) => SavedAccount(
        userId: m['userId'] as String? ?? '',
        username: m['username'] as String? ?? '',
        fullName: m['fullName'] as String? ?? '',
        email: m['email'] as String? ?? '',
        phoneNumber: m['phoneNumber'] as String? ?? '',
        telegramUsername: m['telegramUsername'] as String? ?? '',
        authToken: m['authToken'] as String? ?? '',
        tokenExpiresAt: m['tokenExpiresAt'] as String? ?? '',
        features: {
          for (final e in (m['features'] as Map? ?? const {}).entries)
            if (e.value is bool) e.key.toString(): e.value as bool,
        },
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'fullName': fullName,
        'email': email,
        'phoneNumber': phoneNumber,
        'telegramUsername': telegramUsername,
        'authToken': authToken,
        'tokenExpiresAt': tokenExpiresAt,
        'features': features,
      };
}

class ConfigService {
  static final ConfigService instance = ConfigService._();
  ConfigService._();

  static const _key = 'pd-config-v1';

  /// Every account signed in on this device, the active one included.
  static const _accountsKey = 'pd-accounts-v1';

  /// Saved passwords are kept per account (`<prefix>:<userId>`). The bare
  /// key is the single-account layout of older builds, migrated in [load].
  static const _passKey = 'pd-saved-password-v1';

  /// Feature ids that were toggled locally but not yet accepted by
  /// transaction-api, per account (`<prefix>:<userId>`). Survives a restart,
  /// so a flag flipped while offline is pushed on the next successful sync.
  static const _pendingFeaturesKey = 'pd-pending-feature-sync-v1';

  static String _passKeyFor(String userId) => '$_passKey:$userId';
  static String _pendingKeyFor(String userId) =>
      '$_pendingFeaturesKey:$userId';

  AppConfig _current = const AppConfig();
  AppConfig get current => _current;

  List<SavedAccount> _accounts = const [];

  /// Every signed-in account, in the order they were added. The active one
  /// reflects its latest session.
  List<SavedAccount> get accounts => List.unmodifiable(_accounts);

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
    _current = raw == null ? const AppConfig() : AppConfig.fromJson(raw);

    _accounts = const [];
    final rawAccounts = prefs.getString(_accountsKey);
    if (rawAccounts != null) {
      try {
        _accounts = (jsonDecode(rawAccounts) as List)
            .map((e) => SavedAccount.fromJson(Map<String, dynamic>.from(e as Map)))
            .where((a) => a.userId.isNotEmpty)
            .toList();
      } catch (_) {
        _accounts = const [];
      }
    }

    // Builds from before multiple accounts kept one session and one saved
    // password: adopt them as the first account.
    if (_current.isLoggedIn && _current.userId.isNotEmpty) {
      final legacyPassword = prefs.getString(_passKey);
      if (legacyPassword != null) {
        await prefs.setString(_passKeyFor(_current.userId), legacyPassword);
        await prefs.remove(_passKey);
      }
      final legacyPending = prefs.getStringList(_pendingFeaturesKey);
      if (legacyPending != null) {
        await prefs.setStringList(
            _pendingKeyFor(_current.userId), legacyPending);
        await prefs.remove(_pendingFeaturesKey);
      }
      _rememberCurrent();
      await _saveAccounts(prefs);
    }
  }

  Future<void> save(AppConfig cfg) async {
    _current = cfg;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, cfg.toJson());
    // Keep the active account's saved session (refreshed token, flags,
    // profile) in step with the config.
    if (cfg.isLoggedIn && cfg.userId.isNotEmpty) {
      _rememberCurrent();
      await _saveAccounts(prefs);
    }
    _notify();
  }

  /// Puts the active session into [_accounts], replacing its older copy.
  void _rememberCurrent() {
    final account = SavedAccount.fromConfig(_current);
    final index = _accounts.indexWhere((a) => a.userId == account.userId);
    _accounts = [..._accounts];
    if (index == -1) {
      _accounts.add(account);
    } else {
      _accounts[index] = account;
    }
  }

  Future<void> _saveAccounts(SharedPreferences prefs) => prefs.setString(
      _accountsKey, jsonEncode(_accounts.map((a) => a.toJson()).toList()));

  // ── Accounts ────────────────────────────────────────────────────────────
  /// Makes the account a successful `POST /api/auth/login` returned the
  /// active one. The account that was active before stays signed in and can
  /// be switched back to. Each account's local data is kept apart by its
  /// user id, so nothing of the previous account is shown to this one.
  Future<void> signIn(Map<String, dynamic> auth,
      {required String username, required String password}) async {
    final userId = auth['user_id'] as String? ?? '';
    final expiresIn = (auth['expires_in'] as num?)?.toInt();
    final expiresAt = expiresIn == null || expiresIn <= 0
        ? ''
        : DateTime.now().add(Duration(seconds: expiresIn)).toIso8601String();

    final prefs = await SharedPreferences.getInstance();
    if (userId.isNotEmpty) {
      await prefs.setString(_passKeyFor(userId), password);
    }
    // Feature flags are per account: keep the ones this account had when it
    // was last used here, start fresh for a new one (the server copy is
    // applied on the next sync).
    final known = _accounts.where((a) => a.userId == userId).firstOrNull;
    await save(_current.copyWith(
      authToken: auth['token'] as String? ?? '',
      tokenExpiresAt: expiresAt,
      username: auth['username'] as String? ?? username,
      fullName: auth['full_name'] as String? ?? '',
      userId: userId,
      email: auth['email'] as String? ?? '',
      phoneNumber: auth['phone_number'] as String? ?? '',
      telegramUsername: auth['telegram_username'] as String? ?? '',
      features: known?.features ?? const {},
    ));
  }

  /// Makes the saved account [userId] the active one.
  Future<void> switchAccount(String userId) async {
    if (userId == _current.userId) return;
    final account = _accounts.where((a) => a.userId == userId).firstOrNull;
    if (account == null) return;
    await save(account.applyTo(_current));
  }

  /// Signs the active account out of this device. Its local data stays on
  /// the device (scoped to its user id) but can no longer be opened without
  /// signing in again. When other accounts are signed in, the first of them
  /// becomes active; otherwise the app goes back to the login screen.
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = _current.userId;
    await prefs.remove(_passKeyFor(userId));
    // Drop unpushed flag changes so they cannot land later by accident.
    await prefs.remove(_pendingKeyFor(userId));
    _accounts = _accounts.where((a) => a.userId != userId).toList();
    await _saveAccounts(prefs);

    if (_accounts.isNotEmpty) {
      await save(_accounts.first.applyTo(_current));
      return;
    }
    await save(_current.copyWith(
      authToken: '',
      tokenExpiresAt: '',
      userId: '',
      fullName: '',
      features: const {},
    ));
  }

  // ── Profile ─────────────────────────────────────────────────────────────
  /// Sets the active account's display name (full name / alias) on
  /// login-api, then locally. Blank clears it, so the username is shown.
  Future<void> updateFullName(String fullName) async {
    final name = fullName.trim();
    Future<void> push() => RemoteApi(_current).updateProfile(fullName: name);
    try {
      await push();
    } on ApiUnauthorizedException {
      if (!await tryRefreshToken()) rethrow;
      await push();
    }
    await save(_current.copyWith(fullName: name));
  }

  // ── Feature flags ───────────────────────────────────────────────────────
  /// Switches an optional feature on or off. The local value is written
  /// first, so the switch responds instantly and keeps working with no API
  /// connection; the server copy is updated in the background and retried
  /// later if the push fails.
  Future<void> setFeature(String featureId, bool enabled) async {
    await save(_current.withFeature(featureId, enabled));
    final prefs = await SharedPreferences.getInstance();
    final key = _pendingKeyFor(_current.userId);
    final pending = (prefs.getStringList(key) ?? const []).toSet()
      ..add(featureId);
    await prefs.setStringList(key, pending.toList());
    unawaited(pushPendingFeatures());
  }

  /// Best-effort push of every locally-changed flag to transaction-api.
  /// Ids that fail stay queued; nothing here ever throws, because losing the
  /// server round-trip must not stop the toggle from working.
  Future<void> pushPendingFeatures() async {
    if (!_current.isLoggedIn) return;
    final cfg = _current;
    final prefs = await SharedPreferences.getInstance();
    final key = _pendingKeyFor(cfg.userId);
    final pending = prefs.getStringList(key) ?? const [];
    if (pending.isEmpty) return;

    final api = RemoteApi(cfg);
    final remaining = <String>[];
    for (final id in pending) {
      final feature = AppFeatures.byId(id);
      // The flag was removed in a newer build - drop it from the queue.
      if (feature == null) continue;
      try {
        await api.putSetting(
          feature.settingKey,
          cfg.isFeatureEnabled(id).toString(),
        );
      } catch (_) {
        remaining.add(id);
      }
    }
    await prefs.setStringList(key, remaining);
  }

  /// Applies the feature flags carried by a `GET /api/user/settings`
  /// response. Flags still queued for push are skipped, so a change made
  /// offline is never overwritten by the older server value.
  Future<void> applyRemoteSettings(List<Map<String, dynamic>> settings) async {
    final prefs = await SharedPreferences.getInstance();
    final pending =
        (prefs.getStringList(_pendingKeyFor(_current.userId)) ?? const [])
            .toSet();

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

  Future<String?> _getSavedPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_passKeyFor(_current.userId));
  }

  /// Re-authenticates the active account using its stored credentials and
  /// saves the new token. Returns true if a fresh token was obtained.
  Future<bool> tryRefreshToken() async {
    final cfg = _current;
    final username = cfg.username;
    final password = await _getSavedPassword();
    if (username.isEmpty || password == null || password.isEmpty) return false;
    try {
      final auth =
          await RemoteApi(cfg).login(username: username, password: password);
      // The account may have been switched while the request was out.
      if (_current.userId != cfg.userId) return false;
      final expiresIn = (auth['expires_in'] as num?)?.toInt();
      final expiresAt = expiresIn == null || expiresIn <= 0
          ? ''
          : DateTime.now()
              .add(Duration(seconds: expiresIn))
              .toIso8601String();
      await save(_current.copyWith(
        authToken: auth['token'] as String? ?? '',
        tokenExpiresAt: expiresAt,
        fullName: auth['full_name'] as String? ?? _current.fullName,
      ));
      return true;
    } catch (_) {
      return false;
    }
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
