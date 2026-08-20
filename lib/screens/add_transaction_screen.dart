import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../core/models.dart';
import '../core/receipt_scanner.dart';
import '../core/repo.dart';
import '../core/remote_api.dart';
import '../core/utils.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';

/// Pre-filled content for [AddTransactionScreen], passed as go_router `extra`.
///
/// The receipt scanner produces one of these after the user confirms the
/// recognised price list; the Add-transaction screen then behaves like a normal
/// manual entry with the item breakdown already filled in.
class AddTransactionDraft {
  final List<TransactionDetail> details;
  final String description;
  final double? amount;

  const AddTransactionDraft({
    this.details = const [],
    this.description = '',
    this.amount,
  });
}

class AddTransactionScreen extends ConsumerStatefulWidget {
  final String? editId;
  final String? returnPath;

  /// Optional pre-filled amount, description and line items (e.g. from a
  /// scanned receipt).
  final AddTransactionDraft? draft;

  const AddTransactionScreen({
    super.key,
    this.editId,
    this.returnPath,
    this.draft,
  });

  @override
  ConsumerState<AddTransactionScreen> createState() =>
      _AddTransactionScreenState();
}

class _AddTransactionScreenState extends ConsumerState<AddTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amtCtl = TextEditingController();
  final _descCtl = TextEditingController();
  final _uuid = const Uuid();

  String _type = 'spending';
  String _source = '';
  String _fromSource = '';
  String _toSource = '';
  String _category = '';
  bool _saving = false;

  /// Line items saved alongside the spending as its "transaction detail".
  final List<TransactionDetail> _details = [];

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    if (draft == null) return;

    // A draft always describes a spending - only spendings carry line items.
    _type = 'spending';
    _details.addAll(draft.details);
    if (draft.description.isNotEmpty) _descCtl.text = draft.description;
    final amount = draft.amount ?? _detailsTotal;
    if (amount > 0) _amtCtl.text = _formatAmount(amount);
  }

  @override
  void dispose() {
    _amtCtl.dispose();
    _descCtl.dispose();
    super.dispose();
  }

  /// Only ticked items count: an unticked row stays in the breakdown as a
  /// record of what was on the receipt but was not bought.
  double get _detailsTotal =>
      _details.fold<double>(0, (sum, d) => sum + d.checkedTotal);

  static String _formatAmount(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2);

  /// Keeps the amount field in step with the breakdown whenever items change,
  /// so the header total can never silently disagree with its detail.
  void _syncAmountFromDetails() {
    if (_details.isEmpty) return;
    _amtCtl.text = _formatAmount(_detailsTotal);
  }

  Future<void> _editDetail({TransactionDetail? existing}) async {
    final result = await showModalBottomSheet<TransactionDetail>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DetailEditorSheet(
        detail: existing,
        newId: () => _uuid.v4(),
      ),
    );
    if (result == null) return;
    setState(() {
      final index = _details.indexWhere((d) => d.id == result.id);
      if (index >= 0) {
        _details[index] = result;
      } else {
        _details.add(result);
      }
      _syncAmountFromDetails();
    });
  }

  void _removeDetail(TransactionDetail detail) {
    setState(() {
      _details.removeWhere((d) => d.id == detail.id);
      _syncAmountFromDetails();
    });
  }

  void _toggleDetail(TransactionDetail detail, bool checked) {
    setState(() {
      final index = _details.indexWhere((d) => d.id == detail.id);
      if (index < 0) return;
      _details[index] = _details[index].copyWith(checked: checked);
      _syncAmountFromDetails();
    });
  }

  Future<void> _save(AppData data) async {
    if (!_formKey.currentState!.validate()) return;
    if (_type == 'transfer' && _fromSource == _toSource) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('From and To sources must be different.')),
      );
      return;
    }

    final amount = double.tryParse(_amtCtl.text.replaceAll(',', '.')) ?? 0;
    final description = _descCtl.text.trim();

    setState(() => _saving = true);
    try {
      var savedLocally = false;
      switch (_type) {
        case 'earning':
          final category = data.categories
              .firstWhere((c) => c.kind == 'earning' && c.name == _category);
          final source = data.sources.firstWhere((s) => s.name == _source);
          savedLocally = await Repo.instance.createEarning(
            amount: amount,
            description: description,
            category: category,
            source: source,
          );
          break;
        case 'spending':
          final category = data.categories
              .firstWhere((c) => c.kind == 'spending' && c.name == _category);
          final source = data.sources.firstWhere((s) => s.name == _source);
          savedLocally = await Repo.instance.createSpending(
            amount: amount,
            description: description,
            category: category,
            source: source,
            details: _details,
          );
          break;
        case 'transfer':
          final from = data.sources.firstWhere((s) => s.name == _fromSource);
          final to = data.sources.firstWhere((s) => s.name == _toSource);
          savedLocally = await Repo.instance.createTransfer(
            amount: amount,
            description: description,
            fromSource: from,
            toSource: to,
          );
          break;
      }
      await ref.read(appDataProvider.notifier).refresh();
      if (mounted) {
        if (savedLocally) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'API unavailable - transaction saved locally and will sync once reconnected.')),
          );
        }
        final returnPath = widget.returnPath;
        if (returnPath == null || returnPath.isEmpty) {
          context.pop();
        } else {
          context.go(returnPath);
        }
      }
    } catch (e) {
      if (!mounted) return;
      final message =
          e is ApiException ? e.message : 'Failed to save transaction.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Scaffold(
          backgroundColor: c.bg,
          body: Center(child: CircularProgressIndicator(color: c.accent))),
      error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
      data: (data) {
        // Transactions loaded from transaction-api have no edit/delete endpoint,
        // so they're shown read-only - only brand-new transactions can be created here.
        if (widget.editId != null && widget.editId!.isNotEmpty) {
          final existing =
              data.transactions.where((t) => t.id == widget.editId).firstOrNull;
          if (existing != null) {
            return _ReadOnlyTransactionView(transaction: existing, c: c);
          }
        }

        final filteredCats =
            data.categories.where((cat) => cat.kind == _type).toList();
        if (_category.isNotEmpty &&
            !filteredCats.any((cat) => cat.name == _category)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _category = '');
          });
        }

        return Scaffold(
          backgroundColor: c.bg,
          body: SafeArea(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        _IconBtn(
                            icon: Icons.close_rounded,
                            onTap: () => context.pop(),
                            c: c),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Add transaction',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: c.ink),
                          ),
                        ),
                        if (_type == 'spending' && ReceiptScanner.isSupported)
                          _IconBtn(
                            icon: Icons.document_scanner_outlined,
                            tooltip: 'Scan price list',
                            onTap: () => context.push('/scan-receipt'),
                            c: c,
                          )
                        else
                          const SizedBox(width: 40),
                      ],
                    ),
                  ),

                  // Type selector
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: c.line2, width: 0.5),
                    ),
                    child: Row(
                      children: ['spending', 'earning', 'transfer'].map((tp) {
                        final active = _type == tp;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _type = tp),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: active ? c.surface2 : Colors.transparent,
                                borderRadius: BorderRadius.circular(11),
                                boxShadow: active
                                    ? [
                                        BoxShadow(
                                            color:
                                                Colors.black.withOpacity(0.06),
                                            blurRadius: 3)
                                      ]
                                    : null,
                              ),
                              child: Text(
                                tp[0].toUpperCase() + tp.substring(1),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: active ? c.ink : c.muted,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Amount field
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: c.line2, width: 0.5),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('Rp',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: c.muted)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            controller: _amtCtl,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.,]'))
                            ],
                            style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                                color: c.ink),
                            decoration: InputDecoration(
                              hintText: '0',
                              hintStyle: TextStyle(
                                  color: c.ink.withOpacity(0.18),
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              isDense: true,
                            ),
                            validator: (v) {
                              if (v == null || v.isEmpty) return 'Required';
                              final n = double.tryParse(v.replaceAll(',', '.'));
                              if (n == null || n <= 0)
                                return 'Enter a valid amount';
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Description
                  _Field(
                      label: 'Description',
                      child: TextFormField(
                        controller: _descCtl,
                        style: TextStyle(fontSize: 15, color: c.ink),
                        decoration: InputDecoration(
                            hintText: 'What was it?',
                            hintStyle: TextStyle(color: c.muted)),
                      )),
                  const SizedBox(height: 14),

                  // Source fields
                  if (_type == 'transfer') ...[
                    _Field(
                        label: 'From',
                        child: _SourceDropdown(
                          value: _fromSource,
                          sources: data.sources,
                          c: c,
                          hint: 'Select source…',
                          onChanged: (v) =>
                              setState(() => _fromSource = v ?? ''),
                        )),
                    const SizedBox(height: 14),
                    _Field(
                        label: 'To',
                        child: _SourceDropdown(
                          value: _toSource,
                          sources: data.sources,
                          c: c,
                          hint: 'Select destination…',
                          onChanged: (v) => setState(() => _toSource = v ?? ''),
                        )),
                  ] else ...[
                    _Field(
                        label: 'Source',
                        child: _SourceDropdown(
                          value: _source,
                          sources: data.sources,
                          c: c,
                          hint: 'Select source…',
                          onChanged: (v) => setState(() => _source = v ?? ''),
                        )),
                    const SizedBox(height: 14),
                    _Field(
                        label: 'Category',
                        child: _CategoryDropdown(
                          value: _category,
                          categories: filteredCats,
                          c: c,
                          onChanged: (v) => setState(() => _category = v ?? ''),
                        )),
                    const SizedBox(height: 14),
                    if (_type == 'spending')
                      _DetailSection(
                        details: _details,
                        currency: ref.watch(configProvider).currency,
                        c: c,
                        onAdd: () => _editDetail(),
                        onEdit: (detail) => _editDetail(existing: detail),
                        onRemove: _removeDetail,
                        onToggle: _toggleDetail,
                        onScan: ReceiptScanner.isSupported
                            ? () => context.push('/scan-receipt')
                            : null,
                      ),
                  ],
                  const SizedBox(height: 24),

                  // Save button
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _saving ? null : () => _save(data),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.ink,
                        foregroundColor: c.bg,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      child: _saving
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: c.bg),
                            )
                          : const Text(
                              'Save transaction',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Transactions loaded from transaction-api have no edit/delete endpoint,
/// so they are shown as a read-only summary.
class _ReadOnlyTransactionView extends ConsumerWidget {
  final Transaction transaction;
  final AppColors c;
  const _ReadOnlyTransactionView({required this.transaction, required this.c});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(configProvider);
    final t = transaction;
    final isEarning = t.type == 'earning';
    final isTransfer = t.type == 'transfer';
    final amountColor = isTransfer ? c.transfer : (isEarning ? c.pos : c.neg);
    final sign = isTransfer ? '' : (isEarning ? '+' : '−');
    // Line items live on AppData, so a synced spending shows its breakdown
    // without an extra round-trip.
    final details = ref.watch(appDataProvider).maybeWhen<List<TransactionDetail>>(
          data: (data) => data.detailsFor(t.id),
          orElse: () => const <TransactionDetail>[],
        );
    final plannedTransactions = ref
        .watch(appDataProvider)
        .maybeWhen<List<PlannedTransaction>>(
          data: (data) => data.plannedTransactions,
          orElse: () => const <PlannedTransaction>[],
        );

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  _IconBtn(
                      icon: Icons.close_rounded,
                      onTap: () => context.pop(),
                      c: c),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Transaction',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: c.ink)),
                  ),
                  const SizedBox(width: 40),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.line2, width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.type[0].toUpperCase() + t.type.substring(1),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.muted),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$sign${fmtRp(t.amount, cfg.currency)}',
                    style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: amountColor),
                  ),
                  const SizedBox(height: 18),
                  if (t.description.isNotEmpty)
                    _DetailRow(
                        label: 'Description', value: t.description, c: c),
                  if (isTransfer) ...[
                    _DetailRow(label: 'From', value: t.fromSource ?? '—', c: c),
                    _DetailRow(label: 'To', value: t.toSource ?? '—', c: c),
                  ] else ...[
                    _DetailRow(label: 'Source', value: t.source ?? '—', c: c),
                    _DetailRow(
                        label: 'Category', value: t.category ?? '—', c: c),
                  ],
                  _DetailRow(
                      label: 'Date',
                      value: fmtDate(t.date, 'long'),
                      c: c,
                      last: true),
                ],
              ),
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 16),
              _ReadOnlyDetailList(
                details: details,
                currency: cfg.currency,
                c: c,
                onToggle: (detail, checked) async {
                  await Repo.instance
                      .setTransactionDetailChecked(detail, checked);
                  await ref.read(appDataProvider.notifier).refreshCached();
                },
                onTrackAsConsumable: (detail) =>
                    _trackAsConsumable(context, ref, t, detail),
                onAddToPlannedTransaction: (detail) =>
                    _addToPlannedTransaction(
                        context, ref, detail, plannedTransactions),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, size: 18, color: c.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      details.isEmpty
                          ? 'This transaction is synced from the server and cannot be edited or deleted here.'
                          : 'This transaction is synced from the server and cannot be edited or deleted here. Ticking items off its detail is saved.',
                      style:
                          TextStyle(fontSize: 13, color: c.muted, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Turns one line item into consumable units - one per unit bought, so a
/// three-pack becomes three entries that run out on their own dates.
///
/// The unit price and the transaction's date carry over, and the link back to
/// the purchase is kept, so the Consumables page can say where it came from.
Future<void> _trackAsConsumable(
  BuildContext context,
  WidgetRef ref,
  Transaction transaction,
  TransactionDetail detail,
) async {
  final quantity = detail.quantity;
  final count = quantity >= 1 && quantity == quantity.roundToDouble()
      ? quantity.round()
      : 1;
  final unitPrice = detail.unitPrice > 0
      ? detail.unitPrice
      : (count > 0 ? detail.lineTotal / count : detail.lineTotal);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Add to consumables?'),
      content: Text(count > 1
          ? '${detail.itemName} will be tracked as $count separate units, each '
              'with its own in and out date.'
          : '${detail.itemName} will be tracked as one unit you can mark as '
              'used up later.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Add')),
      ],
    ),
  );
  if (confirmed != true) return;

  await Repo.instance.addConsumables(
    itemName: detail.itemName.isEmpty ? 'Item' : detail.itemName,
    count: count,
    price: unitPrice,
    inDate: transaction.date,
    transactionId: detail.transactionId,
    transactionDetailId: detail.id,
  );
  await ref.read(appDataProvider.notifier).refreshCached();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(count > 1
          ? 'Added $count units to Consumables.'
          : 'Added to Consumables.'),
    ),
  );
}

/// Tags one line item into a planned transaction bundle - a new, named one or
/// an existing one the user already has - so it shows up grouped with
/// everything else bought for that plan.
Future<void> _addToPlannedTransaction(
  BuildContext context,
  WidgetRef ref,
  TransactionDetail detail,
  List<PlannedTransaction> plannedTransactions,
) async {
  final result = await showModalBottomSheet<_PlannedTransactionChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PlannedTransactionPickerSheet(
      itemName: detail.itemName.isEmpty ? 'Item' : detail.itemName,
      existing: plannedTransactions,
    ),
  );
  if (result == null) return;

  await Repo.instance.addTransactionDetailToPlannedTransaction(
    detail: detail,
    existingBundleId: result.existingId,
    newBundleName: result.newName,
  );
  await ref.read(appDataProvider.notifier).refreshCached();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Added to "${result.displayName}".')),
  );
}

/// The breakdown of a saved transaction, shown as a checklist.
///
/// The spending itself cannot be edited after it is stored, but each line item
/// keeps a tick recording whether it was actually bought - so the totals below
/// separate what was on the receipt from what is still ticked.
class _ReadOnlyDetailList extends StatelessWidget {
  final List<TransactionDetail> details;
  final String currency;
  final AppColors c;
  final Future<void> Function(TransactionDetail detail, bool checked) onToggle;
  final void Function(TransactionDetail detail) onTrackAsConsumable;
  final void Function(TransactionDetail detail) onAddToPlannedTransaction;

  const _ReadOnlyDetailList({
    required this.details,
    required this.currency,
    required this.c,
    required this.onToggle,
    required this.onTrackAsConsumable,
    required this.onAddToPlannedTransaction,
  });

  @override
  Widget build(BuildContext context) {
    final total = details.fold<double>(0, (sum, d) => sum + d.lineTotal);
    final checkedTotal =
        details.fold<double>(0, (sum, d) => sum + d.checkedTotal);
    final unchecked = details.where((d) => !d.checked).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Detail (${details.length} item${details.length == 1 ? '' : 's'})',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: c.muted),
          ),
          const SizedBox(height: 10),
          ...details.map((d) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Checkbox(
                      value: d.checked,
                      activeColor: c.accent,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) => onToggle(d, v ?? false),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.itemName.isEmpty ? 'Item' : d.itemName,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: d.checked ? c.ink : c.muted,
                              decoration: d.checked
                                  ? null
                                  : TextDecoration.lineThrough,
                            ),
                          ),
                          if (d.quantity != 1 || d.note.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                [
                                  if (d.quantity != 1)
                                    '${_qty(d.quantity)} × ${fmtRp(d.unitPrice, currency)}',
                                  if (d.note.isNotEmpty) d.note,
                                ].join(' · '),
                                style:
                                    TextStyle(fontSize: 11, color: c.muted),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      fmtRp(d.lineTotal, currency),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: d.checked ? c.ink : c.muted,
                        decoration:
                            d.checked ? null : TextDecoration.lineThrough,
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Item actions',
                      padding: EdgeInsets.zero,
                      color: c.surface,
                      icon: Icon(Icons.more_vert_rounded,
                          size: 18, color: c.muted),
                      onSelected: (value) {
                        if (value == 'consumable') onTrackAsConsumable(d);
                        if (value == 'planned') onAddToPlannedTransaction(d);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem<String>(
                          value: 'consumable',
                          child: Row(
                            children: [
                              Icon(Icons.inventory_2_outlined,
                                  size: 18, color: c.ink),
                              const SizedBox(width: 10),
                              Text('Add to consumables',
                                  style: TextStyle(color: c.ink)),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'planned',
                          child: Row(
                            children: [
                              Icon(Icons.playlist_add_rounded,
                                  size: 18, color: c.ink),
                              const SizedBox(width: 10),
                              Text('Add to planned transaction',
                                  style: TextStyle(color: c.ink)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              )),
          const SizedBox(height: 6),
          Divider(color: c.line2, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text('Items total',
                      style: TextStyle(fontSize: 13, color: c.muted)),
                ),
                Text(
                  fmtRp(total, currency),
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.ink),
                ),
              ],
            ),
          ),
          // Only worth showing once something has been unticked - otherwise it
          // just repeats the line above.
          if (unchecked > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Ticked ($unchecked left out)',
                        style: TextStyle(fontSize: 13, color: c.muted)),
                  ),
                  Text(
                    fmtRp(checkedTotal, currency),
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _qty(double qty) =>
      qty == qty.roundToDouble() ? qty.round().toString() : qty.toString();
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final AppColors c;
  final bool last;
  const _DetailRow(
      {required this.label,
      required this.value,
      required this.c,
      this.last = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: TextStyle(fontSize: 13, color: c.muted)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500, color: c.ink)),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: c.muted)),
        ),
        child,
      ],
    );
  }
}

class _SourceDropdown extends StatelessWidget {
  final String value;
  final List<Source> sources;
  final AppColors c;
  final String hint;
  final ValueChanged<String?> onChanged;
  const _SourceDropdown(
      {required this.value,
      required this.sources,
      required this.c,
      required this.hint,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: value.isEmpty ? null : value,
      hint: Text(hint, style: TextStyle(color: c.muted)),
      decoration: InputDecoration(
        filled: true,
        fillColor: c.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: c.line, width: 0.5)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: c.line, width: 0.5)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      items: sources
          .map((s) => DropdownMenuItem(value: s.name, child: Text(s.name)))
          .toList(),
      onChanged: onChanged,
      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
      dropdownColor: c.surface,
      style: TextStyle(color: c.ink, fontSize: 15),
    );
  }
}

class _CategoryDropdown extends StatelessWidget {
  final String value;
  final List<Category> categories;
  final AppColors c;
  final ValueChanged<String?> onChanged;
  const _CategoryDropdown(
      {required this.value,
      required this.categories,
      required this.c,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: value.isEmpty ? null : value,
      hint: Text('— none —', style: TextStyle(color: c.muted)),
      decoration: InputDecoration(
        filled: true,
        fillColor: c.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: c.line, width: 0.5)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: c.line, width: 0.5)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      items: categories
          .map(
              (cat) => DropdownMenuItem(value: cat.name, child: Text(cat.name)))
          .toList(),
      onChanged: onChanged,
      validator: (v) => v == null || v.isEmpty ? 'Required' : null,
      dropdownColor: c.surface,
      style: TextStyle(color: c.ink, fontSize: 15),
    );
  }
}

/// What [_PlannedTransactionPickerSheet] hands back: either a brand new
/// bundle name, or the id of one the user already has.
class _PlannedTransactionChoice {
  final String? existingId;
  final String? newName;
  final String displayName;
  const _PlannedTransactionChoice({
    this.existingId,
    this.newName,
    required this.displayName,
  });
}

/// Bottom sheet for tagging a transaction line item into a planned
/// transaction bundle - create a new named one, or pick one already made.
class _PlannedTransactionPickerSheet extends StatefulWidget {
  final String itemName;
  final List<PlannedTransaction> existing;

  const _PlannedTransactionPickerSheet({
    required this.itemName,
    required this.existing,
  });

  @override
  State<_PlannedTransactionPickerSheet> createState() =>
      _PlannedTransactionPickerSheetState();
}

class _PlannedTransactionPickerSheetState
    extends State<_PlannedTransactionPickerSheet> {
  late bool _isNew = widget.existing.isEmpty;
  final _nameCtl = TextEditingController();
  String? _selectedId;

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_isNew) {
      final name = _nameCtl.text.trim();
      if (name.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a name for the plan.')),
        );
        return;
      }
      Navigator.pop(
        context,
        _PlannedTransactionChoice(newName: name, displayName: name),
      );
      return;
    }
    final selected =
        widget.existing.where((b) => b.id == _selectedId).firstOrNull;
    if (selected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a plan.')),
      );
      return;
    }
    Navigator.pop(
      context,
      _PlannedTransactionChoice(
          existingId: selected.id, displayName: selected.name),
    );
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
            Text('Add to planned transaction',
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: c.ink)),
            const SizedBox(height: 4),
            Text(widget.itemName,
                style: TextStyle(fontSize: 13, color: c.muted)),
            const SizedBox(height: 14),
            if (widget.existing.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.line2, width: 0.5),
                ),
                child: Row(
                  children: [
                    Expanded(
                        child: _ChoiceTab(
                            label: 'New plan',
                            active: _isNew,
                            c: c,
                            onTap: () => setState(() => _isNew = true))),
                    Expanded(
                        child: _ChoiceTab(
                            label: 'Existing plan',
                            active: !_isNew,
                            c: c,
                            onTap: () => setState(() => _isNew = false))),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            if (_isNew)
              _SheetField(
                  label: 'Plan name',
                  controller: _nameCtl,
                  c: c,
                  autofocus: true)
            else
              DropdownButtonFormField<String>(
                initialValue: _selectedId,
                decoration: InputDecoration(
                  labelText: 'Plan',
                  labelStyle: TextStyle(color: c.muted, fontSize: 13),
                  filled: true,
                  fillColor: c.surface,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: c.line, width: 0.5)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                ),
                dropdownColor: c.surface,
                style: TextStyle(color: c.ink, fontSize: 15),
                items: widget.existing
                    .map((b) =>
                        DropdownMenuItem(value: b.id, child: Text(b.name)))
                    .toList(),
                onChanged: (v) => setState(() => _selectedId = v),
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
                child: const Text('Add',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceTab extends StatelessWidget {
  final String label;
  final bool active;
  final AppColors c;
  final VoidCallback onTap;

  const _ChoiceTab({
    required this.label,
    required this.active,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? c.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: active ? c.ink : c.muted,
            )),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final AppColors c;
  final String? tooltip;
  const _IconBtn({
    required this.icon,
    required this.onTap,
    required this.c,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
            color: c.surface, borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, size: 20, color: c.ink),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Editable list of line items shown under a spending. Populated by hand or
/// from a scanned price list; each row maps to one `spending_detail` row.
class _DetailSection extends StatelessWidget {
  final List<TransactionDetail> details;
  final String currency;
  final AppColors c;
  final VoidCallback onAdd;
  final void Function(TransactionDetail detail) onEdit;
  final void Function(TransactionDetail detail) onRemove;
  final void Function(TransactionDetail detail, bool checked) onToggle;
  final VoidCallback? onScan;

  const _DetailSection({
    required this.details,
    required this.currency,
    required this.c,
    required this.onAdd,
    required this.onEdit,
    required this.onRemove,
    required this.onToggle,
    this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    final total = details.fold<double>(0, (sum, d) => sum + d.checkedTotal);
    final unchecked = details.where((d) => !d.checked).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Transaction detail',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500, color: c.muted),
              ),
            ),
            if (onScan != null)
              TextButton.icon(
                onPressed: onScan,
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero),
                icon: Icon(Icons.document_scanner_outlined,
                    size: 16, color: c.accent),
                label: Text('Scan',
                    style: TextStyle(color: c.accent, fontSize: 13)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.line2, width: 0.5),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              if (details.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    'No breakdown yet. Add items one by one, or scan a printed '
                    'price list to fill them in. Untick an item to leave it out '
                    'of the amount.',
                    style:
                        TextStyle(color: c.muted, fontSize: 13, height: 1.4),
                  ),
                )
              else
                ...details.map((d) => InkWell(
                      onTap: () => onEdit(d),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(4, 11, 8, 11),
                        child: Row(
                          children: [
                            Checkbox(
                              value: d.checked,
                              activeColor: c.accent,
                              visualDensity: VisualDensity.compact,
                              onChanged: (v) => onToggle(d, v ?? false),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d.itemName.isEmpty ? 'Item' : d.itemName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: d.checked ? c.ink : c.muted,
                                      decoration: d.checked
                                          ? null
                                          : TextDecoration.lineThrough,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    [
                                      '${_qtyLabel(d.quantity)} × ${fmtRp(d.unitPrice, currency)}',
                                      if (d.note.isNotEmpty) d.note,
                                    ].join(' · '),
                                    style: TextStyle(
                                        fontSize: 11, color: c.muted),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              fmtRp(d.lineTotal, currency),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: d.checked ? c.ink : c.muted,
                                decoration: d.checked
                                    ? null
                                    : TextDecoration.lineThrough,
                              ),
                            ),
                            GestureDetector(
                              onTap: () => onRemove(d),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Icon(Icons.close_rounded,
                                    size: 16, color: c.muted),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
              Divider(color: c.line2, height: 1),
              InkWell(
                onTap: onAdd,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_rounded, size: 18, color: c.accent),
                      const SizedBox(width: 6),
                      Text('Add item',
                          style: TextStyle(color: c.accent, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (details.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 6),
            child: Text(
              '${details.length - unchecked} of ${details.length} ticked · '
              '${fmtRp(total, currency)} — the amount above follows this total.',
              style: TextStyle(color: c.muted, fontSize: 11),
            ),
          ),
      ],
    );
  }

  static String _qtyLabel(double qty) =>
      qty == qty.roundToDouble() ? qty.round().toString() : qty.toString();
}

/// Bottom sheet for creating or editing a single line item.
class _DetailEditorSheet extends StatefulWidget {
  final TransactionDetail? detail;
  final String Function() newId;

  const _DetailEditorSheet({required this.detail, required this.newId});

  @override
  State<_DetailEditorSheet> createState() => _DetailEditorSheetState();
}

class _DetailEditorSheetState extends State<_DetailEditorSheet> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _qtyCtl;
  late final TextEditingController _priceCtl;
  late final TextEditingController _noteCtl;

  @override
  void initState() {
    super.initState();
    final d = widget.detail;
    _nameCtl = TextEditingController(text: d?.itemName ?? '');
    _qtyCtl = TextEditingController(text: _fmt(d?.quantity ?? 1));
    _priceCtl =
        TextEditingController(text: d == null ? '' : _fmt(d.unitPrice));
    _noteCtl = TextEditingController(text: d?.note ?? '');
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _qtyCtl.dispose();
    _priceCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  static String _fmt(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2);

  void _submit() {
    final name = _nameCtl.text.trim();
    final quantity =
        double.tryParse(_qtyCtl.text.replaceAll(',', '.')) ?? 1;
    final unitPrice =
        double.tryParse(_priceCtl.text.replaceAll(',', '.')) ?? 0;
    if (name.isEmpty || unitPrice <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Item name and a price are required.')),
      );
      return;
    }
    final qty = quantity <= 0 ? 1.0 : quantity;
    final existing = widget.detail;
    Navigator.pop(
      context,
      TransactionDetail(
        id: existing?.id ?? widget.newId(),
        transactionId: existing?.transactionId ?? '',
        itemName: name,
        quantity: qty,
        unitPrice: unitPrice,
        amount: qty * unitPrice,
        note: _noteCtl.text.trim(),
        syncState: 'pending',
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.detail == null ? 'Add item' : 'Edit item',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700, color: c.ink),
            ),
            const SizedBox(height: 14),
            _SheetField(
                label: 'Item name', controller: _nameCtl, c: c, autofocus: true),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: _SheetField(
                      label: 'Qty', controller: _qtyCtl, c: c, numeric: true),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SheetField(
                      label: 'Unit price',
                      controller: _priceCtl,
                      c: c,
                      numeric: true),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _SheetField(label: 'Note (optional)', controller: _noteCtl, c: c),
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
                child: const Text('Save item',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final AppColors c;
  final bool numeric;
  final bool autofocus;

  const _SheetField({
    required this.label,
    required this.controller,
    required this.c,
    this.numeric = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]
          : null,
      style: TextStyle(fontSize: 15, color: c.ink),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: c.muted, fontSize: 13),
        filled: true,
        fillColor: c.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: c.line, width: 0.5)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: c.line, width: 0.5)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}
