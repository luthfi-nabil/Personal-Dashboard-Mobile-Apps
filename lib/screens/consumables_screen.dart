import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

/// Things that run out - shampoo, toothpaste, razor blades.
///
/// Every physical unit is its own row with an in date and an out date, so a
/// three-pack shows up as three units and "how long does one bottle last" is
/// simply the gap between the two. Units are added by hand here, or from a
/// transaction's line item on the transaction detail screen.
class ConsumablesScreen extends ConsumerWidget {
  const ConsumablesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) {
        final inUse = data.consumables.where((item) => item.isInUse).toList();
        final usedUp = data.consumables.where((item) => !item.isInUse).toList()
          ..sort((a, b) => b.outDate.compareTo(a.outDate));

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text('Consumables',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: c.ink)),
                ),
                TextButton.icon(
                  onPressed: () => _openEditor(context, ref),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Things that run out. Each unit is tracked on its own, so you can '
              'see how long one lasts.',
              style: TextStyle(color: c.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            _Reports(inUse: inUse, usedUp: usedUp, c: c),
            const SizedBox(height: 20),
            _SectionTitle('In use (${inUse.length})', c),
            const SizedBox(height: 10),
            if (inUse.isEmpty)
              _EmptyPanel(
                  c: c,
                  text: 'Nothing in use. Add a unit, or send one over from a '
                      'transaction detail.')
            else
              ...inUse.map((item) => _ConsumableCard(
                    item: item,
                    currency: cfg.currency,
                    c: c,
                    onPrimary: () => _markUsedUp(context, ref, item),
                    onRemove: () => _remove(context, ref, item),
                  )),
            const SizedBox(height: 20),
            _SectionTitle('Used up (${usedUp.length})', c),
            const SizedBox(height: 10),
            if (usedUp.isEmpty)
              _EmptyPanel(c: c, text: 'Units you have finished appear here.')
            else
              ...usedUp.take(30).map((item) => _ConsumableCard(
                    item: item,
                    currency: cfg.currency,
                    c: c,
                    onPrimary: () => _putBackInUse(ref, item),
                    onRemove: () => _remove(context, ref, item),
                  )),
          ],
        );
      },
    );
  }

  Future<void> _openEditor(BuildContext context, WidgetRef ref) async {
    final draft = await showModalBottomSheet<_ConsumableDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ConsumableEditorSheet(),
    );
    if (draft == null) return;

    await Repo.instance.addConsumables(
      itemName: draft.itemName,
      count: draft.count,
      notes: draft.notes,
      price: draft.price,
      inDate: draft.inDate,
    );
    await ref.read(appDataProvider.notifier).refresh();
  }

  /// Asks which day it ran out, defaulting to today - the usual case is
  /// noticing an empty bottle the moment you reach for it.
  Future<void> _markUsedUp(
      BuildContext context, WidgetRef ref, Consumable item) async {
    final start = DateTime.tryParse(item.inDate) ?? DateTime.now();
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: start.isAfter(now) ? now : start,
      lastDate: now,
      helpText: 'When did it run out?',
    );
    if (picked == null) return;
    await Repo.instance
        .setConsumableOutDate(item, picked.toIso8601String());
    await ref.read(appDataProvider.notifier).refreshCached();
  }

  Future<void> _putBackInUse(WidgetRef ref, Consumable item) async {
    await Repo.instance.setConsumableOutDate(item, '');
    await ref.read(appDataProvider.notifier).refreshCached();
  }

  Future<void> _remove(
      BuildContext context, WidgetRef ref, Consumable item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this unit?'),
        content: Text(item.isPartOfBatch
            ? '${item.itemName} (${item.unitIndex}/${item.unitTotal}) will be '
                'removed. The other units stay.'
            : '${item.itemName} will be removed.'),
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
    await Repo.instance.removeConsumable(item);
    await ref.read(appDataProvider.notifier).refreshCached();
  }
}

/// Average days a finished unit lasted, or null while nothing has run out yet.
double? _averageLifespan(List<Consumable> usedUp) {
  final spans = usedUp
      .map((item) => item.daysInUse)
      .whereType<int>()
      .toList();
  if (spans.isEmpty) return null;
  return spans.reduce((a, b) => a + b) / spans.length;
}

class _Reports extends StatelessWidget {
  final List<Consumable> inUse;
  final List<Consumable> usedUp;
  final AppColors c;

  const _Reports({required this.inUse, required this.usedUp, required this.c});

  @override
  Widget build(BuildContext context) {
    final average = _averageLifespan(usedUp);
    // The unit that has been going longest is the one most likely to need
    // replacing next.
    final oldest = [...inUse]..sort((a, b) => a.inDate.compareTo(b.inDate));
    final longestRunning = oldest.isEmpty ? null : oldest.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                  label: 'In use',
                  value: '${inUse.length}',
                  color: c.ink,
                  c: c),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                  label: 'Used up',
                  value: '${usedUp.length}',
                  color: c.muted,
                  c: c),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                label: 'Average life',
                value: average == null ? '—' : '${average.round()} days',
                color: c.ink,
                c: c,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricTile(
                label: 'Longest running',
                value: longestRunning == null
                    ? '—'
                    : '${longestRunning.daysInUse ?? 0} days',
                hint: longestRunning?.itemName,
                color: c.ink,
                c: c,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ConsumableCard extends StatelessWidget {
  final Consumable item;
  final String currency;
  final AppColors c;
  final VoidCallback onPrimary;
  final VoidCallback onRemove;

  const _ConsumableCard({
    required this.item,
    required this.currency,
    required this.c,
    required this.onPrimary,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final days = item.daysInUse;
    final subtitle = [
      'in ${fmtDate(item.inDate, 'short')}',
      if (!item.isInUse) 'out ${fmtDate(item.outDate, 'short')}',
      if (days != null)
        item.isInUse ? '$days days so far' : 'lasted $days days',
      if (item.price > 0) fmtRp(item.price, currency),
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
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
                    Flexible(
                      child: Text(
                        item.itemName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: item.isInUse ? c.ink : c.muted,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (item.isPartOfBatch)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '${item.unitIndex}/${item.unitTotal}',
                          style: TextStyle(color: c.muted, fontSize: 11),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(color: c.muted, fontSize: 12)),
                if (item.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(item.notes,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.muted, fontSize: 11)),
                  ),
                // Units created from a line item keep a link back to what they
                // were bought on.
                if (item.transactionId.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: GestureDetector(
                      onTap: () => context.push('/add/${item.transactionId}'),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.receipt_long_outlined,
                              size: 13, color: c.accent),
                          const SizedBox(width: 4),
                          Text('From transaction',
                              style:
                                  TextStyle(color: c.accent, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: onPrimary,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero),
            child: Text(item.isInUse ? 'Used up' : 'Reopen',
                style: TextStyle(color: c.accent, fontSize: 13)),
          ),
          GestureDetector(
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child:
                  Icon(Icons.delete_outline_rounded, size: 18, color: c.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the add sheet hands back.
class _ConsumableDraft {
  final String itemName;
  final int count;
  final double price;
  final String notes;
  final String inDate;

  const _ConsumableDraft({
    required this.itemName,
    required this.count,
    required this.price,
    required this.notes,
    required this.inDate,
  });
}

class _ConsumableEditorSheet extends StatefulWidget {
  const _ConsumableEditorSheet();

  @override
  State<_ConsumableEditorSheet> createState() => _ConsumableEditorSheetState();
}

class _ConsumableEditorSheetState extends State<_ConsumableEditorSheet> {
  final _nameCtl = TextEditingController();
  final _countCtl = TextEditingController(text: '1');
  final _priceCtl = TextEditingController();
  final _notesCtl = TextEditingController();
  DateTime _inDate = DateTime.now();

  @override
  void dispose() {
    _nameCtl.dispose();
    _countCtl.dispose();
    _priceCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  int get _count {
    final parsed = int.tryParse(_countCtl.text.trim()) ?? 1;
    return parsed < 1 ? 1 : parsed;
  }

  void _submit() {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give the item a name.')),
      );
      return;
    }
    Navigator.pop(
      context,
      _ConsumableDraft(
        itemName: name,
        count: _count,
        price: double.tryParse(_priceCtl.text.replaceAll(',', '.')) ?? 0,
        notes: _notesCtl.text.trim(),
        inDate: _inDate.toIso8601String(),
      ),
    );
  }

  Future<void> _pickInDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _inDate,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      helpText: 'When did it come in?',
    );
    if (picked != null) setState(() => _inDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add consumable',
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: c.ink)),
            const SizedBox(height: 14),
            TextField(
              controller: _nameCtl,
              autofocus: true,
              style: TextStyle(fontSize: 15, color: c.ink),
              decoration: _fieldDecoration(c, 'Item name'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _countCtl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(fontSize: 15, color: c.ink),
                    decoration: _fieldDecoration(c, 'Units'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _priceCtl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
                    ],
                    style: TextStyle(fontSize: 15, color: c.ink),
                    decoration: _fieldDecoration(c, 'Price per unit'),
                  ),
                ),
              ],
            ),
            if (_count > 1)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 2),
                child: Text(
                  'Creates $_count separate units (1/$_count … $_count/$_count), '
                  'each finished on its own date.',
                  style: TextStyle(color: c.muted, fontSize: 11, height: 1.4),
                ),
              ),
            const SizedBox(height: 10),
            InkWell(
              onTap: _pickInDate,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: _fieldDecoration(c, 'In date'),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        fmtDate(_inDate.toIso8601String(), 'long'),
                        style: TextStyle(fontSize: 15, color: c.ink),
                      ),
                    ),
                    Icon(Icons.calendar_today_rounded, size: 16, color: c.muted),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _notesCtl,
              style: TextStyle(fontSize: 15, color: c.ink),
              decoration: _fieldDecoration(c, 'Notes (optional)'),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.ink,
                  foregroundColor: c.bg,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(_count > 1 ? 'Add $_count units' : 'Add unit',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
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

class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors c;
  const _SectionTitle(this.text, this.c);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
            color: c.ink, fontSize: 16, fontWeight: FontWeight.w700),
      );
}

class _EmptyPanel extends StatelessWidget {
  final AppColors c;
  final String text;
  const _EmptyPanel({required this.c, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Text(text,
            style: TextStyle(color: c.muted, fontSize: 13, height: 1.4)),
      );
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;
  final Color color;
  final AppColors c;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.color,
    required this.c,
    this.hint,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: c.muted, fontSize: 12)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 18, fontWeight: FontWeight.w700)),
            if (hint != null && hint!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(hint!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 11)),
              ),
          ],
        ),
      );
}
