import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/background_sync.dart';
import '../core/config.dart';
import '../core/db.dart';
import '../core/notifications.dart';
import '../core/features.dart';
import '../core/models.dart';
import '../core/seed.dart';
import '../core/sync.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';
import 'dart:convert';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content:
            const Text("You'll need to sign in again to sync with the server."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Log out')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ConfigService.instance.logout();
    if (!mounted) return;

    // Explicitly replace the shell route after clearing the session. The
    // router redirect remains a fallback for expiry and API-triggered logout.
    context.go('/login');
  }

  /// Writes the flag locally (always succeeds, online or not) and lets
  /// [ConfigService] deal with getting it to the server.
  Future<void> _setFeature(AppFeature feature, bool enabled) async {
    // ConfigService notifies its listeners, so `configProvider` (and every
    // screen watching it) picks the new value up on its own.
    await ConfigService.instance.setFeature(feature.id, enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${feature.label} ${enabled ? 'enabled' : 'disabled'}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _syncNow() async {
    await ref.read(appDataProvider.notifier).refresh(force: true);
    if (!mounted) return;
    final failed = ref.read(appDataProvider).hasError ||
        ref.read(syncStatusProvider) == SyncStatus.error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failed ? 'Sync failed' : 'Synced')),
    );
  }

  Future<void> _exportJson() async {
    final data = await ref.read(appDataProvider.future);
    final json = const JsonEncoder.withIndent('  ').convert({
      'sources': data.sources.map((s) => s.toMap()).toList(),
      'categories': data.categories.map((c) => c.toMap()).toList(),
      'transactions': data.transactions.map((t) => t.toMap()).toList(),
    });
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/personal-dashboard.json');
    await file.writeAsString(json);
    await Share.shareXFiles([XFile(file.path)],
        subject: 'personal-dashboard.json');
  }

  Future<void> _resetData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset & re-seed?'),
        content: const Text(
            'This will wipe all local data and restore sample data.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true) return;
    await AppDb.instance.clearAll();
    await seedIfEmpty();
    await ref.read(appDataProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);
    final pendingCount = ref.watch(pendingSyncCountProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          const SizedBox(height: 14),
          Text('Settings',
              style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: c.ink,
                  letterSpacing: -0.02)),
          const SizedBox(height: 18),

          // ── Account ────────────────────────────────────────────
          _SectionTitle('Account', c),
          const SizedBox(height: 10),
          _card(
              c,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: c.ink,
                            borderRadius: BorderRadius.circular(12)),
                        child: Text(
                          cfg.username.isNotEmpty
                              ? cfg.username[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                              color: c.bg,
                              fontWeight: FontWeight.w700,
                              fontSize: 16),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                cfg.username.isEmpty
                                    ? 'Signed in'
                                    : cfg.username,
                                style: TextStyle(
                                    color: c.ink,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                            if (cfg.email.isNotEmpty)
                              Text(cfg.email,
                                  style:
                                      TextStyle(color: c.muted, fontSize: 12)),
                          ],
                        ),
                      ),
                      TextButton(
                          onPressed: _logout,
                          child:
                              Text('Log out', style: TextStyle(color: c.neg))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Switch(
                        value: cfg.autoSync,
                        activeColor: c.accent,
                        onChanged: (v) => ref
                            .read(configProvider.notifier)
                            .update(cfg.copyWith(autoSync: v)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text('Auto-sync when online',
                              style: TextStyle(color: c.ink, fontSize: 14))),
                      TextButton(
                          onPressed: _syncNow,
                          child: Text('Sync now',
                              style: TextStyle(color: c.accent))),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      cfg.isLoggedIn
                          ? (SyncService.instance.isOnline
                              ? 'Connected, ready to sync'
                              : 'Signed in but offline - showing cached data')
                          : 'Sign in to connect to your server',
                      style: TextStyle(fontSize: 12, color: c.muted),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () => context.push('/server-settings'),
                        icon:
                            Icon(Icons.dns_outlined, size: 16, color: c.accent),
                        label: Text('Server settings',
                            style: TextStyle(color: c.accent)),
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 32)),
                      ),
                      TextButton.icon(
                        onPressed: () => context.push('/pending-sync'),
                        icon: Icon(Icons.sync_outlined,
                            size: 16, color: c.accent),
                        label: Text(
                            pendingCount > 0
                                ? 'Pending sync ($pendingCount)'
                                : 'Pending sync',
                            style: TextStyle(color: c.accent)),
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 32)),
                      ),
                      TextButton.icon(
                        onPressed: () => context.push('/api-log'),
                        icon: Icon(Icons.network_check,
                            size: 16, color: c.accent),
                        label: Text('API Watcher',
                            style: TextStyle(color: c.accent)),
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 32)),
                      ),
                    ],
                  ),
                ],
              )),
          const SizedBox(height: 18),

          // ── Extra features ─────────────────────────────────────
          _SectionTitle('Extra features', c),
          const SizedBox(height: 10),
          _card(
            c,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Switch optional sections on or off. Changes apply straight '
                  'away and are saved to your account when the API is '
                  'reachable.',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < AppFeatures.all.length; i++) ...[
                  if (i > 0) const Divider(height: 20),
                  _FeatureToggle(
                    feature: AppFeatures.all[i],
                    enabled: cfg.isFeatureEnabled(AppFeatures.all[i].id),
                    c: c,
                    onChanged: (v) => _setFeature(AppFeatures.all[i], v),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ── Reminders & background sync ────────────────────
          if (NotificationService.isSupported) ...[
            _SectionTitle('Reminders & background sync', c),
            const SizedBox(height: 10),
            _card(
              c,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PrefToggle(
                    label: 'Routine reminders',
                    description:
                        'Notify before a routine transaction falls due. Due '
                        'dates come from each routine, using its last payment '
                        'and its frequency.',
                    enabled: cfg.remindersEnabled,
                    c: c,
                    onChanged: _setRemindersEnabled,
                  ),
                  if (cfg.remindersEnabled) ...[
                    const Divider(height: 20),
                    Row(
                      children: [
                        Expanded(
                            child: Text('Notify at',
                                style: TextStyle(color: c.ink, fontSize: 14))),
                        TextButton(
                          onPressed: () => _pickReminderTime(cfg),
                          child: Text(_formatTime(cfg),
                              style: TextStyle(
                                  color: c.accent,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('How far ahead',
                        style: TextStyle(color: c.muted, fontSize: 12)),
                    const SizedBox(height: 6),
                    _SegRow(
                      options: const ['0', '1', '3', '7'],
                      labels: const ['Same day', '1 day', '3 days', '7 days'],
                      current: cfg.reminderLeadDays.toString(),
                      c: c,
                      onSelect: (v) => ref
                          .read(configProvider.notifier)
                          .update(cfg.copyWith(
                              reminderLeadDays: int.tryParse(v) ?? 1)),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'A routine that is already overdue is re-notified once '
                      'a day until you confirm it as paid.',
                      style:
                          TextStyle(color: c.muted, fontSize: 12, height: 1.35),
                    ),
                  ],
                  const Divider(height: 20),
                  _PrefToggle(
                    label: 'Sync while the app is closed',
                    description:
                        'Let Android wake the app to push queued changes and '
                        'pull new data. Android will not run this more often '
                        'than every 15 minutes, and may delay it further '
                        'while the phone is asleep.',
                    enabled: cfg.backgroundSyncEnabled,
                    c: c,
                    onChanged: (v) => ref
                        .read(configProvider.notifier)
                        .update(cfg.copyWith(backgroundSyncEnabled: v)),
                  ),
                  if (cfg.backgroundSyncEnabled) ...[
                    const SizedBox(height: 10),
                    _SegRow(
                      options: const ['15', '30', '60', '180'],
                      labels: const ['15 min', '30 min', '1 hour', '3 hours'],
                      current: cfg.backgroundSyncMinutes.toString(),
                      c: c,
                      onSelect: (v) => ref
                          .read(configProvider.notifier)
                          .update(cfg.copyWith(
                              backgroundSyncMinutes: int.tryParse(v) ?? 30)),
                    ),
                    const SizedBox(height: 8),
                    FutureBuilder<DateTime?>(
                      future: BackgroundSyncService.lastRun(),
                      builder: (context, snapshot) => Text(
                        snapshot.data == null
                            ? 'Has not run yet.'
                            : 'Last background sync: '
                                '${_formatDateTime(snapshot.data!)}',
                        style: TextStyle(color: c.muted, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],

          // ── Appearance ─────────────────────────────────────────
          _SectionTitle('Appearance', c),
          const SizedBox(height: 10),
          _card(
              c,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Theme',
                      style: TextStyle(
                          fontSize: 12,
                          color: c.muted,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  _SegRow(
                    options: const ['ink', 'warm', 'dark'],
                    current: cfg.theme,
                    c: c,
                    onSelect: (v) => ref
                        .read(configProvider.notifier)
                        .update(cfg.copyWith(theme: v)),
                  ),
                  const SizedBox(height: 14),
                  Text('Density',
                      style: TextStyle(
                          fontSize: 12,
                          color: c.muted,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  _SegRow(
                    options: const ['compact', 'regular', 'comfy'],
                    current: cfg.density,
                    c: c,
                    onSelect: (v) => ref
                        .read(configProvider.notifier)
                        .update(cfg.copyWith(density: v)),
                  ),
                  const SizedBox(height: 14),
                  Text('Currency format',
                      style: TextStyle(
                          fontSize: 12,
                          color: c.muted,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  _SegRow(
                    options: const ['full', 'short'],
                    labels: const ['Rp 12.596.000', 'Rp 12,6 jt'],
                    current: cfg.currency,
                    c: c,
                    onSelect: (v) => ref
                        .read(configProvider.notifier)
                        .update(cfg.copyWith(currency: v)),
                  ),
                ],
              )),
          const SizedBox(height: 18),

          _SectionTitle('Data', c),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _exportJson,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.ink,
                    side: BorderSide(color: c.line, width: 0.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Export all (JSON)',
                      style: TextStyle(fontSize: 13)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _resetData,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.neg,
                    side: BorderSide(color: c.neg.withOpacity(0.3), width: 0.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Reset & re-seed',
                      style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Turning reminders on is the point at which the notification permission
  /// is actually needed, so it is requested here rather than at launch. If it
  /// is refused the switch stays off - a silent "on" that never notifies
  /// would be worse than an honest one.
  Future<void> _setRemindersEnabled(bool enabled) async {
    final notifier = ref.read(configProvider.notifier);
    if (!enabled) {
      await notifier
          .update(ref.read(configProvider).copyWith(remindersEnabled: false));
      return;
    }
    final granted = await NotificationService.instance.requestPermission();
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Notifications are blocked for this app. Enable '
                'them in Android settings to use reminders.')));
      }
      return;
    }
    await notifier
        .update(ref.read(configProvider).copyWith(remindersEnabled: true));
  }

  Future<void> _pickReminderTime(AppConfig cfg) async {
    final picked = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: cfg.reminderHour, minute: cfg.reminderMinute),
    );
    if (picked == null) return;
    await ref.read(configProvider.notifier).update(cfg.copyWith(
          reminderHour: picked.hour,
          reminderMinute: picked.minute,
        ));
  }

  String _formatTime(AppConfig cfg) =>
      '${cfg.reminderHour.toString().padLeft(2, '0')}:'
      '${cfg.reminderMinute.toString().padLeft(2, '0')}';

  String _formatDateTime(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  Widget _card(AppColors c, Widget child) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: child,
      );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors c;
  const _SectionTitle(this.text, this.c);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: c.muted,
            letterSpacing: 0.06));
  }
}

/// One row in the "Extra features" card: label, one-line description and the
/// switch that turns the section on or off.
class _FeatureToggle extends StatelessWidget {
  final AppFeature feature;
  final bool enabled;
  final AppColors c;
  final ValueChanged<bool> onChanged;

  const _FeatureToggle({
    required this.feature,
    required this.enabled,
    required this.c,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                feature.label,
                style: TextStyle(
                  color: c.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                feature.description,
                style: TextStyle(color: c.muted, fontSize: 12, height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Switch(
          value: enabled,
          activeColor: c.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Same shape as [_FeatureToggle], but for preferences that live in
/// [AppConfig] rather than the [AppFeatures] registry.
class _PrefToggle extends StatelessWidget {
  final String label;
  final String description;
  final bool enabled;
  final AppColors c;
  final ValueChanged<bool> onChanged;

  const _PrefToggle({
    required this.label,
    required this.description,
    required this.enabled,
    required this.c,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: c.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(color: c.muted, fontSize: 12, height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Switch(
          value: enabled,
          activeColor: c.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _SegRow extends StatelessWidget {
  final List<String> options;
  final List<String>? labels;
  final String current;
  final AppColors c;
  final ValueChanged<String> onSelect;
  const _SegRow(
      {required this.options,
      this.labels,
      required this.current,
      required this.c,
      required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: List.generate(options.length, (i) {
          final opt = options[i];
          final label =
              (labels != null && i < labels!.length) ? labels![i] : opt;
          final active = opt == current;
          return Expanded(
            child: GestureDetector(
              onTap: () => onSelect(opt),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                decoration: BoxDecoration(
                  color: active ? c.surface2 : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: active
                      ? [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 3)
                        ]
                      : null,
                ),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: active ? c.ink : c.muted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
