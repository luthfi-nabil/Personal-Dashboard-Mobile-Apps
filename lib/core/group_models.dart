/// Models for the server-side group features: shared routines, planned
/// expenses the group intends to buy, and requests to add one.
///
/// Unlike [SpendingGroup] and friends in `models.dart` these are not cached
/// in SQLite - they are read straight from transaction-api each time the
/// screens open, because paying one moves money between people's records and
/// only the server can settle that.
library;

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
      );
}

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

  const GroupPlans({
    this.routines = const [],
    this.routinePayments = const [],
    this.plannedExpenses = const [],
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

/// One movement of a member's group balance: a `top_up` (positive) or a
/// `spending` paid from the balance (negative).
class GroupBalanceEntry {
  final String id;
  final String groupId;
  final String username;
  final double amount;
  final String entryType;
  final String description;
  final String category;
  final String createdDate;

  const GroupBalanceEntry({
    required this.id,
    required this.groupId,
    required this.username,
    required this.amount,
    required this.entryType,
    required this.description,
    required this.category,
    required this.createdDate,
  });

  bool get isTopUp => entryType == 'top_up';

  factory GroupBalanceEntry.fromApi(Map<String, dynamic> m) =>
      GroupBalanceEntry(
        id: _str(m['entry_id']),
        groupId: _str(m['group_id']),
        username: _str(m['username']),
        amount: _num(m['amount']),
        entryType: _str(m['entry_type']),
        description: _str(m['description']),
        category: _str(m['spending_category']),
        createdDate: _str(m['created_date']),
      );
}

/// A member's balance inside one group - separate from their personal
/// sources and only spendable on that group.
class GroupMemberBalance {
  final String username;
  final double balance;
  final double totalTopUp;
  final double totalSpent;

  const GroupMemberBalance({
    required this.username,
    required this.balance,
    required this.totalTopUp,
    required this.totalSpent,
  });

  factory GroupMemberBalance.fromApi(Map<String, dynamic> m) =>
      GroupMemberBalance(
        username: _str(m['username']),
        balance: _num(m['balance']),
        totalTopUp: _num(m['total_top_up']),
        totalSpent: _num(m['total_spent']),
      );
}

/// What the server lets the caller see of a group's balances: every member's
/// for the leader, only their own for anyone else.
class GroupBalances {
  final bool isLeader;
  final List<GroupMemberBalance> balances;
  final List<GroupBalanceEntry> entries;

  const GroupBalances({
    required this.isLeader,
    required this.balances,
    required this.entries,
  });

  factory GroupBalances.fromApi(Map<String, dynamic> m) => GroupBalances(
        isLeader: m['is_leader'] == true,
        balances: [
          for (final b in (m['balances'] as List? ?? const []))
            GroupMemberBalance.fromApi(Map<String, dynamic>.from(b as Map)),
        ],
        entries: [
          for (final e in (m['entries'] as List? ?? const []))
            GroupBalanceEntry.fromApi(Map<String, dynamic>.from(e as Map)),
        ],
      );

  /// [username]'s balance, or zero when not visible / no entries yet.
  double balanceOf(String username) =>
      balances
          .where((b) => b.username.toLowerCase() == username.toLowerCase())
          .firstOrNull
          ?.balance ??
      0;
}
