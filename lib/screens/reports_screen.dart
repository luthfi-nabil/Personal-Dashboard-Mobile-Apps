import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import '../core/models.dart';
import '../core/repo.dart';
import '../core/utils.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';
import 'dart:math' show max;

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  String _ym = DateTime.now().toIso8601String().substring(0, 7);
  late Future<List<DailyActivity>> _activitiesFuture;

  @override
  void initState() {
    super.initState();
    _activitiesFuture = _loadActivities(_ym);
  }

  Future<List<DailyActivity>> _loadActivities(String ym) {
    final parts = ym.split('-');
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final start = DateTime(year, month, 1);
    final end = DateTime(year, month + 1, 0); // last day of month
    return Repo.instance.getDailyActivitiesBetween(start, end);
  }

  void _changeMonth(String ym) {
    setState(() {
      _ym = ym;
      _activitiesFuture = _loadActivities(ym);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) {
        final totals = monthTotals(data.transactions, _ym);
        final cats = spendByCategory(data.transactions, _ym);
        final flow = cashflowByMonth(data.transactions);
        final plannedByCategory = _plannedByCategory(data.wishlistItems);
        final plannedSpendingTotal = plannedByCategory
            .where((entry) => entry.type == 'spending')
            .fold<double>(0, (sum, entry) => sum + entry.amount);
        final plannedEarningTotal = plannedByCategory
            .where((entry) => entry.type == 'earning')
            .fold<double>(0, (sum, entry) => sum + entry.amount);
        final top = cats.take(6).toList();
        final otherAmt = cats.skip(6).fold<double>(0, (s, c) => s + c.amount);
        final chartData = otherAmt > 0
            ? [
                ...top,
                (
                  name: 'Other',
                  amount: otherAmt,
                  color: const Color(0xFFA09C8E)
                )
              ]
            : top;

        // Top merchants
        final merch = <String, ({int count, double total})>{};
        for (final t in data.transactions) {
          if (t.type != 'spending' || isoMonth(t.date) != _ym) continue;
          final k = t.description.trim().isEmpty ? '—' : t.description.trim();
          final prev = merch[k] ?? (count: 0, total: 0.0);
          merch[k] = (count: prev.count + 1, total: prev.total + t.amount);
        }
        final topMerch = merch.entries.toList()
          ..sort((a, b) => b.value.total.compareTo(a.value.total));
        final top5 = topMerch.take(5).toList();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text('Reports',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: c.ink,
                          letterSpacing: -0.02)),
                ),
                TextButton.icon(
                  onPressed: () => context.push('/export'),
                  icon: Icon(Icons.file_download_outlined,
                      size: 18, color: c.accent),
                  label: Text('Export',
                      style: TextStyle(
                          color: c.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Month picker
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _IconBtn(
                    icon: Icons.arrow_back_ios_rounded,
                    onTap: () => _changeMonth(prevMonth(_ym)),
                    c: c),
                const SizedBox(width: 10),
                SizedBox(
                  width: 130,
                  child: Text(
                    '${monthLabel(_ym)} ${_ym.substring(0, 4)}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: c.ink),
                  ),
                ),
                const SizedBox(width: 10),
                _IconBtn(
                    icon: Icons.arrow_forward_ios_rounded,
                    onTap: () => _changeMonth(nextMonth(_ym)),
                    c: c),
              ],
            ),
            const SizedBox(height: 14),

            // KPIs
            Row(
              children: [
                Expanded(
                    child: _KpiTile(
                        label: 'In',
                        value: fmtRp(totals.earn, cfg.currency),
                        color: c.pos,
                        c: c)),
                const SizedBox(width: 8),
                Expanded(
                    child: _KpiTile(
                        label: 'Out',
                        value: fmtRp(totals.spend, cfg.currency),
                        color: c.neg,
                        c: c)),
                const SizedBox(width: 8),
                Expanded(
                    child: _KpiTile(
                        label: 'Net',
                        value: fmtRp(totals.net, cfg.currency),
                        color: totals.net >= 0 ? c.pos : c.neg,
                        c: c)),
              ],
            ),
            const SizedBox(height: 18),

            Text('Planned by category',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.muted,
                    letterSpacing: 0.06)),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.line2, width: 0.5),
              ),
              clipBehavior: Clip.hardEdge,
              child: plannedByCategory.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                          child: Text('No active planned expenses',
                              style: TextStyle(color: c.muted, fontSize: 13))))
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                    'Out ${fmtRp(plannedSpendingTotal, cfg.currency)}',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: c.neg)),
                              ),
                              Text(
                                  'In ${fmtRp(plannedEarningTotal, cfg.currency)}',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: c.pos)),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: c.line2),
                        ...plannedByCategory.map((entry) => Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                          color: entry.color,
                                          borderRadius:
                                              BorderRadius.circular(3))),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(entry.name,
                                          style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: c.ink)),
                                      Text('${entry.count} ${entry.type}',
                                          style: TextStyle(
                                              fontSize: 11, color: c.muted)),
                                    ],
                                  )),
                                  Text(fmtRp(entry.amount, cfg.currency),
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                          color: entry.type == 'earning'
                                              ? c.pos
                                              : c.neg,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures()
                                          ])),
                                ],
                              ),
                            )),
                      ],
                    ),
            ),
            const SizedBox(height: 18),

            // Donut chart
            Text('Spending by category',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.muted,
                    letterSpacing: 0.06)),
            const SizedBox(height: 12),
            if (chartData.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: c.line2, width: 0.5)),
                child: Center(
                    child: Text('No spending this month',
                        style: TextStyle(color: c.muted, fontSize: 13))),
              )
            else ...[
              SizedBox(
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(PieChartData(
                      sections: chartData
                          .map((cat) => PieChartSectionData(
                                value: cat.amount,
                                color: cat.color,
                                radius: 40,
                                showTitle: false,
                              ))
                          .toList(),
                      centerSpaceRadius: 70,
                      sectionsSpace: 1,
                    )),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Total',
                            style: TextStyle(
                                fontSize: 11,
                                color: c.muted,
                                letterSpacing: 0.05,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(height: 2),
                        Text(fmtRp(totals.spend, cfg.currency),
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: c.ink,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.line2, width: 0.5),
                ),
                padding: const EdgeInsets.all(4),
                child: Column(
                  children: chartData
                      .map((cat) => GestureDetector(
                            onTap: () => context.push(
                                '/category/${Uri.encodeComponent(cat.name)}'),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 10),
                              child: Row(
                                children: [
                                  Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                          color: cat.color,
                                          borderRadius:
                                              BorderRadius.circular(3))),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(cat.name,
                                          style: TextStyle(
                                              fontSize: 14, color: c.ink))),
                                  Text(fmtRp(cat.amount, cfg.currency),
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                          color: c.ink,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures()
                                          ])),
                                ],
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ),
            ],
            const SizedBox(height: 18),

            // Cashflow bars
            Text('Cashflow · last months',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.muted,
                    letterSpacing: 0.06)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.line2, width: 0.5),
              ),
              child: flow.isEmpty
                  ? Center(
                      child: Text('No data', style: TextStyle(color: c.muted)))
                  : _CashflowChart(
                      flow: flow.length > 6
                          ? flow.sublist(flow.length - 6)
                          : flow,
                      c: c),
            ),
            const SizedBox(height: 6),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LegendDot(color: Color(0xFF1F8A4C), label: 'In'),
                SizedBox(width: 14),
                _LegendDot(color: Color(0xFFC43A2B), label: 'Out'),
              ],
            ),
            const SizedBox(height: 18),

            // Top merchants
            Text('Top merchants · ${monthLabel(_ym)}',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.muted,
                    letterSpacing: 0.06)),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.line2, width: 0.5),
              ),
              clipBehavior: Clip.hardEdge,
              child: top5.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                          child: Text('No spending this month',
                              style: TextStyle(color: c.muted, fontSize: 13))))
                  : Column(
                      children: List.generate(top5.length, (i) {
                        final entry = top5[i];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border(
                                bottom: BorderSide(color: c.line2, width: 0.5)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                    color: c.surface2,
                                    borderRadius: BorderRadius.circular(8)),
                                child: Center(
                                    child: Text('${i + 1}',
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: c.muted))),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(entry.key,
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: c.ink)),
                                    Text('${entry.value.count}×',
                                        style: TextStyle(
                                            fontSize: 11, color: c.muted)),
                                  ],
                                ),
                              ),
                              Text(fmtRp(entry.value.total, cfg.currency),
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                      color: c.ink,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures()
                                      ])),
                            ],
                          ),
                        );
                      }),
                    ),
            ),
            const SizedBox(height: 18),

            // Activities by category
            Text('Activities by category · ${monthLabel(_ym)}',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.muted,
                    letterSpacing: 0.06)),
            const SizedBox(height: 12),
            FutureBuilder<List<DailyActivity>>(
              future: _activitiesFuture,
              builder: (context, actSnap) {
                if (actSnap.connectionState != ConnectionState.done) {
                  return Center(
                      child: CircularProgressIndicator(color: c.accent));
                }
                final activities = actSnap.data ?? [];
                if (activities.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.line2, width: 0.5)),
                    child: Center(
                        child: Text('No activities this month',
                            style: TextStyle(color: c.muted, fontSize: 13))),
                  );
                }

                final byCategory = <String, int>{};
                final uncategorized = <String>[];
                for (final a in activities) {
                  if (a.category.isEmpty) {
                    uncategorized.add(a.title);
                  } else {
                    byCategory.update(a.category, (v) => v + 1,
                        ifAbsent: () => 1);
                  }
                }
                if (uncategorized.isNotEmpty) {
                  byCategory['Uncategorized'] = uncategorized.length;
                }
                final sorted = byCategory.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value));
                final total = activities.length;

                return Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.line2, width: 0.5),
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            Text('$total done',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: c.ink)),
                            const Spacer(),
                            Text(
                                '${sorted.length} categor${sorted.length == 1 ? 'y' : 'ies'}',
                                style: TextStyle(fontSize: 12, color: c.muted)),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: c.line2),
                      ...sorted.map((entry) {
                        final ratio = total == 0 ? 0.0 : entry.value / total;
                        final color = entry.key == 'Uncategorized'
                            ? c.muted
                            : _activityCategoryColor(entry.key);
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: color,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      entry.key,
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: c.ink),
                                    ),
                                  ),
                                  Text(
                                    '${entry.value}',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: c.ink),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 36,
                                    child: Text(
                                      '${(ratio * 100).round()}%',
                                      textAlign: TextAlign.right,
                                      style: TextStyle(
                                          fontSize: 12, color: c.muted),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  minHeight: 5,
                                  value: ratio,
                                  backgroundColor: c.line2,
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(color),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

Color _activityCategoryColor(String category) {
  const palette = [
    Color(0xFF2196F3),
    Color(0xFF4CAF50),
    Color(0xFFFF9800),
    Color(0xFF9C27B0),
    Color(0xFFE91E63),
    Color(0xFF00BCD4),
    Color(0xFF795548),
    Color(0xFF607D8B),
    Color(0xFFFF5722),
    Color(0xFF009688),
  ];
  final hash = category.codeUnits.fold(0, (sum, c) => sum + c);
  return palette[hash % palette.length];
}

List<({String name, String type, int count, double amount, Color color})>
    _plannedByCategory(List<WishlistItem> items) {
  final totals =
      <String, ({String name, String type, int count, double amount})>{};
  for (final item in items.where((item) => item.status == 'active')) {
    final type = item.transactionType == 'earning' ? 'earning' : 'spending';
    final name = (item.categoryName ?? '').trim().isEmpty
        ? 'Uncategorized'
        : item.categoryName!.trim();
    final key = '$type::$name';
    final prev = totals[key] ?? (name: name, type: type, count: 0, amount: 0.0);
    totals[key] = (
      name: prev.name,
      type: prev.type,
      count: prev.count + 1,
      amount: prev.amount + item.price,
    );
  }
  final rows = totals.values
      .map((entry) => (
            name: entry.name,
            type: entry.type,
            count: entry.count,
            amount: entry.amount,
            color: _activityCategoryColor('${entry.type}:${entry.name}'),
          ))
      .toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));
  return rows;
}

class _KpiTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final AppColors c;
  const _KpiTile(
      {required this.label,
      required this.value,
      required this.color,
      required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: c.muted)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _CashflowChart extends StatelessWidget {
  final List<({String key, double earn, double spend, double net})> flow;
  final AppColors c;
  const _CashflowChart({required this.flow, required this.c});

  @override
  Widget build(BuildContext context) {
    final maxVal = flow.fold<double>(0, (m, f) => max(m, max(f.earn, f.spend)));

    return SizedBox(
      height: 160,
      child: BarChart(
        BarChartData(
          maxY: maxVal * 1.15,
          barTouchData: BarTouchData(enabled: false),
          titlesData: FlTitlesData(
            leftTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= flow.length) return const SizedBox.shrink();
                  final month = monthLabel(flow[i].key);
                  return Text(month,
                      style: TextStyle(fontSize: 9, color: c.muted));
                },
                reservedSize: 18,
              ),
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: c.line, strokeWidth: 0.5),
          ),
          borderData: FlBorderData(show: false),
          barGroups: List.generate(flow.length, (i) {
            final f = flow[i];
            return BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                    toY: f.earn,
                    color: const Color(0xFF1F8A4C),
                    width: 8,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(3))),
                BarChartRodData(
                    toY: f.spend,
                    color: const Color(0xFFC43A2B),
                    width: 8,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(3))),
              ],
              barsSpace: 2,
            );
          }),
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Row(
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final AppColors c;
  const _IconBtn({required this.icon, required this.onTap, required this.c});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
            color: c.surface, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 16, color: c.ink),
      ),
    );
  }
}
