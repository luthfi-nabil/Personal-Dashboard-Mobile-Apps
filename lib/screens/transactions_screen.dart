import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/receipt_scanner.dart';
import '../core/repo.dart';
import '../core/remote_api.dart';
import '../core/utils.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';
import '../widgets/txn_tile.dart';

class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  String _typeFilter = 'all';
  String _sourceFilter = 'all';
  String _categoryFilter = 'all';
  String _q = '';
  final Set<String> _hiddenTransactionIds = {};
  final _searchCtl = TextEditingController();

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  List<Transaction> _filter(
      List<Transaction> txns, List<Source> sources, List<Category> cats) {
    return txns.where((t) {
      if (_typeFilter != 'all' && t.type != _typeFilter) return false;
      if (_sourceFilter != 'all') {
        final match = t.source == _sourceFilter ||
            t.fromSource == _sourceFilter ||
            t.toSource == _sourceFilter;
        if (!match) return false;
      }
      if (_categoryFilter != 'all' && t.category != _categoryFilter) {
        return false;
      }
      if (_q.isNotEmpty &&
          !(t.description.toLowerCase().contains(_q.toLowerCase()))) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<bool> _confirmDelete(Transaction t) async {
    final label = t.type == 'transfer'
        ? 'transfer'
        : t.type == 'earning'
            ? 'earning'
            : 'spending';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: Text('This removes the $label "${t.description}".'),
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
    return confirmed == true;
  }

  Future<void> _deleteTransaction(Transaction t) async {
    setState(() => _hiddenTransactionIds.add(t.id));
    try {
      await Repo.instance.deleteTransaction(t);
    } catch (e) {
      if (!mounted) return;
      setState(() => _hiddenTransactionIds.remove(t.id));
      final message =
          e is ApiException ? e.message : 'Could not delete transaction.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
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
        try {
          final visibleTransactions = data.transactions
              .where((t) => !_hiddenTransactionIds.contains(t.id))
              .toList();
          final filtered =
              _filter(visibleTransactions, data.sources, data.categories);
          final groups = groupByDay(filtered);

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  children: [
                    // Search
                    Row(
                      children: [
                        Expanded(child: _searchField(c)),
                        if (ReceiptScanner.isSupported) ...[
                          const SizedBox(width: 8),
                          _ScanEntryButton(c: c),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Filters row
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _FilterChip(
                            label: _typeFilterLabel(_typeFilter),
                            items: const [
                              'all',
                              'earning',
                              'spending',
                              'transfer'
                            ],
                            labels: const [
                              'All types',
                              'Earnings',
                              'Spending',
                              'Transfers'
                            ],
                            value: _typeFilter,
                            onChanged: (v) => setState(() => _typeFilter = v),
                            c: c,
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: _sourceFilter == 'all'
                                ? 'All sources'
                                : _sourceFilter,
                            items: ['all', ...data.sources.map((s) => s.name)],
                            labels: [
                              'All sources',
                              ...data.sources.map((s) => s.name)
                            ],
                            value: _sourceFilter,
                            onChanged: (v) => setState(() => _sourceFilter = v),
                            c: c,
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: _categoryFilter == 'all'
                                ? 'All categories'
                                : _categoryFilter,
                            items: [
                              'all',
                              ...data.categories.map((c) => c.name)
                            ],
                            labels: [
                              'All categories',
                              ...data.categories.map((c) => c.name)
                            ],
                            value: _categoryFilter,
                            onChanged: (v) =>
                                setState(() => _categoryFilter = v),
                            c: c,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: groups.isEmpty
                    ? Center(
                        child: Text('Nothing matches',
                            style: TextStyle(color: c.muted, fontSize: 13)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: groups.length,
                        itemBuilder: (context, i) {
                          final group = groups[i];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                                child: Text(
                                  fmtDate(group.day, 'long'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: c.muted,
                                    letterSpacing: 0.06,
                                  ),
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  color: c.surface,
                                  borderRadius: BorderRadius.circular(14),
                                  border:
                                      Border.all(color: c.line2, width: 0.5),
                                ),
                                clipBehavior: Clip.hardEdge,
                                child: Column(
                                  children: group.txns
                                      .map((t) => TxnTile(
                                            t: t,
                                            currency: cfg.currency,
                                            onTap: () =>
                                                context.push('/add/${t.id}'),
                                            onDelete: () async {
                                              if (await _confirmDelete(t)) {
                                                await _deleteTransaction(t);
                                              }
                                            },
                                          ))
                                      .toList(),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          );
        } catch (e) {
          return _ScreenError(c: c, message: 'Transactions screen error: $e');
        }
      },
    );
  }

  Widget _searchField(AppColors c) => Container(
        height: 42,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.search, size: 18, color: c.muted),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchCtl,
                style: TextStyle(fontSize: 14, color: c.ink),
                decoration: InputDecoration(
                  hintText: 'Search description…',
                  hintStyle: TextStyle(color: c.muted, fontSize: 14),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            if (_q.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _searchCtl.clear();
                  setState(() => _q = '');
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.close, size: 16, color: c.muted),
                ),
              ),
          ],
        ),
      );

  String _typeFilterLabel(String v) => switch (v) {
        'earning' => 'Earnings',
        'spending' => 'Spending',
        'transfer' => 'Transfers',
        _ => 'All types',
      };
}

/// Entry point to the receipt scanner from the transaction list.
class _ScanEntryButton extends StatelessWidget {
  final AppColors c;
  const _ScanEntryButton({required this.c});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Scan price list',
      child: GestureDetector(
        onTap: () => context.push(
          Uri(path: '/scan-receipt', queryParameters: {'returnTo': '/transactions'})
              .toString(),
        ),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.line2, width: 0.5),
          ),
          child: Icon(Icons.document_scanner_outlined, size: 19, color: c.ink),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final List<String> items;
  final List<String> labels;
  final String value;
  final ValueChanged<String> onChanged;
  final AppColors c;

  const _FilterChip({
    required this.label,
    required this.items,
    required this.labels,
    required this.value,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final result = await showModalBottomSheet<String>(
          context: context,
          backgroundColor: c.surface,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (_) => ListView(
            shrinkWrap: true,
            children: [
              const SizedBox(height: 12),
              ...List.generate(
                  items.length,
                  (i) => ListTile(
                        title: Text(labels[i], style: TextStyle(color: c.ink)),
                        trailing: items[i] == value
                            ? Icon(Icons.check, color: c.accent)
                            : null,
                        onTap: () => Navigator.pop(context, items[i]),
                      )),
              const SizedBox(height: 12),
            ],
          ),
        );
        if (result != null) onChanged(result);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 13, color: c.ink)),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: c.muted),
          ],
        ),
      ),
    );
  }
}

class _ScreenError extends StatelessWidget {
  final AppColors c;
  final String message;

  const _ScreenError({required this.c, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Text(
          message,
          style: TextStyle(color: c.neg, fontSize: 13),
        ),
      ),
    );
  }
}
