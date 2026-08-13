import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/receipt_scanner.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/source_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Error: $e', style: TextStyle(color: c.neg)),
        ),
      ),
      data: (data) {
        final balances = computeBalances(data.transactions);
        final sourceBalances = data.sources
            .map((source) => _SourceBalance(
                  source: source,
                  balance: balances[source.name] ?? 0,
                ))
            .toList()
          ..sort((a, b) => b.balance.compareTo(a.balance));
        final totalLiquid = sourceBalances.fold<double>(
          0,
          (sum, item) => sum + item.balance,
        );
        // Holdings are valued at their last known unit price, which falls back
        // to the buy price until the first refresh lands - see [Investment].
        final totalInvestment = data.investments.fold<double>(
          0,
          (sum, item) => sum + item.currentValue,
        );
        final netWorth = totalLiquid + totalInvestment;
        final visibleSources = sourceBalances.take(6).toList();
        final latestBloodSugar = [...data.bloodSugarLogs]
          ..sort((a, b) => b.measuredAt.compareTo(a.measuredAt));
        final latestInsulinUsage = [...data.insulinUsages]
          ..sort((a, b) => b.date.compareTo(a.date));

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          children: [
            const SizedBox(height: 14),
            Text(
              'Home',
              style: TextStyle(
                color: c.ink,
                fontSize: 28,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _NetWorthPanel(
              netWorth: netWorth,
              sourceCount: data.sources.length,
              holdingCount: data.investments.length,
              currency: cfg.currency,
              c: c,
            ),
            const SizedBox(height: 10),
            // The two halves of the figure above, each opening the page that
            // owns it.
            Row(
              children: [
                Expanded(
                  child: _BreakdownTile(
                    icon: Icons.account_balance_wallet_outlined,
                    label: 'Liquid',
                    value: fmtRp(totalLiquid, cfg.currency),
                    hint: '${data.sources.length} '
                        'source${data.sources.length == 1 ? '' : 's'}',
                    negative: totalLiquid < 0,
                    onTap: () => context.go('/dashboard'),
                    c: c,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _BreakdownTile(
                    icon: Icons.trending_up_rounded,
                    label: 'Investment',
                    value: fmtRp(totalInvestment, cfg.currency),
                    hint: '${data.investments.length} '
                        'holding${data.investments.length == 1 ? '' : 's'}',
                    negative: false,
                    onTap: () => context.go('/investments'),
                    c: c,
                  ),
                ),
              ],
            ),
            // The whole Health block disappears when the Diabetic extra
            // feature is switched off in Settings.
            if (cfg.healthEnabled) ...[
              const SizedBox(height: 18),
              _SectionHeader(
                title: 'Health',
                action: 'Diabetic',
                onAction: () => context.go('/insulin'),
                c: c,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _HealthStat(
                      icon: Icons.water_drop_outlined,
                      label: 'Blood sugar',
                      value: latestBloodSugar.isEmpty
                          ? 'No logs'
                          : '${latestBloodSugar.first.level.round()} ${latestBloodSugar.first.unit}',
                      c: c,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _HealthStat(
                      icon: Icons.vaccines_outlined,
                      label: 'Insulin usage',
                      value: latestInsulinUsage.isEmpty
                          ? 'No logs'
                          : '${_formatNumber(latestInsulinUsage.first.units)} units',
                      c: c,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            Text(
              'Add',
              style: TextStyle(
                color: c.ink,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            _QuickActions(c: c, healthEnabled: cfg.healthEnabled),
            const SizedBox(height: 20),
            _SectionHeader(
              title: 'Sources',
              action: 'Finance',
              onAction: () => context.go('/dashboard'),
              c: c,
            ),
            const SizedBox(height: 10),
            if (visibleSources.isEmpty)
              _EmptyPanel(c: c, text: 'No finance sources yet.')
            else
              ...visibleSources.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SourceCard(
                    source: item.source,
                    balance: item.balance,
                    currency: cfg.currency,
                    onTap: () => context.push(
                      '/source/${Uri.encodeComponent(item.source.name)}',
                    ),
                  ),
                ),
              ),
            if (sourceBalances.length > visibleSources.length)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.go('/dashboard'),
                  child: Text(
                    'View all sources',
                    style: TextStyle(color: c.accent),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

String _formatNumber(double value) {
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toStringAsFixed(1);
}

class _SourceBalance {
  final Source source;
  final double balance;

  const _SourceBalance({required this.source, required this.balance});
}

/// Everything owned: liquid source balances plus what the investments are
/// currently worth. The two halves are broken out underneath by
/// [_BreakdownTile], since they behave very differently.
class _NetWorthPanel extends StatelessWidget {
  final double netWorth;
  final int sourceCount;
  final int holdingCount;
  final String currency;
  final AppColors c;

  const _NetWorthPanel({
    required this.netWorth,
    required this.sourceCount,
    required this.holdingCount,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final positive = netWorth >= 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.savings_outlined, color: c.accent),
              const SizedBox(width: 8),
              Text(
                'Net worth',
                style: TextStyle(
                  color: c.muted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            fmtRp(netWorth, currency),
            style: TextStyle(
              color: positive ? c.ink : c.neg,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$sourceCount source${sourceCount == 1 ? '' : 's'} + '
            '$holdingCount investment${holdingCount == 1 ? '' : 's'}',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// One half of the net worth figure, opening the page that owns it.
class _BreakdownTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String hint;

  /// Only liquid can realistically go negative, and it should read as a
  /// warning when it does.
  final bool negative;
  final VoidCallback onTap;
  final AppColors c;

  const _BreakdownTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.hint,
    required this.negative,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: c.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 16, color: c.muted),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: negative ? c.neg : c.ink,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            Text(hint, style: TextStyle(color: c.muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  final AppColors c;

  /// Drops the two insulin shortcuts when the Diabetic extra feature is off.
  final bool healthEnabled;

  const _QuickActions({required this.c, required this.healthEnabled});

  @override
  Widget build(BuildContext context) {
    final actions = [
      _ActionSpec(
        icon: Icons.add_card_outlined,
        label: 'Transaction',
        onTap: () => context.push(_returnHomeRoute('/add')),
      ),
      // Photograph a price list, confirm the recognised rows, then land on the
      // Add-transaction screen with the breakdown filled in.
      if (ReceiptScanner.isSupported)
        _ActionSpec(
          icon: Icons.document_scanner_outlined,
          label: 'Scan receipt',
          onTap: () => context.push(_returnHomeRoute('/scan-receipt')),
        ),
      if (healthEnabled) ...[
        _ActionSpec(
          icon: Icons.vaccines_outlined,
          label: 'Insulin usage',
          onTap: () => context.push(_returnHomeRoute('/insulin/add-usage')),
        ),
        _ActionSpec(
          icon: Icons.bloodtype_outlined,
          label: 'Blood sugar',
          onTap: () =>
              context.push(_returnHomeRoute('/insulin/add-blood-sugar')),
        ),
      ],
    ];

    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: _ActionButton(action: actions[i], c: c)),
        ],
      ],
    );
  }
}

String _returnHomeRoute(String path) {
  return Uri(path: path, queryParameters: {'returnTo': '/'}).toString();
}

class _ActionSpec {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionSpec({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class _ActionButton extends StatelessWidget {
  final _ActionSpec action;
  final AppColors c;

  const _ActionButton({required this.action, required this.c});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: FilledButton(
        onPressed: action.onTap,
        style: FilledButton.styleFrom(
          backgroundColor: c.ink,
          foregroundColor: c.bg,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(action.icon, size: 20),
            const SizedBox(height: 6),
            Text(
              action.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, height: 1.1),
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final AppColors c;

  const _HealthStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 86,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, color: c.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
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
  final AppColors c;

  const _SectionHeader({
    required this.title,
    required this.action,
    required this.onAction,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            color: c.ink,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        TextButton(
          onPressed: onAction,
          child: Text(action, style: TextStyle(color: c.accent)),
        ),
      ],
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  final AppColors c;
  final String text;

  const _EmptyPanel({required this.c, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Text(text, style: TextStyle(color: c.muted)),
    );
  }
}
