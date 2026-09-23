import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/remote_api.dart';
import '../core/repo.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

/// Shared ledgers several users tag their own spendings/earnings into.
///
/// Members tag a transaction from the Add-transaction screen; it stays in
/// their personal records and the group only sees it through the recap here.
/// The leader can switch a group off, which hides it from the Add-transaction
/// screen but keeps the recap readable. Anything tagged while a group was off
/// (e.g. entered offline before the switch reached that device) is counted
/// separately as "after turned off".
class GroupSpendingsScreen extends ConsumerWidget {
  const GroupSpendingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) {
        final me = cfg.username.trim();
        final thisMonth = isoMonth(DateTime.now().toIso8601String());
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text('Group Spendings',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: c.ink)),
                ),
                TextButton.icon(
                  onPressed: () => _createGroup(context, ref),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('New'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Spendings and earnings several people put together. Tag a '
              'transaction into a group when adding it - it stays in your own '
              'records too.',
              style: TextStyle(color: c.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            if (data.spendingGroups.isEmpty)
              _EmptyPanel(
                  c: c,
                  text: 'No groups yet. Create one, then add the people who '
                      'share it.')
            else
              ...data.spendingGroups.map((group) {
                final rows = data
                    .groupTransactionsFor(group.id, me)
                    .where((t) =>
                        isoMonth(t.date) == thisMonth &&
                        !data.isAfterTurnedOff(t))
                    .toList();
                final totals = _Totals()..addAll(rows);
                return _GroupCard(
                  group: group,
                  active: data.isGroupActive(group.id),
                  isLeader: group.leader == me,
                  memberCount: data.membersOf(group.id).length,
                  monthTotals: totals,
                  currency: cfg.currency,
                  c: c,
                  onTap: () => context.push('/group-spendings/${group.id}'),
                  onToggle: (value) =>
                      setGroupActive(context, ref, group, value),
                );
              }),
          ],
        );
      },
    );
  }

  Future<void> _createGroup(BuildContext context, WidgetRef ref) async {
    final name = await _promptText(
      context,
      title: 'New group',
      label: 'Group name',
      hint: 'e.g. Household, Trip to Bali',
      action: 'Create',
    );
    if (name == null) return;
    try {
      await Repo.instance.createSpendingGroup(name);
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
      return;
    }
    await ref.read(appDataProvider.notifier).refresh();
  }
}

/// Recap of one group: totals, per member, per category, per month, and every
/// tagged transaction.
class GroupSpendingDetailScreen extends ConsumerStatefulWidget {
  final String groupId;
  const GroupSpendingDetailScreen({super.key, required this.groupId});

  @override
  ConsumerState<GroupSpendingDetailScreen> createState() =>
      _GroupSpendingDetailScreenState();
}

class _GroupSpendingDetailScreenState
    extends ConsumerState<GroupSpendingDetailScreen> {
  /// `yyyy-MM`, or null for all time.
  String? _month = isoMonth(DateTime.now().toIso8601String());

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: dataAsync.when(
          loading: () =>
              Center(child: CircularProgressIndicator(color: c.accent)),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (data) {
            final group = data.groupById(widget.groupId);
            if (group == null) {
              return Column(
                children: [
                  _Header(title: 'Group', c: c),
                  const SizedBox(height: 40),
                  Text('This group is no longer available.',
                      style: TextStyle(color: c.muted)),
                ],
              );
            }
            final me = cfg.username.trim();
            final isLeader = group.leader == me;
            final active = data.isGroupActive(group.id);
            final all = data.groupTransactionsFor(group.id, me);
            final rows = _month == null
                ? all
                : all.where((t) => isoMonth(t.date) == _month).toList();
            final regular =
                rows.where((t) => !data.isAfterTurnedOff(t)).toList();
            final afterOff =
                rows.where((t) => data.isAfterTurnedOff(t)).toList();
            final members = data.membersOf(group.id);

            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(appDataProvider.notifier).refreshFromServer(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                children: [
                  _Header(title: group.name, c: c),
                  _StatusPanel(
                    group: group,
                    active: active,
                    isLeader: isLeader,
                    c: c,
                    onToggle: (value) =>
                        setGroupActive(context, ref, group, value),
                  ),
                  const SizedBox(height: 10),
                  _FeatureLink(
                    icon: Icons.event_repeat_rounded,
                    title: 'Routines & planned expenses',
                    subtitle: isLeader
                        ? 'Add shared routines and plans, review requests'
                        : 'Pay routines, buy or request planned items',
                    c: c,
                    onTap: () =>
                        context.push('/group-spendings/${group.id}/plans'),
                  ),
                  const SizedBox(height: 8),
                  _FeatureLink(
                    icon: Icons.account_balance_wallet_outlined,
                    title: 'Group balance',
                    subtitle: isLeader
                        ? 'Add to your balance, spend it, see everyone\'s'
                        : 'Add to your balance and spend it on the group',
                    c: c,
                    onTap: () =>
                        context.push('/group-spendings/${group.id}/balance'),
                  ),
                  const SizedBox(height: 14),
                  _MonthBar(
                    month: _month,
                    c: c,
                    onChanged: (month) => setState(() => _month = month),
                  ),
                  const SizedBox(height: 12),
                  _SummaryTiles(
                      totals: _Totals()..addAll(regular),
                      currency: cfg.currency,
                      c: c),
                  if (afterOff.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _AfterOffPanel(
                        totals: _Totals()..addAll(afterOff),
                        count: afterOff.length,
                        currency: cfg.currency,
                        c: c),
                  ],
                  const SizedBox(height: 20),
                  _SectionTitle('By member', c),
                  const SizedBox(height: 10),
                  _MemberBreakdown(
                    members: members,
                    rows: regular,
                    leader: group.leader,
                    currency: cfg.currency,
                    c: c,
                  ),
                  const SizedBox(height: 20),
                  _CategoryBreakdown(
                      rows: regular, currency: cfg.currency, c: c),
                  // Always shown, whatever month is picked above: spending
                  // and earning month by month, never netted into one number.
                  const SizedBox(height: 20),
                  _SectionTitle('Monthly spending & earning', c),
                  const SizedBox(height: 10),
                  _MonthlyBreakdown(
                    data: data,
                    rows: all,
                    selected: _month,
                    currency: cfg.currency,
                    c: c,
                    onSelect: (month) => setState(() => _month = month),
                  ),
                  const SizedBox(height: 20),
                  _SectionTitle('Transactions (${rows.length})', c),
                  const SizedBox(height: 10),
                  if (rows.isEmpty)
                    _EmptyPanel(
                        c: c,
                        text: 'Nothing tagged into this group '
                            '${_month == null ? 'yet' : 'this month'}.')
                  else
                    ...rows.map((t) => _GroupTxnTile(
                          txn: t,
                          afterOff: data.isAfterTurnedOff(t),
                          isMine: t.createdBy == me,
                          currency: cfg.currency,
                          c: c,
                        )),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                          child:
                              _SectionTitle('Members (${members.length})', c)),
                      TextButton.icon(
                        onPressed: () =>
                            _addMember(context, group, members),
                        icon: const Icon(Icons.person_add_alt_1_outlined,
                            size: 18),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ...members.map((m) => _MemberTile(
                        member: m,
                        isLeader: m.username == group.leader,
                        isMe: m.username == me,
                        c: c,
                      )),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _addMember(BuildContext context, SpendingGroup group,
      List<GroupMember> members) async {
    final username = await _promptText(
      context,
      title: 'Add member',
      label: 'Username',
      hint: 'Their login username',
      action: 'Add',
    );
    if (username == null) return;
    if (members.any((m) => m.username.toLowerCase() == username.toLowerCase())) {
      if (context.mounted) _snack(context, '$username is already a member.');
      return;
    }
    bool verified;
    try {
      verified = await Repo.instance.addGroupMember(group, username);
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
      return;
    }
    if (context.mounted) {
      _snack(
          context,
          verified
              ? 'Added to ${group.name}.'
              : 'Offline - $username will be checked and added once you '
                  'are back online.');
    }
    await ref.read(appDataProvider.notifier).refresh();
  }
}

/// Leader-only on/off switch, shared by the list and the detail screen.
Future<void> setGroupActive(BuildContext context, WidgetRef ref,
    SpendingGroup group, bool active) async {
  if (!active) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Turn off ${group.name}?'),
        content: const Text(
            'Members can still see the recap, but the group stops being '
            'offered when adding a transaction. Anything tagged after now is '
            'counted separately as "after turned off".'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Turn off')),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  try {
    await Repo.instance.setSpendingGroupActive(group, active);
  } on ApiException catch (e) {
    if (context.mounted) _snack(context, e.message);
    return;
  }
  await ref.read(appDataProvider.notifier).refresh();
}

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String label,
  required String hint,
  required String action,
}) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.none,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onSubmitted: (value) => Navigator.pop(dialogContext, value),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(action)),
      ],
    ),
  );
  controller.dispose();
  final trimmed = result?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// Running spending/earning totals, always kept as two separate numbers.
class _Totals {
  double spend = 0;
  double earn = 0;

  void add(GroupTransaction t) {
    if (t.transactionType == 'earning') {
      earn += t.amount;
    } else {
      spend += t.amount;
    }
  }

  void addAll(Iterable<GroupTransaction> rows) => rows.forEach(add);
}

class _Header extends StatelessWidget {
  final String title;
  final AppColors c;
  const _Header({required this.title, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: c.ink),
            onPressed: () => context.pop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700, color: c.ink)),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final SpendingGroup group;
  final bool active;
  final bool isLeader;
  final int memberCount;
  final _Totals monthTotals;
  final String currency;
  final AppColors c;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  const _GroupCard({
    required this.group,
    required this.active,
    required this.isLeader,
    required this.memberCount,
    required this.monthTotals,
    required this.currency,
    required this.c,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.line2, width: 0.5),
            ),
            child: Row(
              children: [
                Icon(Icons.groups_rounded,
                    color: active ? c.accent : c.muted, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(group.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: c.ink)),
                          ),
                          const SizedBox(width: 6),
                          _Chip(
                              label: active ? 'On' : 'Off',
                              color: active ? c.pos : c.muted),
                          if (group.syncState == 'pending') ...[
                            const SizedBox(width: 4),
                            _Chip(label: 'Pending', color: c.transfer),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${isLeader ? 'You lead' : 'Led by ${group.leader}'}'
                        ' · $memberCount member${memberCount == 1 ? '' : 's'}',
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                      const SizedBox(height: 3),
                      Text.rich(
                        TextSpan(
                          style: TextStyle(fontSize: 12, color: c.ink2),
                          children: [
                            const TextSpan(text: 'This month · Spending '),
                            TextSpan(
                                text: fmtRp(monthTotals.spend, currency),
                                style: TextStyle(color: c.neg)),
                            const TextSpan(text: ' · Earning '),
                            TextSpan(
                                text: fmtRp(monthTotals.earn, currency),
                                style: TextStyle(color: c.pos)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: isLeader
                      ? (active ? 'Turn group off' : 'Turn group on')
                      : 'Only the leader can switch this group',
                  child: Switch(
                    value: active,
                    onChanged: isLeader ? onToggle : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tappable row leading to one of the group's feature screens.
class _FeatureLink extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final AppColors c;
  final VoidCallback onTap;

  const _FeatureLink({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.line2, width: 0.5),
          ),
          child: Row(
            children: [
              Icon(icon, color: c.accent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.ink)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(fontSize: 12, color: c.muted)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  final SpendingGroup group;
  final bool active;
  final bool isLeader;
  final AppColors c;
  final ValueChanged<bool> onToggle;

  const _StatusPanel({
    required this.group,
    required this.active,
    required this.isLeader,
    required this.c,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final text = active
        ? 'On - members can add transactions to this group.'
        : 'Off - hidden when adding transactions. The recap stays readable.';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text,
                    style: TextStyle(fontSize: 13, color: c.ink, height: 1.3)),
                const SizedBox(height: 2),
                Text(
                  isLeader
                      ? 'You are the leader.'
                      : 'Only ${group.leader} (leader) can switch it.',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ],
            ),
          ),
          Switch(value: active, onChanged: isLeader ? onToggle : null),
        ],
      ),
    );
  }
}

class _MonthBar extends StatelessWidget {
  final String? month;
  final AppColors c;
  final ValueChanged<String?> onChanged;

  const _MonthBar(
      {required this.month, required this.c, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final current = month ?? isoMonth(DateTime.now().toIso8601String());
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.chevron_left_rounded, color: c.ink),
          onPressed: month == null ? null : () => onChanged(prevMonth(current)),
        ),
        Expanded(
          child: Text(
            month == null
                ? 'All time'
                : '${monthLabel(current)} ${current.substring(0, 4)}',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
          ),
        ),
        IconButton(
          icon: Icon(Icons.chevron_right_rounded, color: c.ink),
          onPressed: month == null ? null : () => onChanged(nextMonth(current)),
        ),
        TextButton(
          onPressed: () => onChanged(
              month == null ? isoMonth(DateTime.now().toIso8601String()) : null),
          child: Text(month == null ? 'This month' : 'All time'),
        ),
      ],
    );
  }
}

class _SummaryTiles extends StatelessWidget {
  final _Totals totals;
  final String currency;
  final AppColors c;

  const _SummaryTiles(
      {required this.totals, required this.currency, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _MetricTile(
                label: 'Spending',
                value: fmtRp(totals.spend, currency),
                color: c.neg,
                c: c)),
        const SizedBox(width: 8),
        Expanded(
            child: _MetricTile(
                label: 'Earning',
                value: fmtRp(totals.earn, currency),
                color: c.pos,
                c: c)),
      ],
    );
  }
}

/// Totals of transactions tagged while the group was switched off. Kept out
/// of the regular totals above so switching a group off actually closes it.
class _AfterOffPanel extends StatelessWidget {
  final _Totals totals;
  final int count;
  final String currency;
  final AppColors c;

  const _AfterOffPanel({
    required this.totals,
    required this.count,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.transfer.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.transfer.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.power_settings_new_rounded, size: 18, color: c.transfer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('After turned off ($count)',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.ink)),
                const SizedBox(height: 4),
                Text(
                  'Spending ${fmtRp(totals.spend, currency)} · '
                  'Earning ${fmtRp(totals.earn, currency)}',
                  style: TextStyle(fontSize: 13, color: c.ink2),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tagged while the group was off - usually entered offline '
                  'before the switch reached that device. Not included in '
                  'the totals above.',
                  style: TextStyle(fontSize: 12, color: c.muted, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberBreakdown extends StatelessWidget {
  final List<GroupMember> members;
  final List<GroupTransaction> rows;
  final String leader;
  final String currency;
  final AppColors c;

  const _MemberBreakdown({
    required this.members,
    required this.rows,
    required this.leader,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final byMember = <String, _Totals>{
      for (final m in members) m.username: _Totals(),
    };
    for (final t in rows) {
      (byMember[t.createdBy] ??= _Totals()).add(t);
    }
    final grandSpend =
        byMember.values.fold<double>(0, (sum, t) => sum + t.spend);
    final entries = byMember.entries.toList()
      ..sort((a, b) => b.value.spend.compareTo(a.value.spend));

    return _Panel(
      c: c,
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.key == leader ? '${entry.key} ★' : entry.key,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: c.ink),
                      ),
                    ),
                    Text('−${fmtRp(entry.value.spend, currency)}',
                        style: TextStyle(fontSize: 13, color: c.neg)),
                    const SizedBox(width: 10),
                    Text('+${fmtRp(entry.value.earn, currency)}',
                        style: TextStyle(fontSize: 13, color: c.pos)),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: grandSpend <= 0
                        ? 0
                        : (entry.value.spend / grandSpend).clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: c.line2,
                    color: c.neg.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CategoryBreakdown extends StatelessWidget {
  final List<GroupTransaction> rows;
  final String currency;
  final AppColors c;

  const _CategoryBreakdown(
      {required this.rows, required this.currency, required this.c});

  @override
  Widget build(BuildContext context) {
    final byCategory = <String, double>{};
    for (final t in rows.where((t) => t.transactionType != 'earning')) {
      final key = t.category.isEmpty ? 'Uncategorized' : t.category;
      byCategory[key] = (byCategory[key] ?? 0) + t.amount;
    }
    if (byCategory.isEmpty) return const SizedBox.shrink();
    final entries = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle('Spending by category', c),
        const SizedBox(height: 10),
        _Panel(
          c: c,
          children: [
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: catColor(entry.key), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(entry.key,
                            style: TextStyle(fontSize: 14, color: c.ink))),
                    Text(fmtRp(entry.value, currency),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: c.ink)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Spending and earning per month, side by side - two columns, never one
/// netted figure. Tapping a month filters the recap above to it.
class _MonthlyBreakdown extends StatelessWidget {
  final AppData data;
  final List<GroupTransaction> rows;

  /// The month the recap is filtered to (`yyyy-MM`), or null for all time.
  final String? selected;
  final String currency;
  final AppColors c;
  final ValueChanged<String> onSelect;

  const _MonthlyBreakdown({
    required this.data,
    required this.rows,
    required this.selected,
    required this.currency,
    required this.c,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final regular = <String, _Totals>{};
    final offCount = <String, int>{};
    for (final t in rows) {
      final month = isoMonth(t.date);
      regular.putIfAbsent(month, _Totals.new);
      if (data.isAfterTurnedOff(t)) {
        offCount[month] = (offCount[month] ?? 0) + 1;
      } else {
        regular[month]!.add(t);
      }
    }
    if (regular.isEmpty) {
      return _EmptyPanel(c: c, text: 'No months to show yet.');
    }
    final months = regular.keys.toList()..sort((a, b) => b.compareTo(a));
    final header = TextStyle(
        fontSize: 11, fontWeight: FontWeight.w600, color: c.muted);
    return _Panel(
      c: c,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Row(
            children: [
              Expanded(child: Text('MONTH', style: header)),
              SizedBox(
                  width: 104,
                  child: Text('SPENDING',
                      textAlign: TextAlign.right, style: header)),
              SizedBox(
                  width: 104,
                  child: Text('EARNING',
                      textAlign: TextAlign.right, style: header)),
              const SizedBox(width: 18),
            ],
          ),
        ),
        for (final month in months)
          InkWell(
            onTap: () => onSelect(month),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 7),
              color: month == selected
                  ? c.accent.withValues(alpha: 0.08)
                  : Colors.transparent,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${monthLabel(month)} ${month.substring(0, 4)}',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: month == selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: c.ink)),
                        if ((offCount[month] ?? 0) > 0)
                          Text('${offCount[month]} after turned off',
                              style:
                                  TextStyle(fontSize: 11, color: c.transfer)),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 104,
                    child: Text(fmtRp(regular[month]!.spend, currency),
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 13, color: c.neg)),
                  ),
                  SizedBox(
                    width: 104,
                    child: Text(fmtRp(regular[month]!.earn, currency),
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 13, color: c.pos)),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 18, color: c.muted),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _GroupTxnTile extends StatelessWidget {
  final GroupTransaction txn;
  final bool afterOff;
  final bool isMine;
  final String currency;
  final AppColors c;

  const _GroupTxnTile({
    required this.txn,
    required this.afterOff,
    required this.isMine,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final isEarning = txn.transactionType == 'earning';
    final title = txn.description.trim().isNotEmpty
        ? txn.description.trim()
        : (txn.category.isEmpty ? txn.transactionType : txn.category);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: afterOff ? c.transfer.withValues(alpha: 0.5) : c.line2,
            width: afterOff ? 1 : 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink)),
                const SizedBox(height: 3),
                Text(
                  [
                    isMine ? 'You' : txn.createdBy,
                    if (txn.category.isNotEmpty && title != txn.category)
                      txn.category,
                    fmtDate(txn.date, 'long'),
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
                if (afterOff || txn.syncState == 'pending') ...[
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 4,
                    children: [
                      if (afterOff)
                        _Chip(label: 'After turned off', color: c.transfer),
                      if (txn.syncState == 'pending')
                        _Chip(label: 'Pending sync', color: c.muted),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${isEarning ? '+' : '−'}${fmtRp(txn.amount, currency)}',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isEarning ? c.pos : c.neg),
          ),
        ],
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final GroupMember member;
  final bool isLeader;
  final bool isMe;
  final AppColors c;

  const _MemberTile({
    required this.member,
    required this.isLeader,
    required this.isMe,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: c.surface2,
        child: Text(
          member.username.isEmpty ? '?' : member.username[0].toUpperCase(),
          style: TextStyle(color: c.ink, fontWeight: FontWeight.w600),
        ),
      ),
      title: Text(isMe ? '${member.username} (you)' : member.username,
          style: TextStyle(color: c.ink, fontSize: 14)),
      subtitle: member.syncState == 'pending' && !isLeader
          ? Text('Not verified yet - checked when back online',
              style: TextStyle(color: c.muted, fontSize: 12))
          : member.addedBy.isNotEmpty && member.addedBy != member.username
              ? Text('Added by ${member.addedBy}',
                  style: TextStyle(color: c.muted, fontSize: 12))
              : null,
      trailing: Wrap(
        spacing: 4,
        children: [
          if (isLeader) _Chip(label: 'Leader', color: c.accent),
          if (member.syncState == 'pending')
            _Chip(label: 'Pending', color: c.transfer),
        ],
      ),
    );
  }
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

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final AppColors c;

  const _MetricTile(
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
          Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final AppColors c;
  final List<Widget> children;
  const _Panel({required this.c, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors c;
  const _SectionTitle(this.text, this.c);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            fontSize: 16, fontWeight: FontWeight.w700, color: c.ink));
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
