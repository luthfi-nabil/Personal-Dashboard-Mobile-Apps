import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../core/db.dart';
import '../core/models.dart';
import '../core/sync.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

class PendingSyncScreen extends ConsumerStatefulWidget {
  const PendingSyncScreen({super.key});

  @override
  ConsumerState<PendingSyncScreen> createState() => _PendingSyncScreenState();
}

class _PendingSyncScreenState extends ConsumerState<PendingSyncScreen> {
  Future<List<_PendingSyncItem>>? _future;
  String? _loadedUserId;
  int? _loadedPendingCount;

  void _ensureLoaded(String userId, int pendingCount) {
    if (_future != null &&
        _loadedUserId == userId &&
        _loadedPendingCount == pendingCount) {
      return;
    }
    _loadedUserId = userId;
    _loadedPendingCount = pendingCount;
    _future = _loadPendingItems(userId);
  }

  void _reload() {
    setState(() {
      _loadedUserId = null;
      _loadedPendingCount = null;
      _future = null;
    });
  }

  Future<void> _syncNow() async {
    await ref.read(appDataProvider.notifier).refresh();
    if (!mounted) return;
    _reload();
    final failed = ref.read(appDataProvider).hasError ||
        ref.read(syncStatusProvider) == SyncStatus.error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failed ? 'Sync failed' : 'Synced')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final userId = ref.watch(configProvider.select((cfg) => cfg.userId));
    final pendingCount = ref.watch(pendingSyncCountProvider);
    final syncStatus = ref.watch(syncStatusProvider);
    final cfg = ConfigService.instance.current;

    _ensureLoaded(userId, pendingCount);

    return FutureBuilder<List<_PendingSyncItem>>(
      future: _future,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <_PendingSyncItem>[];
        final grouped = _groupItems(items);

        return RefreshIndicator(
          onRefresh: () async => _reload(),
          color: c.accent,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pending sync',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: c.ink,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          pendingCount == 0
                              ? 'No local changes waiting to sync'
                              : '$pendingCount local item${pendingCount == 1 ? '' : 's'} waiting',
                          style: TextStyle(fontSize: 13, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _reload,
                    icon: Icon(Icons.refresh_rounded, color: c.ink),
                  ),
                  FilledButton.icon(
                    onPressed:
                        syncStatus == SyncStatus.syncing ? null : _syncNow,
                    icon: syncStatus == SyncStatus.syncing
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: c.bg,
                            ),
                          )
                        : const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('Sync now'),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.ink,
                      foregroundColor: c.bg,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _StatusCard(
                c: c,
                isOnline: SyncService.instance.isOnline,
                autoSync: cfg.autoSync,
                syncStatus: syncStatus,
              ),
              const SizedBox(height: 16),
              if (snapshot.connectionState == ConnectionState.waiting)
                Padding(
                  padding: const EdgeInsets.only(top: 36),
                  child: Center(
                    child: CircularProgressIndicator(color: c.accent),
                  ),
                )
              else if (items.isEmpty)
                _EmptyState(c: c)
              else
                for (final group in grouped.entries) ...[
                  _SectionHeader(
                      label: group.key, count: group.value.length, c: c),
                  const SizedBox(height: 8),
                  for (final item in group.value) ...[
                    _PendingTile(item: item, c: c),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 8),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _PendingSyncItem {
  final String group;
  final String title;
  final String subtitle;
  final String timestamp;
  final String action;
  final IconData icon;

  const _PendingSyncItem({
    required this.group,
    required this.title,
    required this.subtitle,
    required this.timestamp,
    required this.action,
    required this.icon,
  });
}

Future<List<_PendingSyncItem>> _loadPendingItems(String userId) async {
  final results = await Future.wait([
    AppDb.instance.getPendingSources(userId),
    AppDb.instance.getPendingCategories(userId),
    AppDb.instance.getPendingActivityCategories(userId),
    AppDb.instance.getPendingTransactions(userId),
    AppDb.instance.getPendingWishlistItems(userId),
    AppDb.instance.getPendingRoutineTransactions(userId),
    AppDb.instance.getPendingRoutinePayments(userId),
    AppDb.instance.getPendingInsulinItems(userId),
    AppDb.instance.getPendingInsulinAssigns(userId),
    AppDb.instance.getPendingInsulinUsages(userId),
    AppDb.instance.getPendingBloodSugarLogs(userId),
    AppDb.instance.getPendingDeletes(userId),
    AppDb.instance.getDirtyTransactionDetails(userId),
    AppDb.instance.getPendingConsumables(userId),
    AppDb.instance.getPendingInvestments(userId),
  ]);

  final items = <_PendingSyncItem>[
    for (final item in results[0] as List<Source>)
      _PendingSyncItem(
        group: 'Options',
        title: item.name,
        subtitle: 'Source - ${item.kind}',
        timestamp: item.updatedAt,
        action: 'Create',
        icon: Icons.account_balance_wallet_outlined,
      ),
    for (final item in results[1] as List<Category>)
      _PendingSyncItem(
        group: 'Options',
        title: item.name,
        subtitle: '${_titleCase(item.kind)} category',
        timestamp: item.updatedAt,
        action: 'Create',
        icon: Icons.label_outline_rounded,
      ),
    for (final item in results[2] as List<ActivityCategory>)
      _PendingSyncItem(
        group: 'Activities',
        title: item.name,
        subtitle: 'Activity category',
        timestamp: item.updatedAt,
        action: 'Create',
        icon: Icons.fact_check_outlined,
      ),
    for (final item in results[3] as List<Transaction>) _transactionItem(item),
    for (final item in results[4] as List<WishlistItem>)
      _PendingSyncItem(
        group: 'Planning',
        title: item.itemName,
        subtitle:
            '${fmtRp(item.price, ConfigService.instance.current.currency)} - ${item.status}',
        timestamp: item.updatedAt,
        action: item.status == 'active' ? 'Create' : 'Update',
        icon: Icons.bookmark_border_rounded,
      ),
    for (final item in results[5] as List<RoutineTransaction>)
      _PendingSyncItem(
        group: 'Routine',
        title: item.itemName,
        subtitle: '${item.reminder} - ${item.categoryName}',
        timestamp: item.updatedAt,
        action: 'Create',
        icon: Icons.repeat_rounded,
      ),
    for (final item in results[6] as List<RoutinePayment>)
      _PendingSyncItem(
        group: 'Routine',
        title: item.itemName,
        subtitle:
            '${fmtRp(item.price, ConfigService.instance.current.currency)} - ${item.sourceName}',
        timestamp: item.boughtAt,
        action: 'Create',
        icon: Icons.payments_outlined,
      ),
    for (final item in results[7] as List<InsulinItem>)
      _PendingSyncItem(
        group: 'Health',
        title: item.name,
        subtitle: '${_compactNumber(item.units)} ${item.uom}',
        timestamp: item.date,
        action: 'Create',
        icon: Icons.medication_liquid_outlined,
      ),
    for (final item in results[8] as List<InsulinAssign>)
      _PendingSyncItem(
        group: 'Health',
        title: item.itemName.isEmpty ? item.batchNo : item.itemName,
        subtitle: 'Batch ${item.batchNo}',
        timestamp: item.date,
        action: 'Create',
        icon: Icons.inventory_2_outlined,
      ),
    for (final item in results[9] as List<InsulinUsage>)
      _PendingSyncItem(
        group: 'Health',
        title: '${_compactNumber(item.units)} units',
        subtitle: item.notes?.trim().isNotEmpty == true
            ? item.notes!.trim()
            : 'Insulin usage',
        timestamp: item.date,
        action: 'Create',
        icon: Icons.vaccines_outlined,
      ),
    for (final item in results[10] as List<BloodSugarLog>)
      _PendingSyncItem(
        group: 'Health',
        title: '${_compactNumber(item.level)} ${item.unit}',
        subtitle: item.mealContext?.trim().isNotEmpty == true
            ? item.mealContext!.trim()
            : 'Blood sugar log',
        timestamp: item.measuredAt,
        action: 'Create',
        icon: Icons.monitor_heart_outlined,
      ),
    for (final item in results[11] as List<PendingDelete>) _deleteItem(item),
    // Line items whose tick was changed while the API was unreachable. The
    // item itself is already on the server; only the checkbox is queued.
    for (final item in results[12] as List<TransactionDetail>)
      _PendingSyncItem(
        group: 'Transactions',
        title: item.itemName.isEmpty ? 'Item' : item.itemName,
        subtitle: item.checked
            ? 'Transaction detail - ticked'
            : 'Transaction detail - unticked',
        timestamp: item.updatedAt,
        action: 'Update',
        icon: Icons.checklist_rounded,
      ),
    for (final item in results[13] as List<Consumable>)
      _PendingSyncItem(
        group: 'Personal',
        title: item.isPartOfBatch
            ? '${item.itemName} (${item.unitIndex}/${item.unitTotal})'
            : item.itemName,
        subtitle: item.isInUse ? 'Consumable - in use' : 'Consumable - used up',
        timestamp: item.updatedAt,
        action: 'Create',
        icon: Icons.inventory_2_outlined,
      ),
    for (final item in results[14] as List<Investment>)
      _PendingSyncItem(
        group: 'Finance',
        title: item.name,
        subtitle: '${item.kind.label} - '
            '${fmtUnits(item.units)} ${item.kind.unitLabel}',
        timestamp: item.updatedAt,
        action: 'Create',
        icon: Icons.trending_up_rounded,
      ),
  ];

  items.sort((a, b) {
    final ad = DateTime.tryParse(a.timestamp);
    final bd = DateTime.tryParse(b.timestamp);
    if (ad == null || bd == null) return a.timestamp.compareTo(b.timestamp);
    return ad.compareTo(bd);
  });
  return items;
}

_PendingSyncItem _transactionItem(Transaction item) {
  final currency = ConfigService.instance.current.currency;
  final title = switch (item.type) {
    'earning' => 'Earning ${fmtRp(item.amount, currency)}',
    'spending' => 'Spending ${fmtRp(item.amount, currency)}',
    'transfer' => 'Transfer ${fmtRp(item.amount, currency)}',
    _ => '${_titleCase(item.type)} ${fmtRp(item.amount, currency)}',
  };
  final subtitle = item.type == 'transfer'
      ? '${item.fromSource ?? '-'} to ${item.toSource ?? '-'}'
      : [
          if ((item.category ?? '').isNotEmpty) item.category,
          if ((item.source ?? '').isNotEmpty) item.source,
          if (item.description.trim().isNotEmpty) item.description.trim(),
        ].whereType<String>().join(' - ');

  return _PendingSyncItem(
    group: 'Transactions',
    title: title,
    subtitle: subtitle.isEmpty ? 'Transaction' : subtitle,
    timestamp: item.date,
    action: 'Create',
    icon: item.type == 'earning'
        ? Icons.trending_up_rounded
        : item.type == 'transfer'
            ? Icons.swap_horiz_rounded
            : Icons.trending_down_rounded,
  );
}

_PendingSyncItem _deleteItem(PendingDelete item) {
  final resource = item.resource.replaceAll('_', ' ');
  final secondary =
      item.secondaryId == null ? '' : ' + ${_shortId(item.secondaryId!)}';
  return _PendingSyncItem(
    group: 'Deletes',
    title: 'Delete ${_titleCase(resource)}',
    subtitle: '${_shortId(item.id)}$secondary',
    timestamp: item.updatedAt,
    action: 'Delete',
    icon: Icons.delete_outline_rounded,
  );
}

Map<String, List<_PendingSyncItem>> _groupItems(List<_PendingSyncItem> items) {
  final grouped = <String, List<_PendingSyncItem>>{};
  for (final item in items) {
    (grouped[item.group] ??= []).add(item);
  }
  return grouped;
}

String _titleCase(String value) {
  return value
      .replaceAll('_', ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

String _compactNumber(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toString();
}

class _StatusCard extends StatelessWidget {
  final AppColors c;
  final bool isOnline;
  final bool autoSync;
  final SyncStatus syncStatus;

  const _StatusCard({
    required this.c,
    required this.isOnline,
    required this.autoSync,
    required this.syncStatus,
  });

  @override
  Widget build(BuildContext context) {
    final status = switch (syncStatus) {
      SyncStatus.syncing => 'Syncing',
      SyncStatus.done => 'Synced recently',
      SyncStatus.error => 'Last sync failed',
      _ => isOnline ? 'Ready' : 'Offline',
    };
    final tone = syncStatus == SyncStatus.error
        ? c.neg
        : isOnline
            ? c.pos
            : c.muted;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status,
              style: TextStyle(
                color: c.ink,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
          Text(
            autoSync ? 'Auto-sync on' : 'Auto-sync off',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final AppColors c;

  const _SectionHeader({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: c.muted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          '$count',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
      ],
    );
  }
}

class _PendingTile extends StatelessWidget {
  final _PendingSyncItem item;
  final AppColors c;

  const _PendingTile({required this.item, required this.c});

  @override
  Widget build(BuildContext context) {
    final actionColor = item.action == 'Delete' ? c.neg : c.accent;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: actionColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(item.icon, size: 19, color: actionColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: actionColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        item.action,
                        style: TextStyle(
                          color: actionColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (item.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  _formatTimestamp(item.timestamp),
                  style: TextStyle(color: c.muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final AppColors c;

  const _EmptyState({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        children: [
          Icon(Icons.cloud_done_outlined, size: 34, color: c.pos),
          const SizedBox(height: 10),
          Text(
            'Everything is synced',
            style: TextStyle(
              color: c.ink,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'New offline changes will appear here before they reach the server.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

String _formatTimestamp(String value) {
  if (value.trim().isEmpty) return 'No timestamp';
  final date = fmtDate(value, 'long');
  final time = fmtDate(value, 'time');
  if (date == value && time == value) return value;
  return '$date, $time';
}
