import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/utils.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';
import '../widgets/txn_tile.dart';
import '../widgets/source_card.dart';
import 'dart:ui' show FontFeature;

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String _ym = DateTime.now().toIso8601String().substring(0, 7);

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) {
        final bal = computeBalances(data.transactions);
        final totalNet = data.sources.fold<double>(0, (s, src) => s + (bal[src.name] ?? 0));
        final totals = monthTotals(data.transactions, _ym);
        final series = liquidSeries(data.transactions);
        final recent = data.transactions.take(5).toList();

        return ListView(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const SizedBox(height: 14),
            // Hero card
            _HeroCard(
              totalNet: totalNet,
              totals: totals,
              series: series,
              ym: _ym,
              currency: cfg.currency,
              c: c,
            ),
            const SizedBox(height: 18),

            // Sources
            _SectionHeader(
              title: 'Sources',
              action: 'Manage',
              onAction: () => context.go('/settings'),
            ),
            const SizedBox(height: 10),
            if (data.sources.isEmpty)
              _Empty('No sources yet', c)
            else
              ...data.sources.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SourceCard(
                      source: s,
                      balance: bal[s.name],
                      currency: cfg.currency,
                      onTap: () => context.push('/source/${Uri.encodeComponent(s.name)}'),
                    ),
                  )),
            const SizedBox(height: 18),

            // Recent activity
            _SectionHeader(
              title: 'Recent activity',
              action: 'View all',
              onAction: () => context.go('/transactions'),
            ),
            const SizedBox(height: 10),
            if (recent.isEmpty)
              _Empty('No transactions yet', c)
            else
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: c.line2, width: 0.5),
                ),
                clipBehavior: Clip.hardEdge,
                child: Column(
                  children: recent
                      .map((t) => TxnTile(
                            t: t,
                            currency: cfg.currency,
                            onTap: () => context.push('/add/${t.id}'),
                          ))
                      .toList(),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _HeroCard extends StatelessWidget {
  final double totalNet;
  final ({double earn, double spend, double net}) totals;
  final List<double> series;
  final String ym;
  final String currency;
  final AppColors c;
  const _HeroCard({required this.totalNet, required this.totals, required this.series, required this.ym, required this.currency, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Liquid', style: TextStyle(fontSize: 13, color: c.muted)),
          const SizedBox(height: 4),
          Text(
            fmtRp(totalNet, currency),
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.02,
              color: totalNet < 0 ? c.neg : c.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(height: 64, child: _SparkLine(series: series, color: c.accent)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _KpiCard(label: 'In · ${monthLabel(ym)}', value: fmtRp(totals.earn, currency), positive: true, c: c)),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(label: 'Out · ${monthLabel(ym)}', value: fmtRp(totals.spend, currency), positive: false, c: c)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SparkLine extends StatelessWidget {
  final List<double> series;
  final Color color;
  const _SparkLine({required this.series, required this.color});

  @override
  Widget build(BuildContext context) {
    if (series.length < 2) return const SizedBox.shrink();
    return CustomPaint(
      painter: _SparkPainter(series: series, color: color),
      size: const Size(double.infinity, 64),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> series;
  final Color color;
  const _SparkPainter({required this.series, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2) return;
    final minV = series.reduce((a, b) => a < b ? a : b);
    final maxV = series.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs();
    if (range == 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (int i = 0; i < series.length; i++) {
      final x = size.width * i / (series.length - 1);
      final y = size.height - size.height * (series[i] - minV) / range;
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.series != series;
}

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final bool positive;
  final AppColors c;
  const _KpiCard({required this.label, required this.value, required this.positive, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(positive ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                size: 14, color: c.muted),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: c.muted,
                letterSpacing: 0.05, fontWeight: FontWeight.w500)),
          ]),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: positive ? c.pos : c.neg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String action;
  final VoidCallback onAction;
  const _SectionHeader({required this.title, required this.action, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Row(
      children: [
        Text(title,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                color: c.muted, letterSpacing: 0.06)),
        const Spacer(),
        GestureDetector(
          onTap: onAction,
          child: Text(action, style: TextStyle(fontSize: 13, color: c.accent, fontWeight: FontWeight.w500)),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  final AppColors c;
  const _Empty(this.text, this.c);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, style: TextStyle(fontSize: 13, color: c.muted)),
      ),
    );
  }
}
