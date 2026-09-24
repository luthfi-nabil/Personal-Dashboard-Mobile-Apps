/// Models for the server-side group features: shared routines, planned
/// expenses the group intends to buy, and requests to add one.
///
/// Unlike [SpendingGroup] and friends in `models.dart` these are not synced
/// row by row: they are read from transaction-api, and the last server copy
/// is kept on the device (`group_snapshots`) only so they can be viewed
/// offline. Paying one moves money between people's records and only the
/// server can settle that, so every write stays online-only.
library;

import 'dart:math' as math;

import 'routine_schedule.dart';

double _num(dynamic value) => (value as num?)?.toDouble() ?? 0;

String _str(dynamic value) => value?.toString() ?? '';

String? _strOrNull(dynamic value) {
  final text = value?.toString();
  return text == null || text.isEmpty ? null : text;
}

/// A recurring purchase the whole group shares. Only the leader adds or
/// removes one; any member can pay it out of their own source.
class GroupRoutine {
  final String id;
  final String groupId;
  final String itemName;
  final double price;
  final String reminder;
  final String categoryId;
  final String category;
  final String? lastPaidAt;
  final String? lastPaidBy;
  final String createdBy;

  /// Anchors a custom repeat's periods (see `currentPeriodStart`).
  final String createdDate;

  const GroupRoutine({
    required this.id,
    required this.groupId,
    required this.itemName,
    required this.price,
    required this.reminder,
    required this.categoryId,
    required this.category,
    this.lastPaidAt,
    this.lastPaidBy,
    required this.createdBy,
    this.createdDate = '',
  });

  factory GroupRoutine.fromApi(Map<String, dynamic> m) => GroupRoutine(
        id: _str(m['routine_id']),
        groupId: _str(m['group_id']),
        itemName: _str(m['item_name']),
        price: _num(m['price']),
        reminder: _str(m['reminder']),
        categoryId: _str(m['spending_category_id']),
        category: _str(m['spending_category']),
        lastPaidAt: _strOrNull(m['last_paid_at']),
        lastPaidBy: _strOrNull(m['last_paid_by']),
        createdBy: _str(m['created_by']),
        createdDate: _str(m['created_date']),
      );
}

/// Whether anyone in the group has paid [routine] within its current period
/// (this month for a monthly one, ...). Resets when the next period starts.
bool groupRoutinePaid(GroupRoutine routine, DateTime today) => isPaidThisPeriod(
      reminder: routine.reminder,
      lastPaidAt: routine.lastPaidAt,
      createdDate: routine.createdDate,
      today: today,
    );

/// One member's payment of a [GroupRoutine]. The money came out of
/// [source], one of [paidBy]'s own sources.
class GroupRoutinePayment {
  final String id;
  final String routineId;
  final String groupId;
  final String spendingId;
  final String itemName;
  final double price;
  final String source;
  final String paidBy;
  final String paidAt;

  const GroupRoutinePayment({
    required this.id,
    required this.routineId,
    required this.groupId,
    required this.spendingId,
    required this.itemName,
    required this.price,
    required this.source,
    required this.paidBy,
    required this.paidAt,
  });

  factory GroupRoutinePayment.fromApi(Map<String, dynamic> m) =>
      GroupRoutinePayment(
        id: _str(m['payment_id']),
        routineId: _str(m['routine_id']),
        groupId: _str(m['group_id']),
        spendingId: _str(m['spending_id']),
        itemName: _str(m['item_name']),
        price: _num(m['price']),
        source: _str(m['source']),
        paidBy: _str(m['paid_by']),
        paidAt: _str(m['paid_at']),
      );
}

/// A one-off purchase the group intends to make.
///
/// Status flow: a member's request starts `requested` and the leader turns it
/// into `planned` or `rejected`; the leader's own items start `planned`. A
/// `planned` item becomes `fulfilled` once a member buys it, or `canceled`.
class GroupPlannedExpense {
  final String id;
  final String groupId;
  final String itemName;
  final double price;
  final String categoryId;
  final String category;
  final String notes;
  final String status;
  final String requestedBy;
  final String? reviewedBy;
  final String? fulfilledBy;
  final double? fulfilledPrice;
  final String? fulfilledAt;
  final String createdDate;

  const GroupPlannedExpense({
    required this.id,
    required this.groupId,
    required this.itemName,
    required this.price,
    required this.categoryId,
    required this.category,
    required this.notes,
    required this.status,
    required this.requestedBy,
    this.reviewedBy,
    this.fulfilledBy,
    this.fulfilledPrice,
    this.fulfilledAt,
    required this.createdDate,
  });

  bool get isRequested => status == 'requested';
  bool get isPlanned => status == 'planned';
  bool get isOpen => isRequested || isPlanned;

  factory GroupPlannedExpense.fromApi(Map<String, dynamic> m) =>
      GroupPlannedExpense(
        id: _str(m['planned_expense_id']),
        groupId: _str(m['group_id']),
        itemName: _str(m['item_name']),
        price: _num(m['price']),
        categoryId: _str(m['spending_category_id']),
        category: _str(m['spending_category']),
        notes: _str(m['notes']),
        status: _str(m['status']),
        requestedBy: _str(m['requested_by']),
        reviewedBy: _strOrNull(m['reviewed_by']),
        fulfilledBy: _strOrNull(m['fulfilled_by']),
        fulfilledPrice: (m['fulfilled_price'] as num?)?.toDouble(),
        fulfilledAt: _strOrNull(m['fulfilled_at']),
        createdDate: _str(m['created_date']),
      );
}

/// Everything the group-plans screen shows, across all the user's groups.
class GroupPlans {
  final List<GroupRoutine> routines;
  final List<GroupRoutinePayment> routinePayments;
  final List<GroupPlannedExpense> plannedExpenses;

  /// When this came from the copy saved on the device (offline), the moment
  /// it was saved; null for a fresh server read.
  final String? cachedAt;

  const GroupPlans({
    this.routines = const [],
    this.routinePayments = const [],
    this.plannedExpenses = const [],
    this.cachedAt,
  });

  List<GroupRoutine> routinesOf(String groupId) =>
      routines.where((r) => r.groupId == groupId).toList();

  List<GroupRoutinePayment> paymentsOf(String groupId) =>
      routinePayments.where((p) => p.groupId == groupId).toList();

  List<GroupPlannedExpense> plannedExpensesOf(String groupId) =>
      plannedExpenses.where((p) => p.groupId == groupId).toList();
}

/// One of a group mate's sources, offered as a transfer destination. The
/// server only ever returns names, never balances.
class MemberSource {
  final String id;
  final String name;

  const MemberSource({required this.id, required this.name});

  factory MemberSource.fromApi(Map<String, dynamic> m) =>
      MemberSource(id: _str(m['source_id']), name: _str(m['source']));
}

/// How much one member means to spend on a group each month.
class GroupMemberTarget {
  final String username;
  final double amount;
  final String updatedDate;

  const GroupMemberTarget({
    required this.username,
    required this.amount,
    required this.updatedDate,
  });

  factory GroupMemberTarget.fromApi(Map<String, dynamic> m) =>
      GroupMemberTarget(
        username: _str(m['username']),
        amount: _num(m['amount']),
        updatedDate: _str(m['updated_date']),
      );
}

/// A group's target spendings as the server lets the caller see them: every
/// member's for the leader, only their own for anyone else. [enabled] is the
/// leader's switch; while it is off the app hides target spendings.
class GroupTargets {
  final bool isLeader;
  final bool enabled;
  final List<GroupMemberTarget> targets;

  const GroupTargets({
    required this.isLeader,
    required this.enabled,
    required this.targets,
  });

  factory GroupTargets.fromApi(Map<String, dynamic> m) => GroupTargets(
        isLeader: m['is_leader'] == true,
        // Servers that predate the switch have targets on.
        enabled: m['enabled'] != false,
        targets: [
          for (final t in (m['targets'] as List? ?? const []))
            GroupMemberTarget.fromApi(Map<String, dynamic>.from(t as Map)),
        ],
      );

  /// [username]'s monthly target, or null when they have not set one.
  double? targetOf(String username) => targets
      .where((t) => t.username.toLowerCase() == username.toLowerCase())
      .firstOrNull
      ?.amount;
}

/// One member's month against their target.
class TargetProgress {
  final double target;
  final double spent;

  const TargetProgress({required this.target, required this.spent});

  double get left => target - spent;
  bool get isOver => spent > target + 0.005;

  /// Share of the target used, 0..1 (1 once it is reached or passed).
  double get ratio => target <= 0 ? 1 : (spent / target).clamp(0.0, 1.0);
}

/// A member paying another member back for one of their group spendings.
/// The owner receives [personalAmount] in one of their sources. With
/// [returnBalance] the amount was also given back to the owner's group
/// balance. ([groupAmount] is only set by reimbursements made with older
/// app versions, which paid part into the owner's group balance.)
class GroupReimbursement {
  final String id;
  final String groupId;
  final String transactionId;
  final String owner;
  final String paidBy;
  final String fromSource;
  final double personalAmount;
  final String? toSource;
  final double groupAmount;
  final double amount;
  final bool returnBalance;
  final String description;
  final String createdDate;

  const GroupReimbursement({
    required this.id,
    required this.groupId,
    required this.transactionId,
    required this.owner,
    required this.paidBy,
    required this.fromSource,
    required this.personalAmount,
    required this.toSource,
    required this.groupAmount,
    required this.amount,
    this.returnBalance = false,
    required this.description,
    required this.createdDate,
  });

  factory GroupReimbursement.fromApi(Map<String, dynamic> m) =>
      GroupReimbursement(
        id: _str(m['reimbursement_id']),
        groupId: _str(m['group_id']),
        transactionId: _str(m['transaction_id']),
        owner: _str(m['owner']),
        paidBy: _str(m['paid_by']),
        fromSource: _str(m['from_source']),
        personalAmount: _num(m['personal_amount']),
        toSource: _strOrNull(m['to_source']),
        groupAmount: _num(m['group_amount']),
        amount: _num(m['amount']),
        returnBalance: m['return_balance'] == true,
        description: _str(m['description']),
        createdDate: _str(m['created_date']),
      );
}

/// One person's part of a split group spending: a group member
/// ([username] set) who pays in the app, or just a [name] whose payments the
/// owner records.
class GroupSplitShare {
  final String id;
  final String groupId;
  final String transactionId;
  final String owner;
  final String? username;
  final String name;
  final double amount;
  final double paidAmount;
  final double pendingAmount;
  final String createdDate;

  const GroupSplitShare({
    required this.id,
    required this.groupId,
    required this.transactionId,
    required this.owner,
    required this.username,
    required this.name,
    required this.amount,
    required this.paidAmount,
    required this.pendingAmount,
    required this.createdDate,
  });

  bool get isRegistered => username != null;
  double get unpaid => math.max(0, amount - paidAmount);

  /// What the member can still ask to pay: unpaid minus pending requests.
  double get payable => math.max(0, amount - paidAmount - pendingAmount);
  bool get isPaid => unpaid < 0.005;

  bool isFor(String user) =>
      username != null && username!.toLowerCase() == user.toLowerCase();

  factory GroupSplitShare.fromApi(Map<String, dynamic> m) => GroupSplitShare(
        id: _str(m['share_id']),
        groupId: _str(m['group_id']),
        transactionId: _str(m['transaction_id']),
        owner: _str(m['owner']),
        username: _strOrNull(m['username']),
        name: _str(m['name']),
        amount: _num(m['amount']),
        paidAmount: _num(m['paid_amount']),
        pendingAmount: _num(m['pending_amount']),
        createdDate: _str(m['created_date']),
      );
}

/// A payment towards a split share: `pending` until the owner approves
/// (`approved`) or rejects it, or the payer withdraws it (`cancelled`).
class GroupSplitPayment {
  final String id;
  final String shareId;
  final String groupId;
  final String transactionId;
  final String owner;
  final String? paidBy;
  final String payerName;
  final double amount;
  final String status;
  final String? fromSource;
  final String? toSource;
  final String note;
  final String requestedAt;

  const GroupSplitPayment({
    required this.id,
    required this.shareId,
    required this.groupId,
    required this.transactionId,
    required this.owner,
    required this.paidBy,
    required this.payerName,
    required this.amount,
    required this.status,
    required this.fromSource,
    required this.toSource,
    required this.note,
    required this.requestedAt,
  });

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';

  factory GroupSplitPayment.fromApi(Map<String, dynamic> m) =>
      GroupSplitPayment(
        id: _str(m['payment_id']),
        shareId: _str(m['share_id']),
        groupId: _str(m['group_id']),
        transactionId: _str(m['transaction_id']),
        owner: _str(m['owner']),
        paidBy: _strOrNull(m['paid_by']),
        payerName: _str(m['payer_name']),
        amount: _num(m['amount']),
        status: _str(m['status']),
        fromSource: _strOrNull(m['from_source']),
        toSource: _strOrNull(m['to_source']),
        note: _str(m['note']),
        requestedAt: _str(m['requested_at']),
      );
}

/// Reimbursements and split bills of one group.
class GroupSettlements {
  final List<GroupReimbursement> reimbursements;
  final List<GroupSplitShare> shares;
  final List<GroupSplitPayment> payments;

  /// Names of people outside the app used in this group's split bills.
  final List<String> names;

  const GroupSettlements({
    required this.reimbursements,
    required this.shares,
    required this.payments,
    required this.names,
  });

  static const empty =
      GroupSettlements(reimbursements: [], shares: [], payments: [], names: []);

  factory GroupSettlements.fromApi(Map<String, dynamic> m) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) parse) => [
          for (final e in (m[key] as List? ?? const []))
            parse(Map<String, dynamic>.from(e as Map)),
        ];
    return GroupSettlements(
      reimbursements: list('reimbursements', GroupReimbursement.fromApi),
      shares: list('shares', GroupSplitShare.fromApi),
      payments: list('payments', GroupSplitPayment.fromApi),
      names: [for (final n in (m['names'] as List? ?? const [])) '$n'],
    );
  }

  /// Everything settled against one group spending.
  TransactionSettlement forTransaction(String transactionId) {
    final shares =
        this.shares.where((s) => s.transactionId == transactionId).toList();
    final shareIds = {for (final s in shares) s.id};
    return TransactionSettlement(
      reimbursements: reimbursements
          .where((r) => r.transactionId == transactionId)
          .toList(),
      shares: shares,
      payments: payments.where((p) => shareIds.contains(p.shareId)).toList(),
    );
  }
}

/// Reimbursements and split bill of a single group spending.
class TransactionSettlement {
  final List<GroupReimbursement> reimbursements;
  final List<GroupSplitShare> shares;
  final List<GroupSplitPayment> payments;

  const TransactionSettlement({
    required this.reimbursements,
    required this.shares,
    required this.payments,
  });

  bool get isEmpty => reimbursements.isEmpty && shares.isEmpty;

  /// Reimbursed into the owner's personal sources.
  double get reimbursedPersonal =>
      reimbursements.fold(0, (sum, r) => sum + r.personalAmount);

  /// Reimbursed into the owner's group balance.
  double get reimbursedGroup =>
      reimbursements.fold(0, (sum, r) => sum + r.groupAmount);

  double get reimbursed => reimbursedPersonal + reimbursedGroup;

  /// Given back to the owner's group balance by "return balance".
  double get balanceReturned => reimbursements
      .where((r) => r.returnBalance)
      .fold(0, (sum, r) => sum + r.amount);
  double get splitTotal => shares.fold(0, (sum, s) => sum + s.amount);
  double get splitPaid => shares.fold(0, (sum, s) => sum + s.paidAmount);

  /// What can still be reimbursed or split out: the spending minus every
  /// reimbursement and every split share (paid or not).
  double leftOf(double total) => math.max(0, total - reimbursed - splitTotal);

  List<GroupSplitPayment> paymentsOf(String shareId) =>
      payments.where((p) => p.shareId == shareId).toList();
}

// ── Fund requests ──────────────────────────────────────────────────────────

bool _bool(dynamic value) =>
    value == true || value == 1 || value?.toString() == 'true';

/// Part of one of the recipient's spendings that used up a tracked fund.
class FundUsage {
  final String spendingId;
  final String description;
  final double spendingAmount;
  final double amount;
  final String date;

  const FundUsage({
    required this.spendingId,
    required this.description,
    required this.spendingAmount,
    required this.amount,
    required this.date,
  });

  factory FundUsage.fromApi(Map<String, dynamic> m) => FundUsage(
        spendingId: _str(m['spending_id']),
        description: _str(m['description']),
        spendingAmount: _num(m['spending_amount']),
        amount: _num(m['amount']),
        date: _str(m['created_date']),
      );
}

/// Money a member asked a group mate for - or was sent - for a purpose
/// ([tag], a spending category such as "Transportation").
///
/// A request waits (`requested`) until the payer sends it (`sent`) or
/// rejects it (`rejected`); the requester can withdraw it (`canceled`). A
/// direct send starts `sent`. When [tracked], the recipient's spendings in
/// the tag's category use the money up, leaving [remaining] as their tag
/// balance; the group admin can waive it (`waived`), which drops what is left
/// ([waivedAmount]) from that balance while the spendings stay recorded.
class GroupFundRequest {
  final String id;
  final String groupId;

  /// `request` or `send`.
  final String kind;

  /// Who receives the money.
  final String requester;

  /// Who gives it.
  final String payer;
  final double amount;
  final String tag;
  final String note;
  final bool tracked;
  final String status;
  final String? toSourceId;
  final String? toSource;
  final String? fromSource;
  final String createdBy;
  final String createdDate;
  final String? sentAt;
  final String? waivedBy;
  final String? waivedAt;
  final String? waiveNote;
  final double spent;
  final double remaining;
  final double waivedAmount;
  final List<FundUsage> usage;

  const GroupFundRequest({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.requester,
    required this.payer,
    required this.amount,
    required this.tag,
    this.note = '',
    this.tracked = false,
    required this.status,
    this.toSourceId,
    this.toSource,
    this.fromSource,
    required this.createdBy,
    required this.createdDate,
    this.sentAt,
    this.waivedBy,
    this.waivedAt,
    this.waiveNote,
    this.spent = 0,
    this.remaining = 0,
    this.waivedAmount = 0,
    this.usage = const [],
  });

  bool get isWaiting => status == 'requested';
  bool get isSent => status == 'sent';
  bool get isWaived => status == 'waived';

  /// Money moved and it is tracked, so it has a tag balance.
  bool get hasBalance => tracked && (isSent || isWaived);

  factory GroupFundRequest.fromApi(Map<String, dynamic> m) => GroupFundRequest(
        id: _str(m['request_id']),
        groupId: _str(m['group_id']),
        kind: _str(m['kind']),
        requester: _str(m['requester']),
        payer: _str(m['payer']),
        amount: _num(m['amount']),
        tag: _str(m['tag']),
        note: _str(m['note']),
        tracked: _bool(m['tracked']),
        status: _str(m['status']),
        toSourceId: _strOrNull(m['to_source_id']),
        toSource: _strOrNull(m['to_source']),
        fromSource: _strOrNull(m['from_source']),
        createdBy: _str(m['created_by']),
        createdDate: _str(m['created_date']),
        sentAt: _strOrNull(m['sent_at']),
        waivedBy: _strOrNull(m['waived_by']),
        waivedAt: _strOrNull(m['waived_at']),
        waiveNote: _strOrNull(m['waive_note']),
        spent: _num(m['spent']),
        remaining: _num(m['remaining']),
        waivedAmount: _num(m['waived_amount']),
        usage: (m['usage'] as List? ?? const [])
            .map((e) => FundUsage.fromApi(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// A member's earmarked money for one tag in one group.
class TagBalance {
  final String groupId;
  final String username;
  final String tag;
  final double received;
  final double spent;
  final double waived;
  final double balance;

  const TagBalance({
    required this.groupId,
    required this.username,
    required this.tag,
    required this.received,
    required this.spent,
    required this.waived,
    required this.balance,
  });

  factory TagBalance.fromApi(Map<String, dynamic> m) => TagBalance(
        groupId: _str(m['group_id']),
        username: _str(m['username']),
        tag: _str(m['tag']),
        received: _num(m['received']),
        spent: _num(m['spent']),
        waived: _num(m['waived']),
        balance: _num(m['balance']),
      );
}

/// Everything the fund requests screen shows, across all the user's groups.
class FundRequests {
  final List<GroupFundRequest> requests;
  final List<TagBalance> balances;

  /// Set when read from the copy saved on the device (offline).
  final String? cachedAt;

  const FundRequests({
    this.requests = const [],
    this.balances = const [],
    this.cachedAt,
  });

  factory FundRequests.fromApi(Map<String, dynamic> m, {String? cachedAt}) =>
      FundRequests(
        requests: (m['requests'] as List? ?? const [])
            .map((e) =>
                GroupFundRequest.fromApi(Map<String, dynamic>.from(e as Map)))
            .toList(),
        balances: (m['balances'] as List? ?? const [])
            .map((e) => TagBalance.fromApi(Map<String, dynamic>.from(e as Map)))
            .toList(),
        cachedAt: cachedAt,
      );

  List<GroupFundRequest> of(String groupId) =>
      requests.where((r) => r.groupId == groupId).toList();

  List<TagBalance> balancesOf(String groupId) =>
      balances.where((b) => b.groupId == groupId).toList();
}
