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
import 'group_balance_screen.dart';

/// Group routines, their payments and planned expenses, fetched live.
final groupPlansProvider = FutureProvider.autoDispose<GroupPlans>((ref) {
  ref.watch(configProvider.select((cfg) => cfg.userId));
  return GroupService.instance.loadPlans();
});

const _reminders = ['weekly', 'monthly', 'bi-monthly', 'quarterly', 'yearly'];

/// A group's shared routines and planned expenses.
///
/// The leader adds routines and planned expenses freely; a member can only
/// request a planned expense, which waits for the leader's approval. Whoever
/// pays a routine or buys a planned item pays it from their own source: it is
/// saved as their spending (lowering that source's balance) and shows in the
/// group's transaction history as well.
class GroupPlansScreen extends ConsumerWidget {
  final String groupId;
  const GroupPlansScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final data = ref.watch(appDataProvider).valueOrNull;
    final plansAsync = ref.watch(groupPlansProvider);
    final group = data?.groupById(groupId);
    final me = cfg.username.trim();
    final isLeader = group != null && group.leader == me;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
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
                        group == null
                            ? 'Routines & plans'
                            : '${group.name} · plans',
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
              TabBar(
                labelColor: c.ink,
                unselectedLabelColor: c.muted,
                indicatorColor: c.accent,
                tabs: const [
                  Tab(text: 'Routines'),
                  Tab(text: 'Planned expenses'),
                ],
              ),
              Expanded(
                child: group == null || data == null
                    ? Center(
                        child: Text('This group is no longer available.',
                            style: TextStyle(color: c.muted)))
                    : plansAsync.when(
                        loading: () => Center(
                            child:
                                CircularProgressIndicator(color: c.accent)),
                        error: (e, _) => _ErrorPanel(
                          message: e is ApiException ? e.message : '$e',
                          c: c,
                          onRetry: () => ref.invalidate(groupPlansProvider),
                        ),
                        data: (plans) => TabBarView(
                          children: [
                            _RoutinesTab(
                              group: group,
                              data: data,
                              plans: plans,
                              isLeader: isLeader,
                              me: me,
                              currency: cfg.currency,
                              c: c,
                            ),
                            _PlannedTab(
                              group: group,
                              data: data,
                              plans: plans,
                              isLeader: isLeader,
                              me: me,
                              currency: cfg.currency,
                              c: c,
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs [action], then reloads the plans - and the whole app data when money
/// moved, so the new spending shows in personal records and the group recap.
Future<bool> _run(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action, {
  required String done,
  bool movedMoney = false,
}) async {
  try {
    await action();
  } on ApiException catch (e) {
    if (context.mounted) _snack(context, e.message);
    return false;
  }
  ref.invalidate(groupPlansProvider);
  if (movedMoney) {
    ref.invalidate(groupBalancesProvider);
    await ref.read(appDataProvider.notifier).refreshFromServer();
  }
  if (context.mounted) _snack(context, done);
  return true;
}

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));

// ── Routines ──────────────────────────────────────────────────────────────

class _RoutinesTab extends ConsumerWidget {
  final SpendingGroup group;
  final AppData data;
  final GroupPlans plans;
  final bool isLeader;
  final String me;
  final String currency;
  final AppColors c;

  const _RoutinesTab({
    required this.group,
    required this.data,
    required this.plans,
    required this.isLeader,
    required this.me,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routines = plans.routinesOf(group.id);
    final payments = plans.paymentsOf(group.id);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(groupPlansProvider.future),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isLeader
                      ? 'Shared recurring costs. Whoever pays one pays from '
                          'their own source.'
                      : 'Only ${group.leader} (leader) can add routines. '
                          'Anyone can pay one from their own source.',
                  style: TextStyle(fontSize: 12, color: c.muted, height: 1.4),
                ),
              ),
              if (isLeader)
                TextButton.icon(
                  onPressed: () => _editRoutine(context, ref),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (routines.isEmpty)
            _EmptyPanel(
                c: c,
                text: isLeader
                    ? 'No routines yet. Add rent, internet or anything the '
                        'group pays regularly.'
                    : 'No routines yet.')
          else
            ...routines.map((r) => _RoutineTile(
                  routine: r,
                  currency: currency,
                  isLeader: isLeader,
                  me: me,
                  c: c,
                  onPay: () => _pay(context, ref, r),
                  onEdit: () => _editRoutine(context, ref, existing: r),
                  onDelete: () => _delete(context, ref, r),
                )),
          const SizedBox(height: 22),
          Text('Payments (${payments.length})',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: c.ink)),
          const SizedBox(height: 10),
          if (payments.isEmpty)
            _EmptyPanel(c: c, text: 'Nobody has paid a routine yet.')
          else
            ...payments.map((p) => _Row(
                  title: p.itemName,
                  subtitle: [
                    p.paidBy == me ? 'You' : p.paidBy,
                    p.source,
                    fmtDate(p.paidAt, 'long'),
                  ].join(' · '),
                  amount: '−${fmtRp(p.price, currency)}',
                  amountColor: c.neg,
                  c: c,
                )),
        ],
      ),
    );
  }

  Future<void> _pay(
      BuildContext context, WidgetRef ref, GroupRoutine routine) async {
    final result = await showDialog<_Payment>(
      context: context,
      builder: (_) => _PayDialog(
        title: 'Pay ${routine.itemName}',
        price: routine.price,
        sources: data.sources,
        groupName: group.name,
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => GroupService.instance.payRoutine(routine,
          price: result.price, sourceId: result.sourceId),
      done: 'Paid ${routine.itemName}.',
      movedMoney: true,
    );
  }

  Future<void> _editRoutine(BuildContext context, WidgetRef ref,
      {GroupRoutine? existing}) async {
    final result = await showDialog<_ItemDraft>(
      context: context,
      builder: (_) => _ItemDialog(
        title: existing == null ? 'New group routine' : 'Edit routine',
        action: existing == null ? 'Add' : 'Save',
        categories:
            data.categories.where((cat) => cat.kind == 'spending').toList(),
        withReminder: true,
        initial: existing == null
            ? null
            : _ItemDraft(
                name: existing.itemName,
                price: existing.price,
                categoryId: existing.categoryId,
                category: existing.category,
                reminder: existing.reminder,
              ),
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => GroupService.instance.saveRoutine(
        groupId: group.id,
        routineId: existing?.id,
        itemName: result.name,
        price: result.price,
        reminder: result.reminder,
        categoryId: result.categoryId,
        category: result.category,
      ),
      done: existing == null ? 'Routine added.' : 'Routine saved.',
    );
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, GroupRoutine routine) async {
    final ok = await _confirm(context,
        title: 'Remove ${routine.itemName}?',
        body: 'Past payments stay in everyone\'s records.',
        action: 'Remove');
    if (!ok || !context.mounted) return;
    await _run(
      context,
      ref,
      () => GroupService.instance.deleteRoutine(routine),
      done: 'Routine removed.',
    );
  }
}

class _RoutineTile extends StatelessWidget {
  final GroupRoutine routine;
  final String currency;
  final bool isLeader;
  final String me;
  final AppColors c;
  final VoidCallback onPay;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _RoutineTile({
    required this.routine,
    required this.currency,
    required this.isLeader,
    required this.me,
    required this.c,
    required this.onPay,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final lastPaid = routine.lastPaidAt == null
        ? 'Not paid yet'
        : 'Last paid ${fmtDate(routine.lastPaidAt!, 'long')} by '
            '${routine.lastPaidBy == me ? 'you' : routine.lastPaidBy}';
    return _Card(
      c: c,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(routine.itemName,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.ink)),
                const SizedBox(height: 3),
                Text(
                  '${fmtRp(routine.price, currency)} · ${routine.reminder}'
                  '${routine.category.isEmpty ? '' : ' · ${routine.category}'}',
                  style: TextStyle(fontSize: 12, color: c.ink2),
                ),
                const SizedBox(height: 2),
                Text(lastPaid, style: TextStyle(fontSize: 12, color: c.muted)),
              ],
            ),
          ),
          if (isLeader)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: c.muted),
              onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Remove')),
              ],
            ),
          FilledButton.tonal(onPressed: onPay, child: const Text('Pay')),
        ],
      ),
    );
  }
}

// ── Planned expenses ──────────────────────────────────────────────────────

class _PlannedTab extends ConsumerWidget {
  final SpendingGroup group;
  final AppData data;
  final GroupPlans plans;
  final bool isLeader;
  final String me;
  final String currency;
  final AppColors c;

  const _PlannedTab({
    required this.group,
    required this.data,
    required this.plans,
    required this.isLeader,
    required this.me,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = plans.plannedExpensesOf(group.id);
    final requests = items.where((i) => i.isRequested).toList();
    final planned = items.where((i) => i.isPlanned).toList();
    final history = items.where((i) => !i.isOpen).toList();
    return RefreshIndicator(
      onRefresh: () => ref.refresh(groupPlansProvider.future),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isLeader
                      ? 'Things the group will buy. Members\' requests wait '
                          'for your approval.'
                      : 'Things the group will buy. Your requests wait for '
                          '${group.leader} (leader) to approve them.',
                  style: TextStyle(fontSize: 12, color: c.muted, height: 1.4),
                ),
              ),
              TextButton.icon(
                onPressed: () => _add(context, ref),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(isLeader ? 'Add' : 'Request'),
              ),
            ],
          ),
          if (requests.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Section('Requests (${requests.length})', c),
            ...requests.map((item) => _PlannedTile(
                  item: item,
                  currency: currency,
                  me: me,
                  c: c,
                  actions: [
                    if (isLeader) ...[
                      TextButton(
                        onPressed: () => _review(context, ref, item, false),
                        child: const Text('Reject'),
                      ),
                      FilledButton.tonal(
                        onPressed: () => _review(context, ref, item, true),
                        child: const Text('Approve'),
                      ),
                    ] else if (item.requestedBy == me)
                      TextButton(
                        onPressed: () => _cancel(context, ref, item),
                        child: const Text('Withdraw'),
                      ),
                  ],
                )),
          ],
          const SizedBox(height: 12),
          _Section('Planned (${planned.length})', c),
          if (planned.isEmpty)
            _EmptyPanel(c: c, text: 'Nothing planned right now.')
          else
            ...planned.map((item) => _PlannedTile(
                  item: item,
                  currency: currency,
                  me: me,
                  c: c,
                  actions: [
                    if (isLeader)
                      TextButton(
                        onPressed: () => _cancel(context, ref, item),
                        child: const Text('Cancel'),
                      ),
                    FilledButton.tonal(
                      onPressed: () => _fulfill(context, ref, item),
                      child: const Text('Buy'),
                    ),
                  ],
                )),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Section('History', c),
            ...history.map((item) => _PlannedTile(
                  item: item,
                  currency: currency,
                  me: me,
                  c: c,
                  actions: const [],
                )),
          ],
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_ItemDraft>(
      context: context,
      builder: (_) => _ItemDialog(
        title: isLeader ? 'New planned expense' : 'Request a planned expense',
        action: isLeader ? 'Add' : 'Send request',
        categories:
            data.categories.where((cat) => cat.kind == 'spending').toList(),
        withNotes: true,
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => GroupService.instance.addPlannedExpense(
        groupId: group.id,
        itemName: result.name,
        price: result.price,
        categoryId: result.categoryId,
        category: result.category,
        notes: result.notes,
      ),
      done: isLeader
          ? 'Planned expense added.'
          : 'Request sent to ${group.leader}.',
    );
  }

  Future<void> _review(BuildContext context, WidgetRef ref,
      GroupPlannedExpense item, bool approve) async {
    await _run(
      context,
      ref,
      () => GroupService.instance.reviewPlannedExpense(item, approve),
      done: approve ? 'Approved ${item.itemName}.' : 'Request rejected.',
    );
  }

  Future<void> _cancel(
      BuildContext context, WidgetRef ref, GroupPlannedExpense item) async {
    final ok = await _confirm(context,
        title: 'Cancel ${item.itemName}?',
        body: 'It stays in the history as canceled.',
        action: 'Cancel item');
    if (!ok || !context.mounted) return;
    await _run(
      context,
      ref,
      () => GroupService.instance.cancelPlannedExpense(item),
      done: 'Canceled.',
    );
  }

  Future<void> _fulfill(
      BuildContext context, WidgetRef ref, GroupPlannedExpense item) async {
    final result = await showDialog<_Payment>(
      context: context,
      builder: (_) => _PayDialog(
        title: 'Buy ${item.itemName}',
        price: item.price,
        sources: data.sources,
        groupName: group.name,
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => GroupService.instance.fulfillPlannedExpense(item,
          price: result.price, sourceId: result.sourceId),
      done: 'Bought ${item.itemName}.',
      movedMoney: true,
    );
  }
}

class _PlannedTile extends StatelessWidget {
  final GroupPlannedExpense item;
  final String currency;
  final String me;
  final AppColors c;
  final List<Widget> actions;

  const _PlannedTile({
    required this.item,
    required this.currency,
    required this.me,
    required this.c,
    required this.actions,
  });

  String _who(String name) => name == me ? 'you' : name;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (item.status) {
      'requested' => ('Requested', c.transfer),
      'planned' => ('Planned', c.accent),
      'fulfilled' => ('Bought', c.pos),
      'rejected' => ('Rejected', c.neg),
      _ => ('Canceled', c.muted),
    };
    final detail = switch (item.status) {
      'fulfilled' =>
        'Bought by ${_who(item.fulfilledBy ?? '')} for '
            '${fmtRp(item.fulfilledPrice ?? item.price, currency)}'
            '${item.fulfilledAt == null ? '' : ' · ${fmtDate(item.fulfilledAt!, 'long')}'}',
      'rejected' => 'Rejected by ${_who(item.reviewedBy ?? '')}',
      _ => 'Requested by ${_who(item.requestedBy)}'
          '${item.reviewedBy != null && item.reviewedBy != item.requestedBy ? ' · approved by ${_who(item.reviewedBy!)}' : ''}',
    };
    return _Card(
      c: c,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.itemName,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.ink)),
              ),
              _Chip(label: label, color: color),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${fmtRp(item.price, currency)}'
            '${item.category.isEmpty ? '' : ' · ${item.category}'}',
            style: TextStyle(fontSize: 12, color: c.ink2),
          ),
          if (item.notes.isNotEmpty)
            Text(item.notes, style: TextStyle(fontSize: 12, color: c.ink2)),
          const SizedBox(height: 2),
          Text(detail, style: TextStyle(fontSize: 12, color: c.muted)),
          if (actions.isNotEmpty)
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              for (final a in actions) ...[const SizedBox(width: 6), a],
            ]),
        ],
      ),
    );
  }
}

// ── Dialogs ───────────────────────────────────────────────────────────────

class _Payment {
  final double price;

  /// One of the user's own sources, or null for their group balance.
  final String? sourceId;
  const _Payment(this.price, this.sourceId);
}

/// Dropdown value standing for "my balance in this group".
const _groupBalanceChoice = '__group_balance__';

/// Asks how much was paid and where it comes from: one of the user's own
/// sources, or their balance in this group.
class _PayDialog extends StatefulWidget {
  final String title;
  final double price;
  final List<Source> sources;
  final String groupName;

  const _PayDialog({
    required this.title,
    required this.price,
    required this.sources,
    required this.groupName,
  });

  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  late final TextEditingController _price =
      TextEditingController(text: _formatAmount(widget.price));
  String? _choice;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final price = _parseAmount(_price.text);
    final canPay = price != null && price > 0 && _choice != null;
    final fromBalance = _choice == _groupBalanceChoice;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
            ],
            decoration: const InputDecoration(labelText: 'Amount paid'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _choice,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Pay from'),
            items: [
              const DropdownMenuItem(
                  value: _groupBalanceChoice,
                  child: Text('My group balance')),
              for (final s in widget.sources)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (v) => setState(() => _choice = v),
          ),
          const SizedBox(height: 10),
          Text(
              fromBalance
                  ? 'Taken from your balance in ${widget.groupName} and '
                      'added to its transactions. Your own sources are not '
                      'touched.'
                  : 'Saved as your spending and added to '
                      '${widget.groupName}\'s transactions.',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: canPay
              ? () => Navigator.pop(
                  context, _Payment(price, fromBalance ? null : _choice))
              : null,
          child: const Text('Pay'),
        ),
      ],
    );
  }
}

class _ItemDraft {
  final String name;
  final double price;
  final String categoryId;
  final String category;
  final String reminder;
  final String notes;

  const _ItemDraft({
    required this.name,
    required this.price,
    required this.categoryId,
    required this.category,
    this.reminder = 'monthly',
    this.notes = '',
  });
}

/// Name, price and spending category of a routine or planned expense.
class _ItemDialog extends StatefulWidget {
  final String title;
  final String action;
  final List<Category> categories;
  final bool withReminder;
  final bool withNotes;
  final _ItemDraft? initial;

  const _ItemDialog({
    required this.title,
    required this.action,
    required this.categories,
    this.withReminder = false,
    this.withNotes = false,
    this.initial,
  });

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController _price = TextEditingController(
      text: widget.initial == null ? '' : _formatAmount(widget.initial!.price));
  late final TextEditingController _notes =
      TextEditingController(text: widget.initial?.notes ?? '');
  late String? _categoryId = widget.categories
          .any((cat) => cat.id == widget.initial?.categoryId)
      ? widget.initial!.categoryId
      : null;
  late String _reminder = widget.initial?.reminder ?? 'monthly';

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final price = _parseAmount(_price.text);
    final category =
        widget.categories.where((cat) => cat.id == _categoryId).firstOrNull;
    final valid = _name.text.trim().isNotEmpty &&
        price != null &&
        price > 0 &&
        category != null;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.initial == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Item'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _price,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              decoration: const InputDecoration(labelText: 'Price'),
              onChanged: (_) => setState(() {}),
            ),
            DropdownButtonFormField<String>(
              initialValue: _categoryId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final cat in widget.categories)
                  DropdownMenuItem(value: cat.id, child: Text(cat.name)),
              ],
              onChanged: (v) => setState(() => _categoryId = v),
            ),
            if (widget.withReminder)
              DropdownButtonFormField<String>(
                initialValue: _reminder,
                decoration: const InputDecoration(labelText: 'Repeats'),
                items: [
                  for (final r in _reminders)
                    DropdownMenuItem(value: r, child: Text(r)),
                ],
                onChanged: (v) => setState(() => _reminder = v ?? 'monthly'),
              ),
            if (widget.withNotes)
              TextField(
                controller: _notes,
                decoration:
                    const InputDecoration(labelText: 'Notes (optional)'),
              ),
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
                    _ItemDraft(
                      name: _name.text.trim(),
                      price: price,
                      categoryId: category.id,
                      category: category.name,
                      reminder: _reminder,
                      notes: _notes.text.trim(),
                    ),
                  )
              : null,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

Future<bool> _confirm(BuildContext context,
    {required String title,
    required String body,
    required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Back')),
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

String _formatAmount(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(2);

double? _parseAmount(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));

// ── Small building blocks ─────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final AppColors c;
  final Widget child;
  const _Card({required this.c, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: child,
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String subtitle;
  final String amount;
  final Color amountColor;
  final AppColors c;

  const _Row({
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.amountColor,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      c: c,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(fontSize: 12, color: c.muted)),
              ],
            ),
          ),
          Text(amount,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: amountColor)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  final AppColors c;
  const _Section(this.text, this.c);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: c.ink)),
      );
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  final String text;
  final AppColors c;
  const _EmptyPanel({required this.text, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 13, color: c.muted, height: 1.4)),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final String message;
  final AppColors c;
  final VoidCallback onRetry;
  const _ErrorPanel(
      {required this.message, required this.c, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted)),
            const SizedBox(height: 10),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
