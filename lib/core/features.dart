/// Registry of optional ("extra") app features that the user can switch on
/// and off from Settings.
///
/// Adding a new toggle is a one-line change: append an [AppFeature] to
/// [AppFeatures.all]. Settings renders the list automatically, and any screen
/// can gate itself with `cfg.isFeatureEnabled(AppFeatures.health.id)`.
class AppFeature {
  /// Stable identifier persisted in `AppConfig.features`. Never rename it —
  /// doing so silently resets the user's choice back to [defaultEnabled].
  final String id;

  /// Shown as the switch label in Settings.
  final String label;

  /// One-line explanation shown under the label.
  final String description;

  /// Value used when the user has never touched the switch.
  final bool defaultEnabled;

  const AppFeature({
    required this.id,
    required this.label,
    required this.description,
    this.defaultEnabled = true,
  });

  /// Key this flag is stored under in login-api's `app_settings`.
  /// The API only accepts `FEATURE_*` / `PREF_*` keys from clients.
  String get settingKey => 'FEATURE_${id.toUpperCase()}';
}

class AppFeatures {
  AppFeatures._();

  /// Diabetic tracking: insulin items, batches, usage logs and blood sugar.
  /// Turning it off hides the Diabetic destination, the Home health panel and
  /// the insulin quick actions. Nothing is deleted, so switching it back on
  /// restores everything as it was.
  static const health = AppFeature(
    id: 'health',
    label: 'Health / Diabetic',
    description:
        'Insulin logs, batches and blood sugar tracking. Turning this off '
        'hides the section everywhere — your data is kept.',
  );

  static const List<AppFeature> all = [health];

  static AppFeature? byId(String id) {
    for (final feature in all) {
      if (feature.id == id) return feature;
    }
    return null;
  }

  /// Maps a login-api `app_settings` key back to a feature id, or null
  /// when the key belongs to something else.
  static String? idForSettingKey(String settingKey) {
    for (final feature in all) {
      if (feature.settingKey == settingKey.toUpperCase()) return feature.id;
    }
    return null;
  }
}
