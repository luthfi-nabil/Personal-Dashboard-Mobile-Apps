import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/models.dart';
import '../core/repo.dart';
import '../core/remote_api.dart';
import '../core/utils.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';

enum InsulinView { home, activity, reports }

class InsulinScreen extends ConsumerStatefulWidget {
  final InsulinView view;

  const InsulinScreen({super.key, this.view = InsulinView.home});

  @override
  ConsumerState<InsulinScreen> createState() => _InsulinScreenState();
}

class _InsulinScreenState extends ConsumerState<InsulinScreen> {
  late final ScrollController _contentScrollController;
  late final ScrollController _statusScrollController;

  @override
  void initState() {
    super.initState();
    _contentScrollController = ScrollController(keepScrollOffset: false);
    _statusScrollController = ScrollController(keepScrollOffset: false);
  }

  @override
  void didUpdateWidget(covariant InsulinScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view != widget.view) {
      _jumpToTop(_contentScrollController);
      _jumpToTop(_statusScrollController);
    }
  }

  @override
  void dispose() {
    _contentScrollController.dispose();
    _statusScrollController.dispose();
    super.dispose();
  }

  void _jumpToTop(ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) controller.jumpTo(0);
    });
  }

  Future<void> _refresh() => ref.read(appDataProvider.notifier).refresh();

  void _showError(Object e) {
    final message = e is ApiException ? e.message : 'Something went wrong.';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openItemEditor() {
    final c = AppTheme.colorsOf(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _InsulinItemSheet(
        onSaved: _refresh,
        onError: _showError,
      ),
    );
  }

  void _openAssignEditor(List<InsulinItem> items) {
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add an insulin type first.')),
      );
      return;
    }
    final c = AppTheme.colorsOf(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _InsulinAssignSheet(
        items: items,
        onSaved: _refresh,
        onError: _showError,
      ),
    );
  }

  void _openUsageForInsulin(
      List<InsulinItem> items, List<InsulinAssign> assigns) {
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add an insulin type first.')),
      );
      return;
    }
    if (assigns.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a batch before logging usage.')),
      );
      return;
    }
    final c = AppTheme.colorsOf(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _InsulinUsageByItemSheet(
        items: items,
        assigns: assigns,
        onSaved: _refresh,
        onError: _showError,
      ),
    );
  }

  void _openUsageSheet(InsulinAssign assign) {
    final c = AppTheme.colorsOf(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _InsulinUsageSheet(
        assign: assign,
        onSaved: _refresh,
        onError: _showError,
      ),
    );
  }

  Future<void> _deleteAssign(InsulinAssign a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete batch?'),
        content:
            Text('This removes batch "${a.batchNo}" and its usage history.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Repo.instance.deleteInsulinAssign(a.id);
      await _refresh();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  Future<void> _deleteUsage(_UsageRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete usage?'),
        content: Text(
            'This removes ${_fmtNum(row.usage.units)} units logged for ${row.itemName}.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Repo.instance.deleteInsulinUsage(row.usage);
      await _refresh();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final dataAsync = ref.watch(appDataProvider);
    final pageTitle = _titleForView(widget.view);

    return dataAsync.when(
      loading: () => _statusView(
        c,
        title: pageTitle,
        message: 'Loading insulin dashboard...',
        loading: true,
      ),
      error: (e, _) => _statusView(
        c,
        title: pageTitle,
        message:
            'Could not load insulin data. Pull to refresh or check the health API.',
      ),
      data: (data) {
        final usageRows = _usageRows(
            data.insulinUsages, data.insulinAssigns, data.insulinItems);
        final monthKey = DateTime.now().toIso8601String().substring(0, 7);
        final monthRows = usageRows
            .where((row) => row.usage.date.startsWith(monthKey))
            .toList();
        final monthTotal =
            monthRows.fold<double>(0, (sum, row) => sum + row.usage.units);
        final remaining = data.insulinAssigns
            .fold<double>(0, (sum, assign) => sum + assign.totalUnits);
        final showHome = widget.view == InsulinView.home;
        final showActivity = widget.view == InsulinView.activity;
        final showReports = widget.view == InsulinView.reports;
        return ListView(
          controller: _contentScrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(pageTitle,
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: c.ink,
                          letterSpacing: -0.02)),
                ),
                if (!showReports)
                  FilledButton.icon(
                    onPressed: () => _openUsageForInsulin(
                        data.insulinItems, data.insulinAssigns),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Log dose'),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.ink,
                      foregroundColor: c.bg,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _InsulinSummaryGrid(
              monthTotal: monthTotal,
              remaining: remaining,
              activeBatches: data.insulinAssigns.length,
              c: c,
            ),
            if (showHome) ...[
              const SizedBox(height: 18),

              // ── Insulin types ──────────────────────────────────────
              Row(children: [
                _SectionTitle('Types (${data.insulinItems.length})', c),
                const Spacer(),
                TextButton(
                  onPressed: _openItemEditor,
                  child: Text('+ Add type',
                      style: TextStyle(color: c.accent, fontSize: 13)),
                ),
              ]),
              const SizedBox(height: 10),
              if (data.insulinItems.isEmpty)
                _emptyHint(c, 'No insulin types yet. Add one to get started.')
              else
                ...data.insulinItems.map((item) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: c.line2, width: 0.5),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                  color: c.surface2,
                                  borderRadius: BorderRadius.circular(10)),
                              child: Icon(Icons.vaccines_outlined,
                                  size: 20, color: c.ink),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.name,
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: c.ink)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_fmtNum(item.units)} ${item.uom}'
                                    '${(item.notes?.isNotEmpty ?? false) ? ' · ${item.notes}' : ''}',
                                    style:
                                        TextStyle(fontSize: 12, color: c.muted),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
            ],
            if (showHome || showActivity) ...[
              const SizedBox(height: 18),

              // ── Batches ────────────────────────────────────────────
              Row(children: [
                _SectionTitle('Batches (${data.insulinAssigns.length})', c),
                const Spacer(),
                TextButton(
                  onPressed: () => _openAssignEditor(data.insulinItems),
                  child: Text('+ Add batch',
                      style: TextStyle(color: c.accent, fontSize: 13)),
                ),
              ]),
              const SizedBox(height: 10),
              if (data.insulinAssigns.isEmpty)
                _emptyHint(
                    c, 'No batches yet. Add a batch for an insulin type.')
              else
                ...data.insulinAssigns.map((a) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: c.line2, width: 0.5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        a.itemName.isNotEmpty
                                            ? a.itemName
                                            : 'Unknown type',
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: c.ink),
                                      ),
                                      const SizedBox(height: 2),
                                      Text('Batch ${a.batchNo}',
                                          style: TextStyle(
                                              fontSize: 12, color: c.muted)),
                                    ],
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => _deleteAssign(a),
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Icon(Icons.delete_outline_rounded,
                                        size: 18, color: c.neg),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: _StatChip(
                                    label: 'Remaining',
                                    value: '${_fmtNum(a.totalUnits)} units',
                                    c: c,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _StatChip(
                                    label: 'Last used',
                                    value: a.lastUsedAt != null
                                        ? fmtDate(a.lastUsedAt!, 'short')
                                        : '—',
                                    c: c,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: () => _openUsageSheet(a),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: c.ink,
                                  side: BorderSide(color: c.line, width: 0.5),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                ),
                                child: const Text('Log usage',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
            ],
            if (showReports) ...[
              const SizedBox(height: 18),
              _SectionTitle('Reports', c),
              const SizedBox(height: 10),
              _InsulinReports(
                rows: monthRows,
                monthKey: monthKey,
                c: c,
              ),
            ],
            if (showActivity) ...[
              const SizedBox(height: 18),
              _SectionTitle('Usage history (${usageRows.length})', c),
              const SizedBox(height: 10),
              if (usageRows.isEmpty)
                _emptyHint(c, 'No doses logged yet.')
              else
                ...usageRows.take(12).map((row) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _UsageTile(
                        row: row,
                        c: c,
                        onDelete: () => _deleteUsage(row),
                      ),
                    )),
            ],
          ],
        );
      },
    );
  }

  Widget _emptyHint(AppColors c, String text) => Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Text(text, style: TextStyle(fontSize: 13, color: c.muted)),
      );

  Widget _statusView(
    AppColors c, {
    required String title,
    required String message,
    bool loading = false,
  }) =>
      ListView(
        controller: _statusScrollController,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: c.ink,
              letterSpacing: -0.02,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.line2, width: 0.5),
            ),
            child: Row(
              children: [
                if (loading)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: c.accent,
                      strokeWidth: 2.5,
                    ),
                  )
                else
                  Icon(Icons.info_outline_rounded, color: c.muted, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: c.muted, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}

String _titleForView(InsulinView view) => switch (view) {
      InsulinView.home => 'Insulin',
      InsulinView.activity => 'Insulin Activity',
      InsulinView.reports => 'Insulin Reports',
    };

String _fmtNum(double n) =>
    n == n.roundToDouble() ? n.round().toString() : n.toString();

String _fmtDateTime(String value) {
  final date = fmtDate(value, 'short');
  final time = fmtDate(value, 'time');
  if (date.isEmpty) return time;
  if (time.isEmpty) return date;
  return '$date $time';
}

class _UsageRow {
  final InsulinUsage usage;
  final InsulinAssign? assign;
  final InsulinItem? item;

  const _UsageRow({
    required this.usage,
    required this.assign,
    required this.item,
  });

  String get itemName =>
      item?.name ??
      assign?.itemName ??
      (assign == null ? 'Unknown insulin' : 'Unknown type');
  String get batchNo => assign?.batchNo ?? 'Unknown batch';
}

List<_UsageRow> _usageRows(
  List<InsulinUsage> usages,
  List<InsulinAssign> assigns,
  List<InsulinItem> items,
) {
  final assignById = {for (final assign in assigns) assign.id: assign};
  final itemById = {for (final item in items) item.id: item};
  final rows = usages.map((usage) {
    final assign = assignById[usage.assignId];
    return _UsageRow(
      usage: usage,
      assign: assign,
      item: assign == null ? null : itemById[assign.itemId],
    );
  }).toList()
    ..sort((a, b) => b.usage.date.compareTo(a.usage.date));
  return rows;
}

class _InsulinSummaryGrid extends StatelessWidget {
  final double monthTotal;
  final double remaining;
  final int activeBatches;
  final AppColors c;

  const _InsulinSummaryGrid({
    required this.monthTotal,
    required this.remaining,
    required this.activeBatches,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SummaryMetric(
            label: 'Used this month',
            value: '${_fmtNum(monthTotal)} doses',
            icon: Icons.trending_down_rounded,
            c: c,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SummaryMetric(
            label: 'Remaining',
            value: '${_fmtNum(remaining)} units',
            icon: Icons.inventory_2_outlined,
            c: c,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SummaryMetric(
            label: 'Batches',
            value: activeBatches.toString(),
            icon: Icons.medication_liquid_outlined,
            c: c,
          ),
        ),
      ],
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final AppColors c;

  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c.muted),
          const Spacer(),
          Text(label, style: TextStyle(fontSize: 11, color: c.muted)),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: c.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _InsulinReports extends StatelessWidget {
  final List<_UsageRow> rows;
  final String monthKey;
  final AppColors c;

  const _InsulinReports({
    required this.rows,
    required this.monthKey,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _ReportPanel(
        c: c,
        child: Text(
          'No usage in ${monthLabel(monthKey)} yet.',
          style: TextStyle(color: c.muted, fontSize: 13),
        ),
      );
    }

    final byItem = <String, double>{};
    final byDay = <String, double>{};
    for (final row in rows) {
      byItem[row.itemName] = (byItem[row.itemName] ?? 0) + row.usage.units;
      final day = row.usage.date.length >= 10
          ? row.usage.date.substring(0, 10)
          : row.usage.date;
      byDay[day] = (byDay[day] ?? 0) + row.usage.units;
    }
    final itemEntries = byItem.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxItem = itemEntries.fold<double>(
        0, (max, entry) => entry.value > max ? entry.value : max);
    final dayEntries = byDay.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return _ReportPanel(
      c: c,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Daily usage',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: c.ink),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 72,
            child: _UsageBars(
              values: dayEntries.map((entry) => entry.value).toList(),
              color: c.accent,
              muted: c.line,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'By insulin',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: c.ink),
          ),
          const SizedBox(height: 10),
          for (final entry in itemEntries) ...[
            _UsageByItemRow(
              name: entry.key,
              value: entry.value,
              maxValue: maxItem,
              c: c,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ReportPanel extends StatelessWidget {
  final Widget child;
  final AppColors c;

  const _ReportPanel({required this.child, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: child,
    );
  }
}

class _UsageBars extends StatelessWidget {
  final List<double> values;
  final Color color;
  final Color muted;

  const _UsageBars({
    required this.values,
    required this.color,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _UsageBarsPainter(values: values, color: color, muted: muted),
      size: const Size(double.infinity, 72),
    );
  }
}

class _UsageBarsPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final Color muted;

  const _UsageBarsPainter({
    required this.values,
    required this.color,
    required this.muted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final baseline = size.height - 4;
    paint.color = muted;
    canvas.drawLine(Offset(0, baseline), Offset(size.width, baseline), paint);
    if (values.isEmpty) return;

    final maxValue = values.reduce((a, b) => a > b ? a : b);
    const gap = 4.0;
    final width = ((size.width - gap * (values.length - 1)) / values.length)
        .clamp(4.0, 18.0)
        .toDouble();
    final totalWidth = width * values.length + gap * (values.length - 1);
    var x = (size.width - totalWidth) / 2;
    paint.color = color;
    for (final value in values) {
      final height = maxValue <= 0 ? 0.0 : (baseline - 8) * value / maxValue;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, baseline - height, width, height),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, paint);
      x += width + gap;
    }
  }

  @override
  bool shouldRepaint(_UsageBarsPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.color != color ||
      oldDelegate.muted != muted;
}

class _UsageByItemRow extends StatelessWidget {
  final String name;
  final double value;
  final double maxValue;
  final AppColors c;

  const _UsageByItemRow({
    required this.name,
    required this.value,
    required this.maxValue,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final factor = maxValue <= 0 ? 0.0 : value / maxValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(name,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: c.ink)),
            ),
            Text('${_fmtNum(value)} doses',
                style: TextStyle(fontSize: 12, color: c.muted)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: factor,
            minHeight: 7,
            backgroundColor: c.surface2,
            valueColor: AlwaysStoppedAnimation<Color>(c.accent),
          ),
        ),
      ],
    );
  }
}

class _UsageTile extends StatelessWidget {
  final _UsageRow row;
  final AppColors c;
  final VoidCallback? onDelete;

  const _UsageTile({required this.row, required this.c, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: c.surface2, borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.water_drop_outlined, size: 20, color: c.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.itemName,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.ink)),
                const SizedBox(height: 2),
                Text(
                  'Batch ${row.batchNo} · ${_fmtDateTime(row.usage.date)}'
                  '${(row.usage.notes?.isNotEmpty ?? false) ? ' · ${row.usage.notes}' : ''}',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _fmtNum(row.usage.units),
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: c.ink),
          ),
          if (onDelete != null) ...[
            const SizedBox(width: 8),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
              color: c.neg,
              tooltip: 'Delete usage',
            ),
          ],
        ],
      ),
    );
  }
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

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final AppColors c;
  const _StatChip({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: c.muted)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: c.ink)),
        ],
      ),
    );
  }
}

// ── Insulin type sheet ──────────────────────────────────────────────────────
class _InsulinItemSheet extends ConsumerStatefulWidget {
  final Future<void> Function() onSaved;
  final void Function(Object error) onError;
  const _InsulinItemSheet({required this.onSaved, required this.onError});

  @override
  ConsumerState<_InsulinItemSheet> createState() => _InsulinItemSheetState();
}

class _InsulinItemSheetState extends ConsumerState<_InsulinItemSheet> {
  final _nameCtl = TextEditingController();
  final _unitsCtl = TextEditingController();
  final _uomCtl = TextEditingController(text: 'unit');
  final _notesCtl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _unitsCtl.dispose();
    _uomCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    final units = double.tryParse(_unitsCtl.text.replaceAll(',', '.'));
    final uom = _uomCtl.text.trim();
    if (name.isEmpty || units == null || uom.isEmpty) return;

    setState(() => _saving = true);
    try {
      await Repo.instance.createInsulinItem(
        name: name,
        units: units,
        uom: uom,
        notes: _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim(),
      );
      await widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) widget.onError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Text('Add insulin type',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600, color: c.ink)),
              const Spacer(),
              GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Icon(Icons.close, color: c.muted)),
            ]),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtl,
              style: TextStyle(color: c.ink),
              decoration: const InputDecoration(
                  labelText: 'Name', hintText: 'e.g. Lantus'),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _unitsCtl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
                  ],
                  style: TextStyle(color: c.ink),
                  decoration: const InputDecoration(
                      labelText: 'Units', hintText: 'e.g. 100'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _uomCtl,
                  style: TextStyle(color: c.ink),
                  decoration: const InputDecoration(
                      labelText: 'Unit of measure',
                      hintText: 'e.g. unit, ml, IU'),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _notesCtl,
              style: TextStyle(color: c.ink),
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 20),
            Row(children: [
              const Spacer(),
              ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                    backgroundColor: c.ink,
                    foregroundColor: c.bg,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: _saving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: c.bg))
                    : const Text('Save'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ── Insulin batch (assign) sheet ────────────────────────────────────────────
class _InsulinAssignSheet extends ConsumerStatefulWidget {
  final List<InsulinItem> items;
  final Future<void> Function() onSaved;
  final void Function(Object error) onError;
  const _InsulinAssignSheet(
      {required this.items, required this.onSaved, required this.onError});

  @override
  ConsumerState<_InsulinAssignSheet> createState() =>
      _InsulinAssignSheetState();
}

class _InsulinAssignSheetState extends ConsumerState<_InsulinAssignSheet> {
  final _batchCtl = TextEditingController();
  final _notesCtl = TextEditingController();
  late String _itemId = widget.items.first.id;
  bool _saving = false;

  @override
  void dispose() {
    _batchCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final batchNo = _batchCtl.text.trim();
    if (batchNo.isEmpty) return;

    setState(() => _saving = true);
    try {
      await Repo.instance.createInsulinAssign(
        itemId: _itemId,
        batchNo: batchNo,
        notes: _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim(),
      );
      await widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) widget.onError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Text('Add batch',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600, color: c.ink)),
              const Spacer(),
              GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Icon(Icons.close, color: c.muted)),
            ]),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _itemId,
              decoration: const InputDecoration(labelText: 'Insulin type'),
              items: widget.items
                  .map(
                      (i) => DropdownMenuItem(value: i.id, child: Text(i.name)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _itemId = v);
              },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _batchCtl,
              style: TextStyle(color: c.ink),
              decoration: const InputDecoration(
                  labelText: 'Batch number', hintText: 'e.g. B-2026-001'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _notesCtl,
              style: TextStyle(color: c.ink),
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 20),
            Row(children: [
              const Spacer(),
              ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                    backgroundColor: c.ink,
                    foregroundColor: c.bg,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: _saving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: c.bg))
                    : const Text('Save'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _InsulinUsageByItemSheet extends ConsumerStatefulWidget {
  final List<InsulinItem> items;
  final List<InsulinAssign> assigns;
  final Future<void> Function() onSaved;
  final void Function(Object error) onError;

  const _InsulinUsageByItemSheet({
    required this.items,
    required this.assigns,
    required this.onSaved,
    required this.onError,
  });

  @override
  ConsumerState<_InsulinUsageByItemSheet> createState() =>
      _InsulinUsageByItemSheetState();
}

class _InsulinUsageByItemSheetState
    extends ConsumerState<_InsulinUsageByItemSheet> {
  final _unitsCtl = TextEditingController();
  final _notesCtl = TextEditingController();
  late String _itemId;
  String? _assignId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final firstAssign = widget.assigns.isNotEmpty ? widget.assigns.first : null;
    _itemId = firstAssign?.itemId ?? widget.items.first.id;
    _assignId = firstAssign?.id;
  }

  @override
  void dispose() {
    _unitsCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  List<InsulinAssign> get _assignsForItem =>
      widget.assigns.where((assign) => assign.itemId == _itemId).toList();

  void _selectItem(String itemId) {
    final assigns = widget.assigns.where((assign) => assign.itemId == itemId);
    setState(() {
      _itemId = itemId;
      _assignId = assigns.isEmpty ? null : assigns.first.id;
    });
  }

  Future<void> _save() async {
    final units = double.tryParse(_unitsCtl.text.replaceAll(',', '.'));
    final assignId = _assignId;
    if (assignId == null || units == null || units <= 0) return;

    setState(() => _saving = true);
    try {
      await Repo.instance.logInsulinUsage(
        assignId: assignId,
        units: units,
        notes: _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim(),
      );
      await widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) widget.onError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final assigns = _assignsForItem;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Text('Log insulin dose',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600, color: c.ink)),
              const Spacer(),
              GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Icon(Icons.close, color: c.muted)),
            ]),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _itemId,
              decoration: const InputDecoration(labelText: 'Insulin'),
              items: widget.items
                  .map((item) =>
                      DropdownMenuItem(value: item.id, child: Text(item.name)))
                  .toList(),
              onChanged: (value) {
                if (value != null) _selectItem(value);
              },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              key: ValueKey(_itemId),
              initialValue: _assignId,
              decoration: const InputDecoration(labelText: 'Batch'),
              items: assigns
                  .map((assign) => DropdownMenuItem(
                      value: assign.id,
                      child: Text(
                          '${assign.batchNo} · ${_fmtNum(assign.totalUnits)} left')))
                  .toList(),
              onChanged: assigns.isEmpty
                  ? null
                  : (value) => setState(() => _assignId = value),
            ),
            if (assigns.isEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('No batch exists for this insulin yet.',
                    style: TextStyle(color: c.neg, fontSize: 12)),
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _unitsCtl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              style: TextStyle(color: c.ink),
              decoration: const InputDecoration(
                  labelText: 'Dose used', hintText: 'e.g. 10'),
              autofocus: true,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _notesCtl,
              style: TextStyle(color: c.ink),
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 20),
            Row(children: [
              const Spacer(),
              ElevatedButton(
                onPressed: _saving || _assignId == null ? null : _save,
                style: ElevatedButton.styleFrom(
                    backgroundColor: c.ink,
                    foregroundColor: c.bg,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: _saving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: c.bg))
                    : const Text('Save'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ── Log insulin usage sheet ─────────────────────────────────────────────────
class _InsulinUsageSheet extends ConsumerStatefulWidget {
  final InsulinAssign assign;
  final Future<void> Function() onSaved;
  final void Function(Object error) onError;
  const _InsulinUsageSheet(
      {required this.assign, required this.onSaved, required this.onError});

  @override
  ConsumerState<_InsulinUsageSheet> createState() => _InsulinUsageSheetState();
}

class _InsulinUsageSheetState extends ConsumerState<_InsulinUsageSheet> {
  final _unitsCtl = TextEditingController();
  final _notesCtl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _unitsCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final units = double.tryParse(_unitsCtl.text.replaceAll(',', '.'));
    if (units == null || units <= 0) return;

    setState(() => _saving = true);
    try {
      await Repo.instance.logInsulinUsage(
        assignId: widget.assign.id,
        units: units,
        notes: _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim(),
      );
      await widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) widget.onError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Text(
                'Log usage · ${widget.assign.itemName.isNotEmpty ? widget.assign.itemName : 'Batch ${widget.assign.batchNo}'}',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600, color: c.ink),
              ),
              const Spacer(),
              GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Icon(Icons.close, color: c.muted)),
            ]),
            const SizedBox(height: 16),
            TextField(
              controller: _unitsCtl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              style: TextStyle(color: c.ink),
              decoration: const InputDecoration(
                  labelText: 'Dose used', hintText: 'e.g. 10'),
              autofocus: true,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _notesCtl,
              style: TextStyle(color: c.ink),
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 20),
            Row(children: [
              const Spacer(),
              ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                    backgroundColor: c.ink,
                    foregroundColor: c.bg,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: _saving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: c.bg))
                    : const Text('Save'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
