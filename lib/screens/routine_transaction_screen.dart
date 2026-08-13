import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

class RoutineTransactionScreen extends ConsumerWidget {
  const RoutineTransactionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) {
        final active = data.routineTransactions
            .where((item) => item.status == 'active')
            .toList();
        final currentMonth = DateTime.now().toIso8601String().substring(0, 7);
        final estimatedMonthly =
            active.fold<double>(0, (sum, item) => sum + _monthlyEstimate(item));
        final latestPayments = [...data.routinePayments]
          ..sort((a, b) => b.boughtAt.compareTo(a.boughtAt));
        final reminderMix = _reminderSummary(active);
        final topCategory = _topRoutineCategory(active);
        final paidRoutineIdsThisMonth = data.routinePayments
            .where((p) => isoMonth(p.boughtAt) == currentMonth)
            .map((p) => p.routineId)
            .toSet();
        final unpaidThisMonth = active
            .where((item) =>
                item.reminder == 'monthly' &&
                !paidRoutineIdsThisMonth.contains(item.id))
            .toList();
        // What is still owed this month: the share of the monthly estimate
        // belonging to routines that have not been paid yet. Anything already
        // paid this month contributes nothing, so this counts down to zero as
        // the month is worked through.
        final remainingThisMonth = active
            .where((item) => !paidRoutineIdsThisMonth.contains(item.id))
            .fold<double>(0, (sum, item) => sum + _monthlyEstimate(item));
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text('Routine Transaction',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: c.ink)),
                ),
                TextButton.icon(
                  onPressed: () => _openRoutineEditor(context, ref, data),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _RoutineReports(
              estimatedMonthly: estimatedMonthly,
              remainingThisMonth: remainingThisMonth,
              activeCount: active.length,
              latestPayment:
                  latestPayments.isEmpty ? null : latestPayments.first,
              reminderMix: reminderMix,
              topCategory: topCategory,
              currency: cfg.currency,
              c: c,
            ),
            const SizedBox(height: 20),
            _SectionTitle(
                'Not paid yet this month (${unpaidThisMonth.length})', c),
            const SizedBox(height: 10),
            if (unpaidThisMonth.isEmpty)
              _EmptyPanel(c: c, text: 'All monthly routines paid this month.')
            else
              ...unpaidThisMonth.map((item) => _UnpaidCard(
                    item: item,
                    currency: cfg.currency,
                    c: c,
                    onBought: () =>
                        _openBoughtDialog(context, ref, item, data),
                  )),
            const SizedBox(height: 20),
            if (active.isEmpty)
              _EmptyPanel(c: c, text: 'No routine transactions yet.')
            else
              ...active.map((item) => _RoutineCard(
                    item: item,
                    currency: cfg.currency,
                    c: c,
                    onBought: () => _openBoughtDialog(context, ref, item, data),
                    onRemove: () => _remove(context, ref, item),
                  )),
            const SizedBox(height: 20),
            _SectionTitle('History (${data.routinePayments.length})', c),
            const SizedBox(height: 10),
            if (data.routinePayments.isEmpty)
              _EmptyPanel(c: c, text: 'Routine payments appear here.')
            else
              ...data.routinePayments.take(20).map((payment) => Container(
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
                              Text(payment.itemName,
                                  style: TextStyle(
                                      color: c.ink,
                                      fontWeight: FontWeight.w700)),
                              Text(
                                  '${payment.categoryName} - ${payment.sourceName}',
                                  style:
                                      TextStyle(color: c.muted, fontSize: 12)),
                            ],
                          ),
                        ),
                        Text(fmtRp(payment.price, cfg.currency),
                            style: TextStyle(color: c.neg, fontSize: 13)),
                      ],
                    ),
                  )),
          ],
        );
      },
    );
  }

  Future<void> _remove(
      BuildContext context, WidgetRef ref, RoutineTransaction item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove routine transaction?'),
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
    await Repo.instance.removeRoutineTransaction(item);
    await ref.read(appDataProvider.notifier).refresh();
  }
}

double _monthlyEstimate(RoutineTransaction item) => switch (item.reminder) {
      'weekly' => item.price * 4,
      'bi-monthly' => item.price / 2,
      'quarterly' => item.price / 3,
      'yearly' => item.price / 12,
      _ => item.price,
    };

String _reminderSummary(List<RoutineTransaction> items) {
  final counts = <String, int>{};
  for (final item in items) {
    counts[item.reminder] = (counts[item.reminder] ?? 0) + 1;
  }
  if (counts.isEmpty) return 'None';
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries
      .take(3)
      .map((entry) => '${entry.key} ${entry.value}')
      .join(' / ');
}

String _topRoutineCategory(List<RoutineTransaction> items) {
  final totals = <String, double>{};
  for (final item in items) {
    totals[item.categoryName] = (totals[item.categoryName] ?? 0) + item.price;
  }
  if (totals.isEmpty) return 'None';
  final entries = totals.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.first.key;
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

class _RoutineReports extends StatelessWidget {
  final double estimatedMonthly;

  /// Of [estimatedMonthly], how much belongs to routines still unpaid.
  final double remainingThisMonth;
  final int activeCount;
  final RoutinePayment? latestPayment;
  final String reminderMix;
  final String topCategory;
  final String currency;
  final AppColors c;

  const _RoutineReports({
    required this.estimatedMonthly,
    required this.remainingThisMonth,
    required this.activeCount,
    required this.latestPayment,
    required this.reminderMix,
    required this.topCategory,
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
                label: 'Monthly estimate',
                value: fmtRp(estimatedMonthly, currency),
                color: c.neg,
                c: c,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'Expense remaining',
                value: fmtRp(remainingThisMonth, currency),
                // Nothing left to pay is good news, so it stops reading as an
                // outstanding cost once the month is cleared.
                color: remainingThisMonth > 0 ? c.neg : c.pos,
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
                label: 'Active routines',
                value: activeCount.toString(),
                color: c.ink,
                c: c,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'Latest payment',
                value: latestPayment == null
                    ? 'None'
                    : fmtDate(latestPayment!.boughtAt, 'short'),
                color: c.ink,
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
              label: 'Latest item paid',
              value: latestPayment == null ? 'None' : latestPayment!.itemName,
            ),
            (
              label: 'Reminder mix',
              value: reminderMix,
            ),
            (
              label: 'Largest routine category',
              value: topCategory,
            ),
          ],
        ),
      ],
    );
  }
}

class _RoutineCard extends StatelessWidget {
  final RoutineTransaction item;
  final String currency;
  final AppColors c;
  final VoidCallback onBought;
  final VoidCallback onRemove;

  const _RoutineCard({
    required this.item,
    required this.currency,
    required this.c,
    required this.onBought,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
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
                Text(item.itemName,
                    style:
                        TextStyle(fontWeight: FontWeight.w700, color: c.ink)),
                const SizedBox(height: 4),
                Text('${fmtRp(item.price, currency)} - ${item.reminder}',
                    style: TextStyle(color: c.muted, fontSize: 12)),
                Text(item.categoryName,
                    style: TextStyle(color: c.accent, fontSize: 12)),
                if (item.lastBoughtAt != null)
                  Text('Latest: ${fmtDate(item.lastBoughtAt!, 'long')}',
                      style: TextStyle(color: c.muted, fontSize: 12)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'bought') onBought();
              if (value == 'remove') onRemove();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'bought', child: Text('Confirm bought')),
              PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}

class _UnpaidCard extends StatelessWidget {
  final RoutineTransaction item;
  final String currency;
  final AppColors c;
  final VoidCallback onBought;

  const _UnpaidCard({
    required this.item,
    required this.currency,
    required this.c,
    required this.onBought,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.neg.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 40,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: c.neg,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.itemName,
                    style:
                        TextStyle(fontWeight: FontWeight.w700, color: c.ink)),
                const SizedBox(height: 2),
                Text(item.categoryName,
                    style: TextStyle(color: c.accent, fontSize: 12)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(fmtRp(item.price, currency),
                  style: TextStyle(
                      color: c.neg,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: onBought,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: c.ink,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Pay',
                      style: TextStyle(
                          color: c.bg,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

void _openRoutineEditor(BuildContext context, WidgetRef ref, AppData data) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.colorsOf(context).bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _RoutineEditorSheet(
      data: data,
      onSaved: () async {
        await ref.read(appDataProvider.notifier).refresh();
      },
    ),
  );
}

class _RoutineEditorSheet extends ConsumerStatefulWidget {
  final AppData data;
  final VoidCallback onSaved;
  const _RoutineEditorSheet({required this.data, required this.onSaved});

  @override
  ConsumerState<_RoutineEditorSheet> createState() =>
      _RoutineEditorSheetState();
}

class _RoutineEditorSheetState extends ConsumerState<_RoutineEditorSheet> {
  final _nameCtl = TextEditingController();
  final _priceCtl = TextEditingController();
  String _reminder = 'monthly';
  String _category = '';

  @override
  void dispose() {
    _nameCtl.dispose();
    _priceCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    final price = double.tryParse(_priceCtl.text.replaceAll(',', '.')) ?? 0;
    final cats = widget.data.categories.where((cat) => cat.kind == 'spending');
    if (name.isEmpty || price <= 0 || _category.isEmpty) return;
    final category = cats.firstWhere((cat) => cat.name == _category);
    await Repo.instance.createRoutineTransaction(
      itemName: name,
      price: price,
      reminder: _reminder,
      category: category,
    );
    widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cats = widget.data.categories.where((cat) => cat.kind == 'spending');
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
              Text('Add routine',
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
              initialValue: _reminder,
              decoration: _fieldDecoration(c, 'Date reminder'),
              dropdownColor: c.surface,
              style: TextStyle(color: c.ink, fontSize: 15),
              items: const [
                DropdownMenuItem(value: 'weekly', child: Text('weekly')),
                DropdownMenuItem(value: 'monthly', child: Text('monthly')),
                DropdownMenuItem(
                    value: 'bi-monthly', child: Text('bi-monthly')),
                DropdownMenuItem(value: 'quarterly', child: Text('quarterly')),
                DropdownMenuItem(value: 'yearly', child: Text('yearly')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _reminder = v);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _category.isEmpty ? null : _category,
              decoration: _fieldDecoration(c, 'Category'),
              dropdownColor: c.surface,
              style: TextStyle(color: c.ink, fontSize: 15),
              items: cats
                  .map((cat) =>
                      DropdownMenuItem(value: cat.name, child: Text(cat.name)))
                  .toList(),
              onChanged: (v) => setState(() => _category = v ?? ''),
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

Future<void> _openBoughtDialog(
  BuildContext context,
  WidgetRef ref,
  RoutineTransaction item,
  AppData data,
) async {
  final priceCtl = TextEditingController();
  String sourceName = '';
  final formKey = GlobalKey<FormState>();
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Confirm routine bought',
            style: TextStyle(
                color: AppTheme.colorsOf(context).ink,
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
                  labelText: 'Final price',
                  hintText: item.price.toStringAsFixed(0),
                ),
                style: TextStyle(color: AppTheme.colorsOf(context).ink),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: sourceName.isEmpty ? null : sourceName,
                decoration: const InputDecoration(labelText: 'Source'),
                items: data.sources
                    .map((s) =>
                        DropdownMenuItem(value: s.name, child: Text(s.name)))
                    .toList(),
                onChanged: (v) => setState(() => sourceName = v ?? ''),
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
            child: const Text('Submit'),
          ),
        ],
      ),
    ),
  );
  if (result != true) return;
  final price =
      double.tryParse(priceCtl.text.replaceAll(',', '.')) ?? item.price;
  final source = data.sources.firstWhere((s) => s.name == sourceName);
  final savedLocally = await Repo.instance
      .confirmRoutineBought(routine: item, price: price, source: source);
  await ref.read(appDataProvider.notifier).refresh();
  if (context.mounted && savedLocally) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('API unavailable - expense saved locally for sync.')));
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
