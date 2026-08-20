import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

class PlannedExpenseScreen extends ConsumerStatefulWidget {
  const PlannedExpenseScreen({super.key});

  @override
  ConsumerState<PlannedExpenseScreen> createState() => _PlannedExpenseScreenState();
}

class _PlannedExpenseScreenState extends ConsumerState<PlannedExpenseScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) => _tab == 0
          ? _buildListView(context, data, cfg, c)
          : _buildCategoryView(context, data, cfg, c),
    );
  }

  List<Widget> _pageHeader(
      BuildContext context, AppData data, AppConfig cfg, AppColors c) {
    return [
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: Text('Planned Expenses',
                style: TextStyle(
                    fontSize: 28, fontWeight: FontWeight.w700, color: c.ink)),
          ),
          if (_tab == 0)
            TextButton.icon(
              onPressed: () => _openPlannedExpenseEditor(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add'),
            ),
          if (_tab == 1)
            TextButton.icon(
              onPressed: () => _openCategoryEditor(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Category'),
            ),
        ],
      ),
      const SizedBox(height: 10),
      _TabSwitcher(tab: _tab, onSelect: (t) => setState(() => _tab = t), c: c),
      const SizedBox(height: 16),
    ];
  }

  Widget _buildListView(
      BuildContext context, AppData data, AppConfig cfg, AppColors c) {
    final active =
        data.plannedExpenseItems.where((item) => item.status == 'active').toList();
    final history =
        data.plannedExpenseItems.where((item) => item.status != 'active').toList();
    final fulfilled = data.plannedExpenseItems
        .where((item) => item.status == 'fulfilled')
        .toList()
      ..sort((a, b) => (b.fulfilledAt ?? '').compareTo(a.fulfilledAt ?? ''));
    final plannedTotal =
        active.fold<double>(0, (sum, item) => sum + item.price);
    final plannedSpendingTotal = active
        .where((item) => item.transactionType != 'earning')
        .fold<double>(0, (sum, item) => sum + item.price);
    final plannedEarningTotal = active
        .where((item) => item.transactionType == 'earning')
        .fold<double>(0, (sum, item) => sum + item.price);
    final fulfilledTotal = fulfilled.fold<double>(
        0, (sum, item) => sum + (item.fulfilledPrice ?? item.price));
    final highPriority = active.where((item) => item.priority == 'high').length;
    final avgFulfilled =
        fulfilled.isEmpty ? 0.0 : fulfilledTotal / fulfilled.length;
    final prioritySummary = _prioritySummary(active);
    final categorySummary = _categorySummary(active, cfg.currency);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        ..._pageHeader(context, data, cfg, c),
        _PlannedExpenseReports(
          plannedTotal: plannedTotal,
          plannedSpendingTotal: plannedSpendingTotal,
          plannedEarningTotal: plannedEarningTotal,
          fulfilledTotal: fulfilledTotal,
          highPriority: highPriority,
          activeCount: active.length,
          averageFulfilled: avgFulfilled,
          latestBought: fulfilled.isEmpty ? null : fulfilled.first,
          prioritySummary: prioritySummary,
          categorySummary: categorySummary,
          currency: cfg.currency,
          c: c,
        ),
        const SizedBox(height: 20),
        _SectionTitle('Planned (${active.length})', c),
        const SizedBox(height: 10),
        if (active.isEmpty)
          _EmptyPanel(c: c, text: 'No planned expenses yet.')
        else
          ...active.map((item) => _PlannedExpenseCard(
                item: item,
                currency: cfg.currency,
                c: c,
                onFulfill: () => _openFulfillDialog(context, item, data),
                onPartialPayment: () => _openFulfillDialog(
                  context,
                  item,
                  data,
                  partialPayment: true,
                ),
                onCancel: () => _cancel(context, item),
                onRemove: () => _remove(context, item),
              )),
        const SizedBox(height: 20),
        _SectionTitle('History (${history.length})', c),
        const SizedBox(height: 10),
        if (history.isEmpty)
          _EmptyPanel(c: c, text: 'Fulfilled and canceled plans appear here.')
        else
          ...history.map((item) => _PlannedExpenseCard(
                item: item,
                currency: cfg.currency,
                c: c,
                onFulfill: null,
                onPartialPayment: null,
                onCancel: null,
                onRemove: () => _remove(context, item),
              )),
      ],
    );
  }

  Widget _buildCategoryView(
      BuildContext context, AppData data, AppConfig cfg, AppColors c) {
    final plannedCats =
        data.categories.where((cat) => cat.kind == 'planned_expense').toList();
    final active =
        data.plannedExpenseItems.where((item) => item.status == 'active').toList();

    final catTotals = <String,
        ({double total, double spending, double earning, int count})>{};
    for (final item in active) {
      final catName = (item.categoryName ?? '').trim().isEmpty
          ? 'Uncategorized'
          : item.categoryName!.trim();
      final prev = catTotals[catName];
      final isEarning = item.transactionType == 'earning';
      catTotals[catName] = (
        total: (prev?.total ?? 0) + item.price,
        spending: (prev?.spending ?? 0) + (isEarning ? 0 : item.price),
        earning: (prev?.earning ?? 0) + (isEarning ? item.price : 0),
        count: (prev?.count ?? 0) + 1,
      );
    }
    final catEntries = catTotals.entries.toList()
      ..sort((a, b) => b.value.total.compareTo(a.value.total));

    final totalPlanned = active.fold<double>(0, (s, i) => s + i.price);
    final totalSpending = active
        .where((i) => i.transactionType != 'earning')
        .fold<double>(0, (s, i) => s + i.price);
    final totalEarning = active
        .where((i) => i.transactionType == 'earning')
        .fold<double>(0, (s, i) => s + i.price);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        ..._pageHeader(context, data, cfg, c),
        _SectionTitle('Reports', c),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                label: 'Total planned',
                value: fmtRp(totalPlanned, cfg.currency),
                color: c.ink,
                c: c,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'Categories',
                value: plannedCats.length.toString(),
                color: c.ink,
                c: c,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                label: 'Planned spending',
                value: fmtRp(totalSpending, cfg.currency),
                color: c.neg,
                c: c,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'Planned earning',
                value: fmtRp(totalEarning, cfg.currency),
                color: c.pos,
                c: c,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle('By category (${catEntries.length})', c),
        const SizedBox(height: 10),
        if (catEntries.isEmpty)
          _EmptyPanel(c: c, text: 'No active planned expenses.')
        else
          ...catEntries.map((entry) => _CategoryValueCard(
                name: entry.key,
                total: entry.value.total,
                spending: entry.value.spending,
                earning: entry.value.earning,
                count: entry.value.count,
                currency: cfg.currency,
                c: c,
              )),
        const SizedBox(height: 20),
        _SectionTitle('Manage categories (${plannedCats.length})', c),
        const SizedBox(height: 10),
        if (plannedCats.isEmpty)
          _EmptyPanel(
              c: c,
              text:
                  'No planned expense categories yet. Tap "+ Category" to add one.')
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: plannedCats.map((cat) {
              final color = catColor(cat.name);
              return GestureDetector(
                onTap: () => _openCategoryEditor(context, category: cat),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: c.line2, width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration:
                            BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(cat.name,
                          style: TextStyle(fontSize: 13, color: c.ink)),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Future<void> _cancel(BuildContext context, PlannedExpenseItem item) async {
    await Repo.instance.cancelPlannedExpenseItem(item);
    await ref.read(appDataProvider.notifier).refresh();
  }

  Future<void> _remove(BuildContext context, PlannedExpenseItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove planned expense?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await Repo.instance.removePlannedExpenseItem(item);
    await ref.read(appDataProvider.notifier).refresh();
  }

  void _openPlannedExpenseEditor(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.colorsOf(context).bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlannedExpenseEditorSheet(onSaved: () async {
        await ref.read(appDataProvider.notifier).refresh();
      }),
    );
  }

  void _openCategoryEditor(BuildContext context, {Category? category}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.colorsOf(context).bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlannedCategoryEditorSheet(
        category: category,
        onSaved: () async {
          await ref.read(appDataProvider.notifier).refresh();
        },
      ),
    );
  }

  Future<void> _openFulfillDialog(
    BuildContext context,
    PlannedExpenseItem item,
    AppData data, {
    bool partialPayment = false,
  }) async {
    final defaultPrice = partialPayment ? item.price / 2 : item.price;
    final defaultPriceText = defaultPrice == defaultPrice.roundToDouble()
        ? defaultPrice.toStringAsFixed(0)
        : defaultPrice.toStringAsFixed(2);
    final priceCtl = TextEditingController(
      text: partialPayment ? defaultPriceText : '',
    );
    String sourceName = '';
    String categoryId = '';
    final categoryKind =
        item.transactionType == 'earning' ? 'earning' : 'spending';
    final financeCategories =
        data.categories.where((cat) => cat.kind == categoryKind).toList();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(
              partialPayment ? 'Partial payment' : 'Fulfill planned expense',
              style: TextStyle(
                  color: AppTheme.colorsOf(ctx).ink,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: priceCtl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
                  ],
                  decoration: InputDecoration(
                    labelText:
                        partialPayment ? 'Payment amount' : 'Final price',
                    hintText: defaultPriceText,
                  ),
                  style: TextStyle(color: AppTheme.colorsOf(ctx).ink),
                  validator: (v) {
                    final price =
                        double.tryParse((v ?? '').replaceAll(',', '.')) ??
                            item.price;
                    if (price <= 0) return 'Must be greater than zero';
                    if (partialPayment && price >= item.price) {
                      return 'Must be less than planned amount';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: sourceName.isEmpty ? null : sourceName,
                  decoration: const InputDecoration(labelText: 'Source'),
                  items: data.sources
                      .map((s) =>
                          DropdownMenuItem(value: s.name, child: Text(s.name)))
                      .toList(),
                  onChanged: (v) => setS(() => sourceName = v ?? ''),
                  validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: categoryId.isEmpty ? null : categoryId,
                  decoration: InputDecoration(
                      labelText:
                          '${categoryKind[0].toUpperCase()}${categoryKind.substring(1)} finance category'),
                  items: financeCategories
                      .map((cat) => DropdownMenuItem(
                          value: cat.id, child: Text(cat.name)))
                      .toList(),
                  onChanged: (v) => setS(() => categoryId = v ?? ''),
                  validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: Text(partialPayment ? 'Pay' : 'Submit'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    final price =
        double.tryParse(priceCtl.text.replaceAll(',', '.')) ?? item.price;
    final source = data.sources.firstWhere((s) => s.name == sourceName);
    final category =
        financeCategories.firstWhere((cat) => cat.id == categoryId);
    final savedLocally = partialPayment
        ? await Repo.instance.partialPayPlannedExpenseItem(
            item: item,
            price: price,
            category: category,
            source: source,
          )
        : await Repo.instance.fulfillPlannedExpenseItem(
            item: item, price: price, category: category, source: source);
    await ref.read(appDataProvider.notifier).refresh();
    if (context.mounted && savedLocally) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('API unavailable - transaction saved locally for sync.')));
    }
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────

String _prioritySummary(List<PlannedExpenseItem> items) {
  final counts = <String, int>{};
  for (final item in items) {
    counts[item.priority] = (counts[item.priority] ?? 0) + 1;
  }
  if (counts.isEmpty) return 'None';
  return ['high', 'medium', 'low']
      .where((priority) => counts[priority] != null)
      .map((priority) => '$priority ${counts[priority]}')
      .join(' / ');
}

String _categorySummary(List<PlannedExpenseItem> items, String currency) {
  final totals = <String, double>{};
  for (final item in items) {
    final type = item.transactionType == 'earning' ? 'earning' : 'spending';
    final category = (item.categoryName ?? '').trim().isEmpty
        ? 'Uncategorized'
        : item.categoryName!.trim();
    final key = '$category ($type)';
    totals[key] = (totals[key] ?? 0) + item.price;
  }
  final rows = totals.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (rows.isEmpty) return 'None';
  return rows
      .take(3)
      .map((entry) => '${entry.key}: ${fmtRp(entry.value, currency)}')
      .join(' / ');
}

InputDecoration _fieldDecoration(AppColors c, String label) => InputDecoration(
      labelText: label,
      filled: true,
      fillColor: c.surface,
      labelStyle: TextStyle(color: c.muted, fontSize: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.line, width: 0.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.line, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.accent, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    );

// ── Widgets ────────────────────────────────────────────────────────────────

class _TabSwitcher extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onSelect;
  final AppColors c;

  const _TabSwitcher(
      {required this.tab, required this.onSelect, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _TabPill(
            label: 'Expenses',
            active: tab == 0,
            c: c,
            onTap: () => onSelect(0)),
        const SizedBox(width: 8),
        _TabPill(
            label: 'Categories',
            active: tab == 1,
            c: c,
            onTap: () => onSelect(1)),
      ],
    );
  }
}

class _TabPill extends StatelessWidget {
  final String label;
  final bool active;
  final AppColors c;
  final VoidCallback onTap;

  const _TabPill(
      {required this.label,
      required this.active,
      required this.c,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? c.ink : c.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? c.ink : c.line2,
            width: active ? 1.5 : 0.5,
          ),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? c.bg : c.muted)),
      ),
    );
  }
}

class _CategoryValueCard extends StatelessWidget {
  final String name;
  final double total;
  final double spending;
  final double earning;
  final int count;
  final String currency;
  final AppColors c;

  const _CategoryValueCard({
    required this.name,
    required this.total,
    required this.spending,
    required this.earning,
    required this.count,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final color = catColor(name);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
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
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(name,
                    style:
                        TextStyle(fontWeight: FontWeight.w700, color: c.ink)),
              ),
              Text(fmtRp(total, currency),
                  style: TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14, color: c.ink)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(width: 18),
              Text('$count ${count == 1 ? 'item' : 'items'}',
                  style: TextStyle(color: c.muted, fontSize: 12)),
              if (spending > 0) ...[
                const SizedBox(width: 10),
                Text('spend ${fmtRp(spending, currency)}',
                    style: TextStyle(color: c.neg, fontSize: 12)),
              ],
              if (earning > 0) ...[
                const SizedBox(width: 10),
                Text('earn ${fmtRp(earning, currency)}',
                    style: TextStyle(color: c.pos, fontSize: 12)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _PlannedExpenseReports extends StatelessWidget {
  final double plannedTotal;
  final double plannedSpendingTotal;
  final double plannedEarningTotal;
  final double fulfilledTotal;
  final int highPriority;
  final int activeCount;
  final double averageFulfilled;
  final PlannedExpenseItem? latestBought;
  final String prioritySummary;
  final String categorySummary;
  final String currency;
  final AppColors c;

  const _PlannedExpenseReports({
    required this.plannedTotal,
    required this.plannedSpendingTotal,
    required this.plannedEarningTotal,
    required this.fulfilledTotal,
    required this.highPriority,
    required this.activeCount,
    required this.averageFulfilled,
    required this.latestBought,
    required this.prioritySummary,
    required this.categorySummary,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('Reports', c),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                label: 'Planned value',
                value: fmtRp(plannedTotal, currency),
                color: c.ink,
                c: c,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'Bought total',
                value: fmtRp(fulfilledTotal, currency),
                color: c.neg,
                c: c,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                label: 'Active items',
                value: activeCount.toString(),
                color: c.ink,
                c: c,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'High priority',
                value: highPriority.toString(),
                color: highPriority > 0 ? c.neg : c.muted,
                c: c,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ReportPanel(
          c: c,
          rows: [
            (
              label: 'Planned spending',
              value: fmtRp(plannedSpendingTotal, currency),
            ),
            (
              label: 'Planned earning',
              value: fmtRp(plannedEarningTotal, currency),
            ),
            (
              label: 'By category',
              value: categorySummary,
            ),
            (
              label: 'Latest bought',
              value: latestBought == null ? 'None' : latestBought!.itemName,
            ),
            (
              label: 'Priority mix',
              value: prioritySummary,
            ),
            (
              label: 'Average bought price',
              value: fmtRp(averageFulfilled, currency),
            ),
          ],
        ),
      ],
    );
  }
}

class _PlannedExpenseCard extends StatelessWidget {
  final PlannedExpenseItem item;
  final String currency;
  final AppColors c;
  final VoidCallback? onFulfill;
  final VoidCallback? onPartialPayment;
  final VoidCallback? onCancel;
  final VoidCallback onRemove;

  const _PlannedExpenseCard({
    required this.item,
    required this.currency,
    required this.c,
    required this.onFulfill,
    required this.onPartialPayment,
    required this.onCancel,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (item.status) {
      'fulfilled' => c.pos,
      'canceled' => c.neg,
      _ => c.accent,
    };
    final amount = item.fulfilledPrice ?? item.price;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(item.itemName,
                          style: TextStyle(
                              fontWeight: FontWeight.w700, color: c.ink)),
                    ),
                    Text(item.priority,
                        style: TextStyle(
                            fontSize: 12,
                            color: c.muted,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(fmtRp(amount, currency),
                    style: TextStyle(color: statusColor, fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                    '${item.transactionType == 'earning' ? 'earning' : 'spending'} - ${(item.categoryName ?? '').trim().isEmpty ? 'Uncategorized' : item.categoryName}',
                    style: TextStyle(color: c.muted, fontSize: 12)),
                if ((item.notes ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(item.notes!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.muted, fontSize: 12)),
                ],
                if (item.status != 'active') ...[
                  const SizedBox(height: 4),
                  Text(item.status,
                      style: TextStyle(color: statusColor, fontSize: 12)),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'fulfill') onFulfill?.call();
              if (value == 'partial') onPartialPayment?.call();
              if (value == 'cancel') onCancel?.call();
              if (value == 'remove') onRemove();
            },
            itemBuilder: (_) => [
              if (onFulfill != null)
                const PopupMenuItem(value: 'fulfill', child: Text('Fulfill')),
              if (onPartialPayment != null)
                const PopupMenuItem(
                    value: 'partial', child: Text('Partial payment')),
              if (onCancel != null)
                const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
              const PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlannedExpenseEditorSheet extends ConsumerStatefulWidget {
  final Future<void> Function() onSaved;
  const _PlannedExpenseEditorSheet({required this.onSaved});

  @override
  ConsumerState<_PlannedExpenseEditorSheet> createState() =>
      _PlannedExpenseEditorSheetState();
}

class _PlannedExpenseEditorSheetState extends ConsumerState<_PlannedExpenseEditorSheet> {
  final _nameCtl = TextEditingController();
  final _priceCtl = TextEditingController();
  final _notesCtl = TextEditingController();
  String _transactionType = 'spending';
  String? _categoryId;
  String _priority = 'medium';

  @override
  void dispose() {
    _nameCtl.dispose();
    _priceCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    final price = double.tryParse(_priceCtl.text.replaceAll(',', '.')) ?? 0;
    final data = ref.read(appDataProvider).valueOrNull;
    final categories = data?.categories
            .where((cat) => cat.kind == 'planned_expense')
            .toList() ??
        [];
    Category? category;
    for (final cat in categories) {
      if (cat.id == _categoryId) {
        category = cat;
        break;
      }
    }
    if (name.isEmpty || price <= 0 || category == null) return;
    await Repo.instance.createPlannedExpenseItem(
      itemName: name,
      price: price,
      transactionType: _transactionType,
      category: category,
      notes: _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim(),
      priority: _priority,
    );
    await widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final data = ref.watch(appDataProvider).valueOrNull;
    final categories = data?.categories
            .where((cat) => cat.kind == 'planned_expense')
            .toList() ??
        [];
    final selectedCategoryId =
        categories.any((cat) => cat.id == _categoryId) ? _categoryId : null;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Text('Add planned expense',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, color: c.ink)),
              const Spacer(),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 14),
            TextField(
                controller: _nameCtl,
                style: TextStyle(color: c.ink, fontSize: 15),
                decoration: _fieldDecoration(c, 'Item name')),
            const SizedBox(height: 12),
            TextField(
              controller: _priceCtl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              style: TextStyle(color: c.ink, fontSize: 15),
              decoration: _fieldDecoration(c, 'Price'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _transactionType,
              decoration: _fieldDecoration(c, 'Type'),
              dropdownColor: c.surface,
              style: TextStyle(color: c.ink, fontSize: 15),
              items: const [
                DropdownMenuItem(value: 'spending', child: Text('spending')),
                DropdownMenuItem(value: 'earning', child: Text('earning')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _transactionType = v;
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: selectedCategoryId,
              decoration: _fieldDecoration(c, 'Planned category'),
              dropdownColor: c.surface,
              style: TextStyle(color: c.ink, fontSize: 15),
              items: categories
                  .map((cat) =>
                      DropdownMenuItem(value: cat.id, child: Text(cat.name)))
                  .toList(),
              onChanged: (v) => setState(() => _categoryId = v),
            ),
            const SizedBox(height: 12),
            TextField(
                controller: _notesCtl,
                minLines: 1,
                maxLines: 3,
                style: TextStyle(color: c.ink, fontSize: 15),
                decoration: _fieldDecoration(c, 'Notes')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _priority,
              decoration: _fieldDecoration(c, 'Priority'),
              dropdownColor: c.surface,
              style: TextStyle(color: c.ink, fontSize: 15),
              items: const [
                DropdownMenuItem(value: 'high', child: Text('high')),
                DropdownMenuItem(value: 'medium', child: Text('medium')),
                DropdownMenuItem(value: 'low', child: Text('low')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _priority = v);
              },
            ),
            const SizedBox(height: 22),
            SizedBox(
              height: 48,
              width: double.infinity,
              child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: c.ink,
                      foregroundColor: c.bg,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: const Text('Save',
                      style: TextStyle(fontWeight: FontWeight.w600))),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlannedCategoryEditorSheet extends ConsumerStatefulWidget {
  final Category? category;
  final Future<void> Function() onSaved;
  const _PlannedCategoryEditorSheet({this.category, required this.onSaved});

  @override
  ConsumerState<_PlannedCategoryEditorSheet> createState() =>
      _PlannedCategoryEditorSheetState();
}

class _PlannedCategoryEditorSheetState
    extends ConsumerState<_PlannedCategoryEditorSheet> {
  final _nameCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.category != null) {
      _nameCtl.text = widget.category!.name;
    }
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) return;
    await Repo.instance.createCategory(name: name, kind: 'planned_expense');
    await widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete category?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await Repo.instance
        .deleteCategory(id: widget.category!.id, kind: widget.category!.kind);
    await widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Text(
                  widget.category != null
                      ? 'Edit category'
                      : 'Add planned category',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, color: c.ink)),
              const Spacer(),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _nameCtl,
              enabled: widget.category == null,
              style: TextStyle(color: c.ink, fontSize: 15),
              decoration: _fieldDecoration(c, 'Category name').copyWith(
                helperText: widget.category != null
                    ? "Name can't be changed once created"
                    : null,
              ),
            ),
            const SizedBox(height: 22),
            Row(children: [
              if (widget.category != null)
                TextButton(
                  onPressed: _delete,
                  child: Text('Delete', style: TextStyle(color: c.neg)),
                ),
              const Spacer(),
              if (widget.category == null)
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: c.ink,
                        foregroundColor: c.bg,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12))),
                    child: const Text('Save',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors c;
  const _SectionTitle(this.text, this.c);

  @override
  Widget build(BuildContext context) => Text(text,
      style:
          TextStyle(color: c.muted, fontSize: 14, fontWeight: FontWeight.w600));
}

class _EmptyPanel extends StatelessWidget {
  final AppColors c;
  final String text;
  const _EmptyPanel({required this.c, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line2, width: 0.5)),
        child: Text(text, style: TextStyle(color: c.muted, fontSize: 13)),
      );
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final AppColors c;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.color,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11, color: c.muted, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _ReportPanel extends StatelessWidget {
  final AppColors c;
  final List<({String label, String value})> rows;

  const _ReportPanel({required this.c, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        children: List.generate(rows.length, (index) {
          final row = rows[index];
          final last = index == rows.length - 1;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              border: last
                  ? null
                  : Border(bottom: BorderSide(color: c.line2, width: 0.5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(row.label,
                      style: TextStyle(fontSize: 13, color: c.muted)),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    row.value,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.ink),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}
