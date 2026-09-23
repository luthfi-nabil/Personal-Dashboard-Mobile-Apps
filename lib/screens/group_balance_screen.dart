import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/group_models.dart';
import '../core/group_service.dart';
import '../core/models.dart';
import '../core/remote_api.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

/// A group's member balances, fetched live. What comes back depends on who
/// asks: the leader gets every member, anyone else only themselves.
final groupBalancesProvider =
    FutureProvider.autoDispose.family<GroupBalances, String>((ref, groupId) {
  ref.watch(configProvider.select((cfg) => cfg.userId));
  return GroupService.instance.balances(groupId);
});

/// The user's own balance inside a group: separate from their personal
/// sources and only spendable on the group.
///
/// Only the member themselves can add to it ("Add balance"); nobody can top
/// up someone else's. Spending from it is a group transaction that shows in
/// the group's transaction list. Every movement is kept as history. The
/// leader also sees every member's balance and history.
class GroupBalanceScreen extends ConsumerWidget {
  final String groupId;
  const GroupBalanceScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final data = ref.watch(appDataProvider).valueOrNull;
    final group = data?.groupById(groupId);
    final balancesAsync = ref.watch(groupBalancesProvider(groupId));
    final me = cfg.username.trim();

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                    onPressed: () => context.pop(),
                  ),
                  Expanded(
                    child: Text(
                      group == null ? 'Group balance' : '${group.name} · balance',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: c.ink),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: group == null || data == null
                  ? Center(
                      child: Text('This group is no longer available.',
                          style: TextStyle(color: c.muted)))
                  : balancesAsync.when(
                      loading: () => Center(
                          child: CircularProgressIndicator(color: c.accent)),
                      error: (e, _) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(e is ApiException ? e.message : '$e',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: c.muted)),
                              TextButton(
                                onPressed: () => ref.invalidate(
                                    groupBalancesProvider(groupId)),
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      data: (balances) => _BalanceBody(
                        group: group,
                        data: data,
                        balances: balances,
                        me: me,
                        currency: cfg.currency,
                        c: c,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalanceBody extends ConsumerWidget {
  final SpendingGroup group;
  final AppData data;
  final GroupBalances balances;
  final String me;
  final String currency;
  final AppColors c;

  const _BalanceBody({
    required this.group,
    required this.data,
    required this.balances,
    required this.me,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = balances.balances
        .where((b) => b.username.toLowerCase() == me.toLowerCase())
        .firstOrNull;
    final others = balances.balances
        .where((b) => b.username.toLowerCase() != me.toLowerCase())
        .toList();
    return RefreshIndicator(
      onRefresh: () => ref.refresh(groupBalancesProvider(group.id).future),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          _MyBalanceCard(
            balance: mine,
            currency: currency,
            c: c,
            onTopUp: () => _topUp(context, ref),
            onSpend: () => _spend(context, ref, mine?.balance ?? 0),
          ),
          if (balances.isLeader) ...[
            const SizedBox(height: 22),
            _Title("Members' balances", c),
            const SizedBox(height: 4),
            Text('Only you, as leader, can see everyone\'s balance.',
                style: TextStyle(fontSize: 12, color: c.muted)),
            const SizedBox(height: 10),
            if (others.isEmpty)
              _Empty('No other members yet.', c)
            else
              _Panel(
                c: c,
                children: [
                  for (final b in others)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(b.username,
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: c.ink)),
                                Text(
                                  'Added ${fmtRp(b.totalTopUp, currency)} · '
                                  'spent ${fmtRp(b.totalSpent, currency)}',
                                  style:
                                      TextStyle(fontSize: 12, color: c.muted),
                                ),
                              ],
                            ),
                          ),
                          Text(fmtRp(b.balance, currency),
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: c.ink)),
                        ],
                      ),
                    ),
                ],
              ),
          ],
          const SizedBox(height: 22),
          _Title(
              balances.isLeader ? 'Balance history (everyone)' : 'Your history',
              c),
          const SizedBox(height: 10),
          if (balances.entries.isEmpty)
            _Empty('No balance movements yet.', c)
          else
            ...balances.entries.map((e) => _EntryTile(
                  entry: e,
                  who: e.username.toLowerCase() == me.toLowerCase()
                      ? 'You'
                      : e.username,
                  currency: currency,
                  c: c,
                )),
        ],
      ),
    );
  }

  Future<void> _topUp(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_AmountDraft>(
      context: context,
      builder: (_) => _AmountDialog(
        title: 'Add balance',
        action: 'Add',
        note: 'Goes to your own balance in ${group.name}. It can only be '
            'spent on this group.',
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => GroupService.instance
          .topUp(group.id, result.amount, description: result.description),
      done: 'Balance added.',
    );
  }

  Future<void> _spend(
      BuildContext context, WidgetRef ref, double available) async {
    final result = await showDialog<_AmountDraft>(
      context: context,
      builder: (_) => _AmountDialog(
        title: 'New group transaction',
        action: 'Save',
        note: 'Paid from your group balance '
            '(${fmtRp(available, currency)} available) and added to '
            '${group.name}\'s transactions.',
        categories:
            data.categories.where((cat) => cat.kind == 'spending').toList(),
        max: available,
      ),
    );
    if (result == null || !context.mounted) return;
    final category = result.category!;
    await _run(
      context,
      ref,
      () => GroupService.instance.spendFromBalance(
        groupId: group.id,
        amount: result.amount,
        categoryId: category.id,
        category: category.name,
        description: result.description,
      ),
      done: 'Group transaction saved.',
      // The group's transaction list comes with the app data.
      refreshAppData: true,
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action, {
    required String done,
    bool refreshAppData = false,
  }) async {
    try {
      await action();
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    ref.invalidate(groupBalancesProvider(group.id));
    if (refreshAppData) {
      await ref.read(appDataProvider.notifier).refreshFromServer();
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    }
  }
}

class _MyBalanceCard extends StatelessWidget {
  final GroupMemberBalance? balance;
  final String currency;
  final AppColors c;
  final VoidCallback onTopUp;
  final VoidCallback onSpend;

  const _MyBalanceCard({
    required this.balance,
    required this.currency,
    required this.c,
    required this.onTopUp,
    required this.onSpend,
  });

  @override
  Widget build(BuildContext context) {
    final value = balance?.balance ?? 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your group balance',
              style: TextStyle(fontSize: 12, color: c.muted)),
          const SizedBox(height: 4),
          Text(fmtRp(value, currency),
              style: TextStyle(
                  fontSize: 28, fontWeight: FontWeight.w700, color: c.ink)),
          const SizedBox(height: 4),
          Text(
            'Added ${fmtRp(balance?.totalTopUp ?? 0, currency)} · '
            'spent ${fmtRp(balance?.totalSpent ?? 0, currency)}',
            style: TextStyle(fontSize: 12, color: c.ink2),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onTopUp,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add balance'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: value > 0 ? onSpend : null,
                  icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                  label: const Text('Spend'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  final GroupBalanceEntry entry;
  final String who;
  final String currency;
  final AppColors c;

  const _EntryTile({
    required this.entry,
    required this.who,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final positive = entry.amount >= 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(
              entry.isTopUp
                  ? Icons.add_circle_outline_rounded
                  : Icons.shopping_bag_outlined,
              size: 20,
              color: entry.isTopUp ? c.pos : c.neg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    entry.description.isEmpty
                        ? (entry.isTopUp ? 'Add balance' : 'Group transaction')
                        : entry.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink)),
                const SizedBox(height: 2),
                Text(
                  [
                    who,
                    entry.isTopUp ? 'added' : 'spent',
                    if (entry.category.isNotEmpty) entry.category,
                    fmtDate(entry.createdDate, 'long'),
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ],
            ),
          ),
          Text(
            '${positive ? '+' : '−'}${fmtRp(entry.amount.abs(), currency)}',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: positive ? c.pos : c.neg),
          ),
        ],
      ),
    );
  }
}

class _AmountDraft {
  final double amount;
  final String description;
  final Category? category;
  const _AmountDraft(this.amount, this.description, this.category);
}

/// Amount + note, and a spending category when [categories] is given.
class _AmountDialog extends StatefulWidget {
  final String title;
  final String action;
  final String note;
  final List<Category>? categories;

  /// Upper bound for the amount, e.g. the balance available to spend.
  final double? max;

  const _AmountDialog({
    required this.title,
    required this.action,
    required this.note,
    this.categories,
    this.max,
  });

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  final _amount = TextEditingController();
  final _description = TextEditingController();
  String? _categoryId;

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', '.'));
    final categories = widget.categories;
    final category =
        categories?.where((cat) => cat.id == _categoryId).firstOrNull;
    final tooMuch =
        amount != null && widget.max != null && amount > widget.max! + 0.000001;
    final valid = amount != null &&
        amount > 0 &&
        !tooMuch &&
        (categories == null || category != null);
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              decoration: InputDecoration(
                labelText: 'Amount',
                errorText: tooMuch ? 'More than your group balance' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (categories != null)
              DropdownButtonFormField<String>(
                initialValue: _categoryId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final cat in categories)
                    DropdownMenuItem(value: cat.id, child: Text(cat.name)),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            TextField(
              controller: _description,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                  labelText: categories == null
                      ? 'Note (optional)'
                      : 'Description (optional)'),
            ),
            const SizedBox(height: 10),
            Text(widget.note,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: valid
              ? () => Navigator.pop(
                    context,
                    _AmountDraft(amount, _description.text.trim(), category),
                  )
              : null,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

class _Title extends StatelessWidget {
  final String text;
  final AppColors c;
  const _Title(this.text, this.c);

  @override
  Widget build(BuildContext context) => Text(text,
      style:
          TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.ink));
}

class _Empty extends StatelessWidget {
  final String text;
  final AppColors c;
  const _Empty(this.text, this.c);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 13, color: c.muted, height: 1.4)),
      );
}

class _Panel extends StatelessWidget {
  final AppColors c;
  final List<Widget> children;
  const _Panel({required this.c, required this.children});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children),
      );
}
