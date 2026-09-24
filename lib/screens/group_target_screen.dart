import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/group_models.dart';
import '../core/group_service.dart';
import '../core/models.dart';
import '../core/money_input.dart';
import '../core/remote_api.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

/// A group's target spendings, fetched live. What comes back depends on who
/// asks: the leader gets every member's target, anyone else only their own.
final groupTargetsProvider =
    FutureProvider.autoDispose.family<GroupTargets, String>((ref, groupId) {
  ref.watch(configProvider.select((cfg) => cfg.userId));
  return GroupService.instance.targets(groupId);
});

/// What each member spent on [groupId] in [month] (`yyyy-MM`), keyed by
/// lower-case username. Only spendings count, and - like the recap's
/// totals - not those tagged while the group was switched off.
Map<String, double> groupMonthSpending(
    AppData data, String groupId, String me, String month) {
  final spent = <String, double>{};
  for (final t in data.groupTransactionsFor(groupId, me)) {
    if (t.transactionType == 'earning' ||
        isoMonth(t.date) != month ||
        data.isAfterTurnedOff(t)) {
      continue;
    }
    final key = t.createdBy.toLowerCase();
    spent[key] = (spent[key] ?? 0) + t.amount;
  }
  return spent;
}

/// Turns target spendings on or off for the whole group (leader only), then
/// reloads them. Shared by this screen and the group recap.
Future<void> setGroupTargetsEnabled(
    BuildContext context, WidgetRef ref, String groupId, bool enabled) async {
  try {
    await GroupService.instance.setTargetsEnabled(groupId, enabled);
  } on ApiException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
    return;
  }
  ref.invalidate(groupTargetsProvider(groupId));
}

/// Target spendings: every member sets how much they mean to spend on the
/// group each month, and sees how much of it their group spendings have
/// used. Only the member themselves sets their target; the leader sees
/// everyone's, and can switch the feature off for the whole group - which
/// hides it for every member.
class GroupTargetScreen extends ConsumerStatefulWidget {
  final String groupId;
  const GroupTargetScreen({super.key, required this.groupId});

  @override
  ConsumerState<GroupTargetScreen> createState() => _GroupTargetScreenState();
}

class _GroupTargetScreenState extends ConsumerState<GroupTargetScreen> {
  String _month = isoMonth(DateTime.now().toIso8601String());

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final data = ref.watch(appDataProvider).valueOrNull;
    final group = data?.groupById(widget.groupId);
    final targetsAsync = ref.watch(groupTargetsProvider(widget.groupId));

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
                      group == null
                          ? 'Target spendings'
                          : '${group.name} · targets',
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
                  : targetsAsync.when(
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
                                    groupTargetsProvider(widget.groupId)),
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      data: (targets) => RefreshIndicator(
                        onRefresh: () => ref.refresh(
                            groupTargetsProvider(widget.groupId).future),
                        child: _body(context, group, data, targets,
                            cfg.username.trim(), cfg.currency, c),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, SpendingGroup group, AppData data,
      GroupTargets targets, String me, String currency, AppColors c) {
    final spent = groupMonthSpending(data, group.id, me, _month);
    final mySpent = spent[me.toLowerCase()] ?? 0;
    final myTarget = targets.targetOf(me);
    final others = data
        .membersOf(group.id)
        .where((m) => m.username.toLowerCase() != me.toLowerCase())
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        if (targets.isLeader) ...[
          _SwitchCard(
            enabled: targets.enabled,
            c: c,
            onChanged: (v) =>
                setGroupTargetsEnabled(context, ref, group.id, v),
          ),
          const SizedBox(height: 14),
        ],
        if (!targets.enabled)
          _Empty(
              targets.isLeader
                  ? 'Target spendings are off, so members don\'t see them. '
                      'Targets already set are kept for when you turn them '
                      'back on.'
                  : 'Target spendings are turned off for this group by the '
                      'leader.',
              c)
        else ...[
          _MonthBar(
            month: _month,
            c: c,
            onChanged: (m) => setState(() => _month = m),
          ),
          const SizedBox(height: 10),
          _MyTargetCard(
            month: _month,
            target: myTarget,
            spent: mySpent,
            currency: currency,
            c: c,
            onEdit: () => _editTarget(context, group, myTarget),
          ),
          if (targets.isLeader) ...[
            const SizedBox(height: 22),
            _Title("Members' targets", c),
            const SizedBox(height: 4),
            Text('Only you, as leader, can see everyone\'s target.',
                style: TextStyle(fontSize: 12, color: c.muted)),
            const SizedBox(height: 10),
            if (others.isEmpty)
              _Empty('No other members yet.', c)
            else
              _Panel(
                c: c,
                children: [
                  for (final m in others)
                    _MemberRow(
                      name: data.displayName(m.username),
                      target: targets.targetOf(m.username),
                      spent: spent[m.username.toLowerCase()] ?? 0,
                      currency: currency,
                      c: c,
                    ),
                ],
              ),
          ],
          const SizedBox(height: 14),
          Text(
            'Counts the group spendings each member adds in the month - '
            'earnings don\'t count. A target is the same every month until '
            'it is changed.',
            style: TextStyle(fontSize: 12, color: c.muted, height: 1.4),
          ),
        ],
      ],
    );
  }

  Future<void> _editTarget(
      BuildContext context, SpendingGroup group, double? current) async {
    final result = await showDialog<double>(
      context: context,
      builder: (_) =>
          _TargetDialog(groupName: group.name, current: current),
    );
    if (result == null || !context.mounted) return;
    try {
      await GroupService.instance.setTarget(group.id, result);
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    ref.invalidate(groupTargetsProvider(group.id));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result <= 0 ? 'Target removed.' : 'Target saved.')));
    }
  }
}

/// Colour of a target's progress: over it, close to it, or comfortably
/// under.
Color _progressColor(TargetProgress p, AppColors c) => p.isOver
    ? c.neg
    : p.ratio >= 0.8
        ? c.transfer
        : c.accent;

class _SwitchCard extends StatelessWidget {
  final bool enabled;
  final AppColors c;
  final ValueChanged<bool> onChanged;

  const _SwitchCard(
      {required this.enabled, required this.c, required this.onChanged});

  @override
  Widget build(BuildContext context) {
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
                Text('Target spendings',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.ink)),
                const SizedBox(height: 2),
                Text(
                  enabled
                      ? 'On - every member can set a monthly target.'
                      : 'Off - hidden for every member of the group.',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ],
            ),
          ),
          Switch(value: enabled, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _MyTargetCard extends StatelessWidget {
  final String month;
  final double? target;
  final double spent;
  final String currency;
  final AppColors c;
  final VoidCallback onEdit;

  const _MyTargetCard({
    required this.month,
    required this.target,
    required this.spent,
    required this.currency,
    required this.c,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final t = target;
    final p = t == null ? null : TargetProgress(target: t, spent: spent);
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
          Text('Your target · ${monthLabel(month)} ${month.substring(0, 4)}',
              style: TextStyle(fontSize: 12, color: c.muted)),
          const SizedBox(height: 4),
          Text(t == null ? 'No target yet' : fmtRp(t, currency),
              style: TextStyle(
                  fontSize: t == null ? 20 : 28,
                  fontWeight: FontWeight.w700,
                  color: t == null ? c.muted : c.ink)),
          const SizedBox(height: 8),
          if (p != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: p.ratio,
                minHeight: 8,
                backgroundColor: c.line2,
                color: _progressColor(p, c),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Spent ${fmtRp(spent, currency)} · '
              '${p.isOver ? 'over by ${fmtRp(-p.left, currency)}' : '${fmtRp(p.left, currency)} left'}',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: p.isOver ? c.neg : c.ink2),
            ),
          ] else
            Text(
              'Spent ${fmtRp(spent, currency)} on this group this month. '
              'Set a target to keep an eye on it.',
              style: TextStyle(fontSize: 13, color: c.ink2, height: 1.35),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onEdit,
              icon: Icon(t == null ? Icons.flag_outlined : Icons.edit_outlined,
                  size: 18),
              label: Text(t == null ? 'Set target' : 'Change target'),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final String name;
  final double? target;
  final double spent;
  final String currency;
  final AppColors c;

  const _MemberRow({
    required this.name,
    required this.target,
    required this.spent,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final t = target;
    final p = t == null ? null : TargetProgress(target: t, spent: spent);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(name,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink)),
              ),
              Text(
                t == null
                    ? 'No target'
                    : '${fmtRp(spent, currency)} / ${fmtRp(t, currency)}',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: p != null && p.isOver ? c.neg : c.ink),
              ),
            ],
          ),
          const SizedBox(height: 5),
          if (p != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: p.ratio,
                minHeight: 5,
                backgroundColor: c.line2,
                color: _progressColor(p, c),
              ),
            )
          else
            Text('Spent ${fmtRp(spent, currency)}',
                style: TextStyle(fontSize: 12, color: c.muted)),
        ],
      ),
    );
  }
}

class _MonthBar extends StatelessWidget {
  final String month;
  final AppColors c;
  final ValueChanged<String> onChanged;

  const _MonthBar(
      {required this.month, required this.c, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final thisMonth = isoMonth(DateTime.now().toIso8601String());
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.chevron_left_rounded, color: c.ink),
          onPressed: () => onChanged(prevMonth(month)),
        ),
        Expanded(
          child: Text(
            '${monthLabel(month)} ${month.substring(0, 4)}',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
          ),
        ),
        IconButton(
          icon: Icon(Icons.chevron_right_rounded, color: c.ink),
          onPressed:
              month == thisMonth ? null : () => onChanged(nextMonth(month)),
        ),
      ],
    );
  }
}

/// Asks for the monthly target; answers 0 to remove it.
class _TargetDialog extends StatefulWidget {
  final String groupName;
  final double? current;

  const _TargetDialog({required this.groupName, required this.current});

  @override
  State<_TargetDialog> createState() => _TargetDialogState();
}

class _TargetDialogState extends State<_TargetDialog> {
  late final TextEditingController _amount = TextEditingController(
      text: widget.current == null ? '' : formatMoneyInput(widget.current!));

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = parseMoney(_amount.text);
    final valid = amount != null && amount > 0;
    return AlertDialog(
      title: Text(widget.current == null ? 'Set target' : 'Change target'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: moneyInputFormatters,
            decoration: const InputDecoration(
                labelText: 'Monthly target', prefixText: 'Rp '),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          Text(
            'How much you mean to spend on ${widget.groupName} each month. '
            'Only you can change it.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        if (widget.current != null)
          TextButton(
              onPressed: () => Navigator.pop(context, 0.0),
              child: const Text('Remove')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: valid ? () => Navigator.pop(context, amount) : null,
          child: const Text('Save'),
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
            crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
}
