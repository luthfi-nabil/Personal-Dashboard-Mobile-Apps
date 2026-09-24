import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/group_models.dart';
import '../core/group_service.dart';
import '../core/models.dart';
import '../core/money_input.dart';
import '../core/proof_service.dart';
import '../core/remote_api.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/proof_widgets.dart';

/// Reimbursements and split bills of a group, fetched live.
final groupSettlementsProvider =
    FutureProvider.autoDispose.family<GroupSettlements, String>((ref, groupId) {
  ref.watch(configProvider.select((cfg) => cfg.userId));
  return GroupService.instance.settlements(groupId);
});

/// One group transaction with how it was settled.
///
/// For a spending:
/// - **Reimburse** (anyone but the owner): pay the owner back from one of
///   your sources into one of theirs, optionally with a proof of transfer.
/// - **Split bill** (owner): say who else pays part of it - a group member,
///   who pays in the app (with a proof, if they like) and waits for the
///   owner's approval, or any name, whose payments the owner records.
///
/// Group members see the proofs attached to the transaction and to its
/// settlements.
class GroupTransactionScreen extends ConsumerWidget {
  final String groupId;
  final String transactionId;
  const GroupTransactionScreen(
      {super.key, required this.groupId, required this.transactionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final data = ref.watch(appDataProvider).valueOrNull;
    final me = cfg.username.trim();
    final group = data?.groupById(groupId);
    final txn = data
        ?.groupTransactionsFor(groupId, me)
        .where((t) => t.transactionId == transactionId)
        .firstOrNull;
    final settlementsAsync = ref.watch(groupSettlementsProvider(groupId));

    Widget body;
    if (data == null) {
      body = Center(child: CircularProgressIndicator(color: c.accent));
    } else if (group == null || txn == null) {
      body = Center(
          child: Text('This transaction is no longer available.',
              style: TextStyle(color: c.muted)));
    } else {
      body = RefreshIndicator(
        onRefresh: () => ref.refresh(groupSettlementsProvider(groupId).future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            _TxnCard(
                txn: txn,
                me: me,
                ownerName: data.displayName(txn.createdBy),
                currency: cfg.currency,
                c: c),
            if (txn.syncState != 'pending') ...[
              const SizedBox(height: 10),
              ProofGallery(
                proofRef: ProofRef.forTransactionType(txn.transactionType),
                refId: txn.transactionId,
                canAdd: txn.createdBy.toLowerCase() == me.toLowerCase(),
              ),
            ],
            const SizedBox(height: 14),
            if (txn.transactionType == 'earning')
              _Note(
                  c: c,
                  text: 'Earnings are not reimbursed or split - only group '
                      'spendings are.')
            else if (txn.syncState == 'pending')
              _Note(
                  c: c,
                  text: 'This spending is still waiting to sync. It can be '
                      'reimbursed or split once it reaches the server.')
            else
              settlementsAsync.when(
                loading: () => Padding(
                  padding: const EdgeInsets.all(24),
                  child:
                      Center(child: CircularProgressIndicator(color: c.accent)),
                ),
                error: (e, _) => _Note(
                  c: c,
                  text: e is ApiException ? e.message : '$e',
                  action: TextButton(
                    onPressed: () =>
                        ref.invalidate(groupSettlementsProvider(groupId)),
                    child: const Text('Retry'),
                  ),
                ),
                data: (all) => _SettlementSection(
                  group: group,
                  data: data,
                  txn: txn,
                  all: all,
                  me: me,
                  currency: cfg.currency,
                  c: c,
                ),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                    onPressed: () => context.pop(),
                  ),
                  Expanded(
                    child: Text(
                      group == null ? 'Transaction' : group.name,
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
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Runs [action], then reloads settlements and the app data (money may have
/// moved into or out of personal sources).
Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  String groupId,
  Future<void> Function() action, {
  required String done,
  bool movedMoney = true,
}) async {
  try {
    await action();
  } on ApiException catch (e) {
    if (context.mounted) _snack(context, e.message);
    return;
  }
  ref.invalidate(groupSettlementsProvider(groupId));
  if (movedMoney) {
    await ref.read(appDataProvider.notifier).refreshFromServer();
  }
  if (context.mounted) _snack(context, done);
}

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));

double _parseAmount(String text) => parseMoney(text) ?? 0;

/// Uploads a proof for a settlement that was just made. The settlement
/// stands either way, so a failed upload is only reported.
Future<void> _attachProof(BuildContext context, ProofRef ref, String refId,
    Uint8List? proof) async {
  if (proof == null) return;
  try {
    await ProofService.instance.upload(ref, refId, proof);
  } on ApiException catch (e) {
    if (context.mounted) {
      _snack(context, 'Saved, but the proof was not uploaded: ${e.message}');
    }
  }
}

// ── The transaction ───────────────────────────────────────────────────────

class _TxnCard extends StatelessWidget {
  final GroupTransaction txn;
  final String me;

  /// Display name of whoever recorded it.
  final String ownerName;
  final String currency;
  final AppColors c;

  const _TxnCard(
      {required this.txn,
      required this.me,
      required this.ownerName,
      required this.currency,
      required this.c});

  @override
  Widget build(BuildContext context) {
    final isEarning = txn.transactionType == 'earning';
    final title = txn.description.trim().isNotEmpty
        ? txn.description.trim()
        : (txn.category.isEmpty ? txn.transactionType : txn.category);
    return _Card(
      c: c,
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: c.ink)),
        const SizedBox(height: 6),
        Text(
          '${isEarning ? '+' : '−'}${fmtRp(txn.amount, currency)}',
          style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: isEarning ? c.pos : c.neg),
        ),
        const SizedBox(height: 6),
        Text(
          [
            txn.createdBy == me ? 'Paid by you' : 'Paid by $ownerName',
            if (txn.source.isNotEmpty) 'from ${txn.source}',
            if (txn.category.isNotEmpty) txn.category,
            fmtDate(txn.date, 'long'),
          ].join(' · '),
          style: TextStyle(fontSize: 12, color: c.muted),
        ),
      ],
    );
  }
}

// ── Settlement ────────────────────────────────────────────────────────────

class _SettlementSection extends ConsumerWidget {
  final SpendingGroup group;
  final AppData data;
  final GroupTransaction txn;
  final GroupSettlements all;
  final String me;
  final String currency;
  final AppColors c;

  const _SettlementSection({
    required this.group,
    required this.data,
    required this.txn,
    required this.all,
    required this.me,
    required this.currency,
    required this.c,
  });

  bool get _isOwner => txn.createdBy.toLowerCase() == me.toLowerCase();

  String _name(String username) => data.displayName(username);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = all.forTransaction(txn.transactionId);
    final left = s.leftOf(txn.amount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryCard(txn: txn, s: s, currency: currency, c: c),
        const SizedBox(height: 10),
        Row(
          children: [
            if (!_isOwner)
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      left > 0 ? () => _reimburse(context, ref, left) : null,
                  icon: const Icon(Icons.reply_rounded, size: 18),
                  label: Text(left > 0 ? 'Reimburse' : 'Fully settled'),
                ),
              ),
            if (_isOwner)
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      left > 0 ? () => _addShare(context, ref, left) : null,
                  icon: const Icon(Icons.call_split_rounded, size: 18),
                  label: Text(left > 0 ? 'Split bill' : 'Fully settled'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle('Split bill', c),
        const SizedBox(height: 8),
        if (s.shares.isEmpty)
          _Note(
              c: c,
              text: _isOwner
                  ? 'Not split. Use "Split bill" to say who else pays part '
                      'of this.'
                  : 'Not split.')
        else
          ...s.shares.map((share) => _ShareTile(
                share: share,
                name: share.isRegistered ? _name(share.name) : share.name,
                payments: s.paymentsOf(share.id),
                isOwner: _isOwner,
                me: me,
                currency: currency,
                c: c,
                onPay: () => _payShare(context, ref, share),
                onRecord: () => _recordPayment(context, ref, share),
                onRemove: () => _removeShare(context, ref, share),
                onApprove: (p) => _approve(context, ref, p),
                onReject: (p) => _run(
                  context,
                  ref,
                  group.id,
                  () => GroupService.instance
                      .reviewSplitPayment(p, approve: false),
                  done: 'Payment rejected.',
                  movedMoney: false,
                ),
                onWithdraw: (p) => _run(
                  context,
                  ref,
                  group.id,
                  () => GroupService.instance.withdrawSplitPayment(p),
                  done: 'Payment withdrawn.',
                  movedMoney: false,
                ),
              )),
        const SizedBox(height: 20),
        _SectionTitle('Reimbursements', c),
        const SizedBox(height: 8),
        if (s.reimbursements.isEmpty)
          _Note(c: c, text: 'Nobody has reimbursed this yet.')
        else
          ...s.reimbursements.map((r) => _ReimbursementTile(
              r: r,
              me: me,
              paidByName: _name(r.paidBy),
              ownerName: _name(r.owner),
              currency: currency,
              c: c)),
      ],
    );
  }

  Future<void> _reimburse(
      BuildContext context, WidgetRef ref, double left) async {
    final result = await showDialog<_ReimburseDraft>(
      context: context,
      builder: (_) => _ReimburseDialog(
        owner: txn.createdBy,
        ownerName: _name(txn.createdBy),
        left: left,
        sources: data.sources,
        groupName: group.name,
        currency: currency,
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      group.id,
      () async {
        final id = await GroupService.instance.reimburse(
          groupId: group.id,
          transactionId: txn.transactionId,
          fromSourceId: result.fromSourceId,
          amount: result.amount,
          toSourceId: result.toSourceId,
          description: result.note,
        );
        if (context.mounted) {
          await _attachProof(
              context, ProofRef.reimbursement, id, result.proof);
        }
      },
      done: 'Reimbursed ${_name(txn.createdBy)}.',
    );
  }

  Future<void> _addShare(
      BuildContext context, WidgetRef ref, double left) async {
    final members = {
      for (final m in data.membersOf(group.id))
        if (m.username.toLowerCase() != me.toLowerCase())
          m.username: _name(m.username),
    };
    final result = await showDialog<_ShareDraft>(
      context: context,
      builder: (_) => _ShareDialog(
        left: left,
        members: members,
        names: all.names,
        currency: currency,
        onForgetName: (name) => _run(
          context,
          ref,
          group.id,
          () => GroupService.instance.forgetName(group.id, name),
          done: '"$name" removed from the list.',
          movedMoney: false,
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      group.id,
      () => GroupService.instance.addSplitShare(
        groupId: group.id,
        transactionId: txn.transactionId,
        username: result.username,
        name: result.name,
        amount: result.amount,
      ),
      done: 'Split ${fmtRp(result.amount, currency)} to '
          '${result.username == null ? result.name : _name(result.username!)}.',
      movedMoney: false,
    );
  }

  Future<void> _removeShare(
      BuildContext context, WidgetRef ref, GroupSplitShare share) async {
    final ok = await _confirm(context, 'Remove ${share.name}\'s share?',
        'Their pending payments are cancelled.');
    if (!ok || !context.mounted) return;
    await _run(
      context,
      ref,
      group.id,
      () => GroupService.instance.removeSplitShare(share),
      done: 'Share removed.',
      movedMoney: false,
    );
  }

  Future<void> _payShare(
      BuildContext context, WidgetRef ref, GroupSplitShare share) async {
    final result = await showDialog<_MoneyDraft>(
      context: context,
      builder: (_) => _MoneyDialog(
        title: 'Pay your share',
        action: 'Send',
        amount: share.payable,
        max: share.payable,
        choiceLabel: 'Pay from',
        sources: data.sources,
        currency: currency,
        withProof: true,
        hint: '${_name(share.owner)} has to approve it before money moves. '
            'You can pay part now and the rest later.',
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      group.id,
      () async {
        final id = await GroupService.instance.paySplitShare(share,
            amount: result.amount,
            fromSourceId: result.sourceId,
            note: result.note);
        if (context.mounted) {
          await _attachProof(
              context, ProofRef.splitPayment, id, result.proof);
        }
      },
      done: 'Sent to ${_name(share.owner)} for approval.',
      movedMoney: false,
    );
  }

  Future<void> _recordPayment(
      BuildContext context, WidgetRef ref, GroupSplitShare share) async {
    final result = await showDialog<_MoneyDraft>(
      context: context,
      builder: (_) => _MoneyDialog(
        title: 'Received from ${share.name}',
        action: 'Record',
        amount: share.unpaid,
        max: share.unpaid,
        choiceLabel: 'Put it in',
        sources: data.sources,
        currency: currency,
        withProof: true,
        hint: '${share.name} is not in the app, so you record what they '
            'paid you.',
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      group.id,
      () async {
        final id = await GroupService.instance.recordSplitPayment(share,
            amount: result.amount,
            toSourceId: result.sourceId,
            note: result.note);
        if (context.mounted) {
          await _attachProof(
              context, ProofRef.splitPayment, id, result.proof);
        }
      },
      done: 'Recorded ${fmtRp(result.amount, currency)} from ${share.name}.',
    );
  }

  Future<void> _approve(
      BuildContext context, WidgetRef ref, GroupSplitPayment p) async {
    final result = await showDialog<_MoneyDraft>(
      context: context,
      builder: (_) => _MoneyDialog(
        title: 'Approve ${fmtRp(p.amount, currency)} from ${p.payerName}',
        action: 'Approve',
        amount: p.amount,
        fixedAmount: true,
        choiceLabel: 'Put it in',
        sources: data.sources,
        currency: currency,
        hint: p.fromSource == null
            ? 'Check the proof below the payment before approving.'
            : 'Paid from ${p.payerName}\'s ${p.fromSource}. Check the proof '
                'below the payment before approving.',
      ),
    );
    if (result == null || !context.mounted) return;
    await _run(
      context,
      ref,
      group.id,
      () => GroupService.instance
          .reviewSplitPayment(p, approve: true, toSourceId: result.sourceId),
      done: 'Payment approved.',
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
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
  return ok == true;
}

/// Reimbursed, split and what is left.
class _SummaryCard extends StatelessWidget {
  final GroupTransaction txn;
  final TransactionSettlement s;
  final String currency;
  final AppColors c;

  const _SummaryCard(
      {required this.txn,
      required this.s,
      required this.currency,
      required this.c});

  @override
  Widget build(BuildContext context) {
    Widget line(String label, String value,
            {Color? color, bool bold = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                  child: Text(label,
                      style: TextStyle(fontSize: 13, color: c.ink2))),
              Text(value,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                      color: color ?? c.ink)),
            ],
          ),
        );
    return _Card(
      c: c,
      children: [
        line('Reimbursed', fmtRp(s.reimbursed, currency),
            color: c.pos, bold: true),
        // Only reimbursements made while groups still had balances returned
        // money to one or paid into it.
        if (s.balanceReturned > 0 || s.reimbursedGroup > 0)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(
              children: [
                if (s.balanceReturned > 0)
                  line('· returned to group balance',
                      fmtRp(s.balanceReturned, currency)),
                if (s.reimbursedGroup > 0)
                  line('· paid into group balance',
                      fmtRp(s.reimbursedGroup, currency)),
              ],
            ),
          ),
        line('Split bill paid',
            '${fmtRp(s.splitPaid, currency)} of ${fmtRp(s.splitTotal, currency)}',
            color: c.pos),
        Divider(color: c.line2, height: 16),
        line('Not reimbursed or split', fmtRp(s.leftOf(txn.amount), currency),
            bold: true),
      ],
    );
  }
}

class _ShareTile extends StatelessWidget {
  final GroupSplitShare share;

  /// Display name of the person the share is for.
  final String name;
  final List<GroupSplitPayment> payments;
  final bool isOwner;
  final String me;
  final String currency;
  final AppColors c;
  final VoidCallback onPay;
  final VoidCallback onRecord;
  final VoidCallback onRemove;
  final ValueChanged<GroupSplitPayment> onApprove;
  final ValueChanged<GroupSplitPayment> onReject;
  final ValueChanged<GroupSplitPayment> onWithdraw;

  const _ShareTile({
    required this.share,
    required this.name,
    required this.payments,
    required this.isOwner,
    required this.me,
    required this.currency,
    required this.c,
    required this.onPay,
    required this.onRecord,
    required this.onRemove,
    required this.onApprove,
    required this.onReject,
    required this.onWithdraw,
  });

  @override
  Widget build(BuildContext context) {
    final mine = share.isFor(me);
    final shown = payments.where((p) => p.status != 'cancelled').toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: mine && !share.isPaid ? c.accent : c.line2,
            width: mine && !share.isPaid ? 1 : 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(mine ? '$name (you)' : name,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.ink)),
                    if (!share.isRegistered)
                      _Chip(label: 'Not in app', color: c.muted),
                    if (share.isPaid)
                      _Chip(label: 'Paid', color: c.pos)
                    else if (share.pendingAmount > 0)
                      _Chip(label: 'Waiting approval', color: c.transfer),
                  ],
                ),
              ),
              Text(fmtRp(share.amount, currency),
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: c.ink)),
              if (isOwner && share.paidAmount <= 0)
                IconButton(
                  tooltip: 'Remove share',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded, size: 18, color: c.muted),
                  onPressed: onRemove,
                )
              else
                const SizedBox(width: 10),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: share.amount <= 0
                    ? 0
                    : (share.paidAmount / share.amount).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: c.line2,
                color: c.pos,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              'Paid ${fmtRp(share.paidAmount, currency)}',
              if (share.pendingAmount > 0)
                'pending ${fmtRp(share.pendingAmount, currency)}',
              'left ${fmtRp(share.unpaid, currency)}',
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
          for (final p in shown)
            _PaymentRow(
              p: p,
              canReview: isOwner && p.isPending,
              canWithdraw: p.isPending &&
                  p.paidBy != null &&
                  p.paidBy!.toLowerCase() == me.toLowerCase(),
              canAddProof: isOwner ||
                  (p.paidBy != null &&
                      p.paidBy!.toLowerCase() == me.toLowerCase()),
              currency: currency,
              c: c,
              onApprove: () => onApprove(p),
              onReject: () => onReject(p),
              onWithdraw: () => onWithdraw(p),
            ),
          if (mine && share.payable > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onPay,
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: const Text('Pay my share'),
              ),
            ),
          if (isOwner && !share.isRegistered && !share.isPaid)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onRecord,
                icon: const Icon(Icons.add_card_outlined, size: 18),
                label: const Text('Record payment'),
              ),
            ),
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  final GroupSplitPayment p;
  final bool canReview;
  final bool canWithdraw;

  /// The payer and the owner may attach a proof of transfer.
  final bool canAddProof;
  final String currency;
  final AppColors c;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onWithdraw;

  const _PaymentRow({
    required this.p,
    required this.canReview,
    required this.canWithdraw,
    required this.canAddProof,
    required this.currency,
    required this.c,
    required this.onApprove,
    required this.onReject,
    required this.onWithdraw,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (p.status) {
      'approved' => c.pos,
      'pending' => c.transfer,
      _ => c.muted,
    };
    final route = [
      if (p.fromSource != null) 'from ${p.fromSource}',
      if (p.isApproved && p.toSource != null) 'to ${p.toSource}',
    ].join(' ');
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.subdirectory_arrow_right_rounded,
                  size: 16, color: c.muted),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  [
                    fmtRp(p.amount, currency),
                    if (route.isNotEmpty) route,
                    fmtDate(p.requestedAt, 'long'),
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: c.ink2),
                ),
              ),
              _Chip(label: p.status, color: color),
            ],
          ),
          if (p.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text('"${p.note}"',
                  style: TextStyle(fontSize: 12, color: c.muted)),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () => showProofSheet(
                  context,
                  proofRef: ProofRef.splitPayment,
                  refId: p.id,
                  canAdd: canAddProof,
                ),
                icon: const Icon(Icons.receipt_long_outlined, size: 16),
                label: const Text('Proof'),
              ),
              if (canReview || canWithdraw) ...[
                if (canWithdraw)
                  TextButton(
                      onPressed: onWithdraw, child: const Text('Withdraw')),
                if (canReview) ...[
                  TextButton(onPressed: onReject, child: const Text('Reject')),
                  FilledButton(
                      onPressed: onApprove, child: const Text('Approve')),
                ],
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ReimbursementTile extends StatelessWidget {
  final GroupReimbursement r;
  final String me;
  final String paidByName;
  final String ownerName;
  final String currency;
  final AppColors c;

  const _ReimbursementTile(
      {required this.r,
      required this.me,
      required this.paidByName,
      required this.ownerName,
      required this.currency,
      required this.c});

  @override
  Widget build(BuildContext context) {
    final who =
        r.paidBy.toLowerCase() == me.toLowerCase() ? 'You' : paidByName;
    final parts = [
      if (r.personalAmount > 0)
        'personal ${fmtRp(r.personalAmount, currency)}'
            '${r.toSource == null ? '' : ' → ${r.toSource}'}',
      if (r.groupAmount > 0) 'group balance ${fmtRp(r.groupAmount, currency)}',
      if (r.returnBalance) 'balance returned',
    ];
    final canAddProof = r.paidBy.toLowerCase() == me.toLowerCase() ||
        r.owner.toLowerCase() == me.toLowerCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.reply_rounded, size: 20, color: c.pos),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$who paid back $ownerName',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink)),
                const SizedBox(height: 2),
                Text(parts.join(' · '),
                    style: TextStyle(fontSize: 12, color: c.ink2)),
                const SizedBox(height: 2),
                Text(
                  [
                    'from ${r.fromSource}',
                    fmtDate(r.createdDate, 'long'),
                    if (r.description.isNotEmpty) '"${r.description}"',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact),
                    onPressed: () => showProofSheet(
                      context,
                      proofRef: ProofRef.reimbursement,
                      refId: r.id,
                      canAdd: canAddProof,
                    ),
                    icon: const Icon(Icons.receipt_long_outlined, size: 16),
                    label: const Text('Proof'),
                  ),
                ),
              ],
            ),
          ),
          Text(fmtRp(r.amount, currency),
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: c.pos)),
        ],
      ),
    );
  }
}

// ── Dialogs ───────────────────────────────────────────────────────────────

class _ReimburseDraft {
  final String fromSourceId;
  final double amount;
  final String toSourceId;
  final String note;
  final Uint8List? proof;

  const _ReimburseDraft({
    required this.fromSourceId,
    required this.amount,
    required this.toSourceId,
    required this.note,
    this.proof,
  });
}

/// Pay the owner back from one of your sources into one of theirs, with an
/// optional proof of transfer.
class _ReimburseDialog extends StatefulWidget {
  final String owner;
  final String ownerName;
  final double left;
  final List<Source> sources;
  final String groupName;
  final String currency;

  const _ReimburseDialog({
    required this.owner,
    required this.ownerName,
    required this.left,
    required this.sources,
    required this.groupName,
    required this.currency,
  });

  @override
  State<_ReimburseDialog> createState() => _ReimburseDialogState();
}

class _ReimburseDialogState extends State<_ReimburseDialog> {
  late final TextEditingController _amount =
      TextEditingController(text: formatMoneyInput(widget.left));
  final _note = TextEditingController();
  String? _from;
  String? _to;
  Uint8List? _proof;
  List<MemberSource>? _ownerSources;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    GroupService.instance.memberSources(widget.owner).then(
      (sources) {
        if (mounted) setState(() => _ownerSources = sources);
      },
      onError: (Object e) {
        if (mounted) {
          setState(() => _loadError = e is ApiException ? e.message : '$e');
        }
      },
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = _parseAmount(_amount.text);
    final over = amount > widget.left + 0.000001;
    final ok = _from != null && _to != null && amount > 0 && !over;
    return AlertDialog(
      title: Text('Reimburse ${widget.ownerName}'),
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
              inputFormatters: moneyInputFormatters,
              decoration: InputDecoration(
                labelText: 'Amount',
                errorText: over
                    ? 'Only ${fmtRp(widget.left, widget.currency)} is left.'
                    : null,
                helperText:
                    'Left to settle: ${fmtRp(widget.left, widget.currency)}',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _from,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Pay from'),
              items: [
                for (final s in widget.sources)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _from = v),
            ),
            const SizedBox(height: 6),
            if (_loadError != null)
              Text(_loadError!,
                  style: const TextStyle(fontSize: 12, color: Colors.red))
            else if (_ownerSources == null)
              const LinearProgressIndicator()
            else
              DropdownButtonFormField<String>(
                initialValue: _to,
                isExpanded: true,
                decoration: InputDecoration(
                    labelText: 'Into ${widget.ownerName}\'s source'),
                items: [
                  for (final s in _ownerSources!)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _to = v),
              ),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: 12),
            ProofPickerField(
              image: _proof,
              onChanged: (v) => setState(() => _proof = v),
              label: 'Proof of transfer (optional)',
              hint: '${widget.ownerName} and the group can see it.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: ok
              ? () => Navigator.pop(
                    context,
                    _ReimburseDraft(
                      fromSourceId: _from!,
                      amount: amount,
                      toSourceId: _to!,
                      note: _note.text.trim(),
                      proof: _proof,
                    ),
                  )
              : null,
          child: const Text('Reimburse'),
        ),
      ],
    );
  }
}

class _ShareDraft {
  final String? username;
  final String? name;
  final double amount;
  const _ShareDraft({this.username, this.name, required this.amount});
}

/// Who pays part of the bill: a group member (switch on) or just a name.
class _ShareDialog extends StatefulWidget {
  final double left;

  /// Username -> display name of the other members.
  final Map<String, String> members;
  final List<String> names;
  final String currency;
  final ValueChanged<String> onForgetName;

  const _ShareDialog({
    required this.left,
    required this.members,
    required this.names,
    required this.currency,
    required this.onForgetName,
  });

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  late bool _registered = widget.members.isNotEmpty;
  String? _member;
  final _name = TextEditingController();
  late final TextEditingController _amount =
      TextEditingController(text: formatMoneyInput(widget.left));
  late final List<String> _names = [...widget.names];

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = _parseAmount(_amount.text);
    final over = amount > widget.left + 0.000001;
    final who = _registered ? _member : _name.text.trim();
    final ok = who != null && who.isNotEmpty && amount > 0 && !over;
    return AlertDialog(
      title: const Text('Split bill'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Registered user'),
              subtitle: Text(
                  _registered
                      ? 'A group member pays in the app; you approve it.'
                      : 'Someone outside the app; you record what they pay.',
                  style: const TextStyle(fontSize: 12)),
              value: _registered,
              onChanged: widget.members.isEmpty
                  ? null
                  : (v) => setState(() => _registered = v),
            ),
            if (_registered)
              DropdownButtonFormField<String>(
                initialValue: _member,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Member'),
                items: [
                  for (final m in widget.members.entries)
                    DropdownMenuItem(value: m.key, child: Text(m.value)),
                ],
                onChanged: (v) => setState(() => _member = v),
              )
            else ...[
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Name', hintText: 'Saved to this group\'s list'),
                onChanged: (_) => setState(() {}),
              ),
              if (_names.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final n in _names)
                      InputChip(
                        label: Text(n),
                        selected: _name.text.trim() == n,
                        onPressed: () => setState(() => _name.text = n),
                        onDeleted: () {
                          widget.onForgetName(n);
                          setState(() => _names.remove(n));
                        },
                      ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: moneyInputFormatters,
              decoration: const InputDecoration(labelText: 'Their share'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(
              over
                  ? 'Only ${fmtRp(widget.left, widget.currency)} is left.'
                  : 'Left to split: ${fmtRp(widget.left, widget.currency)}',
              style: TextStyle(
                  fontSize: 12, color: over ? Colors.red : Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: ok
              ? () => Navigator.pop(
                    context,
                    _registered
                        ? _ShareDraft(username: _member, amount: amount)
                        : _ShareDraft(name: _name.text.trim(), amount: amount),
                  )
              : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _MoneyDraft {
  final double amount;

  /// One of the user's own sources.
  final String sourceId;
  final String note;
  final Uint8List? proof;
  const _MoneyDraft(this.amount, this.sourceId, this.note, [this.proof]);
}

/// An amount plus one of the user's sources - used to pay a share (from)
/// and to approve or record one (into).
class _MoneyDialog extends StatefulWidget {
  final String title;
  final String action;
  final double amount;
  final double? max;
  final bool fixedAmount;
  final String choiceLabel;
  final List<Source> sources;
  final String currency;
  final String hint;

  /// Offer to attach a proof of transfer.
  final bool withProof;

  const _MoneyDialog({
    required this.title,
    required this.action,
    required this.amount,
    this.max,
    this.fixedAmount = false,
    required this.choiceLabel,
    required this.sources,
    required this.currency,
    required this.hint,
    this.withProof = false,
  });

  @override
  State<_MoneyDialog> createState() => _MoneyDialogState();
}

class _MoneyDialogState extends State<_MoneyDialog> {
  late final TextEditingController _amount =
      TextEditingController(text: formatMoneyInput(widget.amount));
  final _note = TextEditingController();
  String? _choice;
  Uint8List? _proof;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = _parseAmount(_amount.text);
    final over = widget.max != null && amount > widget.max! + 0.000001;
    final choice = _choice;
    final ok = amount > 0 && !over && choice != null;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.fixedAmount)
              TextField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: moneyInputFormatters,
                decoration: InputDecoration(
                    labelText: 'Amount',
                    helperText: widget.max == null
                        ? null
                        : 'Up to ${fmtRp(widget.max!, widget.currency)}'),
                onChanged: (_) => setState(() {}),
              ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _choice,
              isExpanded: true,
              decoration: InputDecoration(labelText: widget.choiceLabel),
              items: [
                for (final s in widget.sources)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _choice = v),
            ),
            if (!widget.fixedAmount) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
            ],
            if (widget.withProof) ...[
              const SizedBox(height: 12),
              ProofPickerField(
                image: _proof,
                onChanged: (v) => setState(() => _proof = v),
                label: 'Proof of transfer (optional)',
              ),
            ],
            const SizedBox(height: 10),
            Text(widget.hint,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: ok
              ? () => Navigator.pop(
                    context,
                    _MoneyDraft(amount, choice, _note.text.trim(), _proof),
                  )
              : null,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

// ── Small building blocks ─────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final AppColors c;
  final List<Widget> children;
  const _Card({required this.c, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
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

class _Note extends StatelessWidget {
  final String text;
  final AppColors c;
  final Widget? action;
  const _Note({required this.text, required this.c, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: c.muted, height: 1.4)),
          ),
          if (action != null) action!,
        ],
      ),
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
        style:
            TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.ink));
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
