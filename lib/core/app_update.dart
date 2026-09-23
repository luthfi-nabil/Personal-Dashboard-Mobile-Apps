import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

enum AppUpdateState {
  idle,
  checking,
  upToDate,
  available,
  downloading,

  /// Downloaded and verified; waiting for the user to confirm the system
  /// install prompt.
  ready,
  offline,
  unsupported,
  error,
}

/// What the update server says the newest build is (`android/version.json`,
/// written by `publish-update.ps1`).
class AppRelease {
  final String version;
  final int build;
  final String apk;
  final String sha256;
  final int size;
  final String notes;

  const AppRelease({
    required this.version,
    required this.build,
    required this.apk,
    required this.sha256,
    required this.size,
    required this.notes,
  });

  factory AppRelease.fromJson(Map<String, dynamic> m) => AppRelease(
        version: m['version']?.toString() ?? '',
        build: (m['build'] as num?)?.toInt() ?? 0,
        apk: m['apk']?.toString() ?? '',
        sha256: (m['sha256']?.toString() ?? '').toLowerCase(),
        size: (m['size'] as num?)?.toInt() ?? 0,
        notes: m['notes']?.toString() ?? '',
      );

  String get label => '$version ($build)';
}

/// In-app updates for the sideloaded Android build, from the same
/// self-hosted server the desktop app uses (the `desktop-updates` container,
/// port 3054, path `/android/`).
///
/// Android never lets a sideloaded app replace itself silently, so "auto"
/// here means: the check runs by itself whenever a sync reaches the server,
/// the APK downloads in the background and is verified against the
/// published SHA-256, and then the system installer is opened - the user
/// taps Install once. iOS and other platforms report [unsupported].
///
/// The installed app and the new APK must be signed with the same key and
/// share the application id, or Android refuses the update ("App not
/// installed"); `publish-update.ps1` builds on this machine for that reason.
class AppUpdateService extends ChangeNotifier {
  static final AppUpdateService instance = AppUpdateService._();
  AppUpdateService._();

  static const _channel = MethodChannel('personal_dashboard/app_update');
  static const _baseKey = 'pd-update-base-v1';
  static const updatePort = 3054;

  /// Background checks (after a sync) at most this often.
  static const _minAutoInterval = Duration(minutes: 15);

  AppUpdateState state = AppUpdateState.idle;
  AppRelease? latest;
  String? error;
  double progress = 0;
  String currentVersion = '';
  int currentBuild = 0;
  DateTime? lastChecked;

  /// Server set in Settings, or empty to derive it from the Transaction API.
  String customBase = '';

  DateTime? _lastAutoCheck;
  bool _busy = false;
  String? _apkPath;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  void _set(AppUpdateState next, {String? err}) {
    state = next;
    error = err;
    notifyListeners();
  }

  /// Loads the saved server override and the installed version.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    customBase = prefs.getString(_baseKey) ?? '';
    if (!isSupported) {
      _set(AppUpdateState.unsupported,
          err: 'In-app updates are only available on Android.');
      return;
    }
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('version');
      currentVersion = info?['name']?.toString() ?? '';
      currentBuild = (info?['code'] as num?)?.toInt() ?? 0;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setCustomBase(String value) async {
    customBase = value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseKey, customBase);
    notifyListeners();
  }

  /// The update server: the one set in Settings, else the Transaction API's
  /// host on port 3054 (both run in the same docker-compose stack).
  String get baseUrl {
    if (customBase.isNotEmpty) return customBase.replaceAll(RegExp(r'/+$'), '');
    final api = Uri.tryParse(ConfigService.instance.current.apiBase);
    final host = (api == null || api.host.isEmpty) ? '127.0.0.1' : api.host;
    return '${api?.scheme.isNotEmpty == true ? api!.scheme : 'http'}://$host:$updatePort';
  }

  String get _feed => '$baseUrl/android';

  /// Looks for a newer build and, when there is one, downloads it.
  /// [manual] skips the throttle (Settings → Check now).
  Future<void> check({bool manual = false}) async {
    if (!isSupported || _busy) return;
    if (state == AppUpdateState.ready || state == AppUpdateState.downloading) {
      return;
    }
    final now = DateTime.now();
    if (!manual &&
        _lastAutoCheck != null &&
        now.difference(_lastAutoCheck!) < _minAutoInterval) {
      return;
    }
    _lastAutoCheck = now;
    _busy = true;
    _set(AppUpdateState.checking);
    try {
      final res = await http
          .get(Uri.parse('$_feed/version.json'),
              headers: {'cache-control': 'no-cache'})
          .timeout(const Duration(seconds: 5));
      lastChecked = DateTime.now();
      if (res.statusCode != 200) {
        _set(AppUpdateState.offline,
            err: 'No release published on $baseUrl (HTTP ${res.statusCode}).');
        return;
      }
      final release = AppRelease.fromJson(
          Map<String, dynamic>.from(jsonDecode(res.body) as Map));
      latest = release;
      if (release.build <= currentBuild || release.apk.isEmpty) {
        _set(AppUpdateState.upToDate);
        return;
      }
      _set(AppUpdateState.available);
      _busy = false;
      await download();
    } on TimeoutException {
      _set(AppUpdateState.offline, err: 'Update server $baseUrl is not reachable.');
    } on SocketException {
      _set(AppUpdateState.offline, err: 'Update server $baseUrl is not reachable.');
    } on http.ClientException {
      _set(AppUpdateState.offline, err: 'Update server $baseUrl is not reachable.');
    } catch (e) {
      _set(AppUpdateState.error, err: '$e');
    } finally {
      _busy = false;
    }
  }

  /// Streams the APK into the cache dir (shared with the installer through
  /// the `updates/` FileProvider path) and checks its SHA-256.
  Future<void> download() async {
    final release = latest;
    if (release == null || _busy) return;
    _busy = true;
    progress = 0;
    _set(AppUpdateState.downloading);
    final client = http.Client();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      final file = File('${dir.path}/${release.apk}');

      final res = await client
          .send(http.Request('GET', Uri.parse('$_feed/${Uri.encodeComponent(release.apk)}')));
      if (res.statusCode != 200) throw 'Download failed (HTTP ${res.statusCode})';
      final total = res.contentLength ?? release.size;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          progress = received / total;
          notifyListeners();
        }
      }
      await sink.close();

      final hash = await _channel.invokeMethod<String>('sha256', {'path': file.path});
      if (release.sha256.isNotEmpty && hash != release.sha256) {
        await file.delete();
        throw 'The download is damaged (checksum mismatch). Try again.';
      }
      _apkPath = file.path;
      _set(AppUpdateState.ready);
    } catch (e) {
      _set(AppUpdateState.error, err: '$e');
    } finally {
      client.close();
      _busy = false;
    }
  }

  /// Opens the system installer for the downloaded APK. Returns false when
  /// Android first needs "Install unknown apps" allowed for this app - the
  /// settings page is opened and the user comes back and taps again.
  Future<bool> install() async {
    final path = _apkPath;
    if (path == null) return false;
    final allowed = await _channel.invokeMethod<bool>('canInstall') ?? false;
    if (!allowed) {
      await _channel.invokeMethod('openInstallSettings');
      return false;
    }
    await _channel.invokeMethod('install', {'path': path});
    return true;
  }

  String get statusText => switch (state) {
        AppUpdateState.idle => 'Not checked yet.',
        AppUpdateState.checking => 'Checking for updates…',
        AppUpdateState.upToDate => 'You are on the latest version.',
        AppUpdateState.available => 'Version ${latest?.label} is available.',
        AppUpdateState.downloading =>
          'Downloading ${latest?.label}… ${(progress * 100).round()}%',
        AppUpdateState.ready => 'Version ${latest?.label} is ready to install.',
        AppUpdateState.offline => 'Not connected to the update server. ${error ?? ''}',
        AppUpdateState.unsupported => error ?? 'Not supported on this device.',
        AppUpdateState.error => 'Update failed: ${error ?? 'unknown error'}',
      };
}
