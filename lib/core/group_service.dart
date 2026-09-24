import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'config.dart';
import 'db.dart';
import 'group_models.dart';
import 'models.dart';
import 'remote_api.dart';
import 'sync.dart';

/// Online-only calls for the group features that move money between
/// members' records (group routines, planned expenses, transfers to members,
/// settlements) and for target spendings.
///
/// These are deliberately not queued offline like personal transactions:
/// whether a payment is still allowed (the item is still open, the source is
/// really yours) can only be decided by the server at the moment it happens.
class GroupService {
  static final GroupService instance = GroupService._();
  GroupService._();

  static const _uuid = Uuid();

  RemoteApi get _api => RemoteApi(ConfigService.instance.current);

  Future<T> _call<T>(Future<T> Function(RemoteApi api) call) async {
    if (!SyncService.instance.isOnline) {
      throw const ApiException(
          'You are offline. Group payments need a connection.');
    }
    try {
      return await call(_api);
    } on ApiUnauthorizedException {
      if (!await ConfigService.instance.tryRefreshToken()) rethrow;
      return await call(_api);
    } on ApiUnavailableException {
      throw const ApiException(
          'The server is unreachable. Try again in a moment.');
    }
  }

  String get _userId => ConfigService.instance.current.userId;

  static const _plansKey = 'group_plans';

  /// Group routines, their payments and planned expenses.
  ///
  /// Read from the server when possible, and every server copy is saved on
  /// the device, so the lists still open offline (or with the server down)
  /// from the last copy - [GroupPlans.cachedAt] then says how old it is.
  /// Paying, approving and the rest stay online-only.
  Future<GroupPlans> loadPlans() async {
    final userId = _userId;
    if (SyncService.instance.isOnline) {
      try {
        return await _call((api) => refreshPlans(api, userId));
      } on ApiException {
        final cached = await cachedPlans(userId);
        if (cached != null) return cached;
        rethrow;
      }
    }
    final cached = await cachedPlans(userId);
    if (cached != null) return cached;
    throw const ApiException('You are offline and the group plans have not '
        'been loaded on this device yet.');
  }

  /// Fetches the plans with [api] and saves them for [userId]. Also called
  /// after every sync, so the local copy is fresh even if the screen was
  /// never opened.
  Future<GroupPlans> refreshPlans(RemoteApi api, String userId) async {
    final results = await Future.wait([
      api.getGroupRoutines(),
      api.getGroupRoutinePayments(),
      api.getGroupPlannedExpenses(),
    ]);
    await AppDb.instance.putGroupSnapshot(
      _plansKey,
      jsonEncode({
        'routines': results[0],
        'payments': results[1],
        'planned': results[2],
      }),
      DateTime.now().toIso8601String(),
      userId,
    );
    return _plansFrom(results[0], results[1], results[2]);
  }

  /// The last saved copy for [userId], or null when there is none.
  Future<GroupPlans?> cachedPlans(String userId) async {
    final snap = await AppDb.instance.getGroupSnapshot(_plansKey, userId);
    if (snap == null) return null;
    try {
      final m = jsonDecode(snap.json) as Map<String, dynamic>;
      List<Map<String, dynamic>> list(String key) => (m[key] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      return _plansFrom(list('routines'), list('payments'), list('planned'),
          cachedAt: snap.savedAt);
    } catch (_) {
      return null;
    }
  }

  GroupPlans _plansFrom(
    List<Map<String, dynamic>> routines,
    List<Map<String, dynamic>> payments,
    List<Map<String, dynamic>> planned, {
    String? cachedAt,
  }) =>
      GroupPlans(
        routines: routines.map(GroupRoutine.fromApi).toList(),
        routinePayments: payments.map(GroupRoutinePayment.fromApi).toList(),
        plannedExpenses: planned.map(GroupPlannedExpense.fromApi).toList(),
        cachedAt: cachedAt,
      );

  // ── Fund requests ──────────────────────────────────────────────────────

  static const _fundsKey = 'fund_requests';

  /// Fund requests and tag balances. Like [loadPlans], the last server copy
  /// is kept on the device and shown offline; every action is online-only.
  Future<FundRequests> loadFundRequests() async {
    final userId = _userId;
    if (SyncService.instance.isOnline) {
      try {
        return await _call((api) => refreshFundRequests(api, userId));
      } on ApiException {
        final cached = await cachedFundRequests(userId);
        if (cached != null) return cached;
        rethrow;
      }
    }
    final cached = await cachedFundRequests(userId);
    if (cached != null) return cached;
    throw const ApiException('You are offline and the fund requests have '
        'not been loaded on this device yet.');
  }

  Future<FundRequests> refreshFundRequests(RemoteApi api, String userId) async {
    final raw = await api.getFundRequests();
    await AppDb.instance.putGroupSnapshot(
        _fundsKey, jsonEncode(raw), DateTime.now().toIso8601String(), userId);
    return FundRequests.fromApi(raw);
  }

  Future<FundRequests?> cachedFundRequests(String userId) async {
    final snap = await AppDb.instance.getGroupSnapshot(_fundsKey, userId);
    if (snap == null) return null;
    try {
      return FundRequests.fromApi(
          Map<String, dynamic>.from(jsonDecode(snap.json) as Map),
          cachedAt: snap.savedAt);
    } catch (_) {
      return null;
    }
  }

  /// Asks [username] for [amount] for [tag], received into the caller's
  /// [toSourceId] (optional - the payer can pick one of the caller's sources
  /// when sending).
  Future<void> requestFunds({
    required String groupId,
    required String username,
    required double amount,
    required String tag,
    String note = '',
    bool tracked = false,
    String? toSourceId,
  }) =>
      _call((api) => api.createFundRequest(
            groupId: groupId,
            requestId: _uuid.v4(),
            kind: 'request',
            username: username,
            amount: amount,
            tag: tag,
            note: note,
            tracked: tracked,
            toSourceId: toSourceId,
          ));

  /// Sends [username] [amount] for [tag] right away, from the caller's
  /// [fromSourceId] into their [toSourceId].
  Future<void> sendFunds({
    required String groupId,
    required String username,
    required double amount,
    required String tag,
    String note = '',
    bool tracked = false,
    required String fromSourceId,
    required String toSourceId,
  }) =>
      _call((api) => api.createFundRequest(
            groupId: groupId,
            requestId: _uuid.v4(),
            kind: 'send',
            username: username,
            amount: amount,
            tag: tag,
            note: note,
            tracked: tracked,
            fromSourceId: fromSourceId,
            toSourceId: toSourceId,
          ));

  Future<void> fulfillFundRequest(GroupFundRequest r,
          {required String fromSourceId, String? toSourceId}) =>
      _call((api) => api.fulfillFundRequest(
            groupId: r.groupId,
            requestId: r.id,
            fromSourceId: fromSourceId,
            toSourceId: toSourceId,
          ));

  Future<void> rejectFundRequest(GroupFundRequest r) =>
      _call((api) => api.rejectFundRequest(r.groupId, r.id));

  Future<void> cancelFundRequest(GroupFundRequest r) =>
      _call((api) => api.cancelFundRequest(r.groupId, r.id));

  /// Group admin only.
  Future<void> waiveFundRequest(GroupFundRequest r, {String note = ''}) =>
      _call((api) => api.waiveFundRequest(r.groupId, r.id, note: note));

  Future<void> saveRoutine({
    required String groupId,
    String? routineId,
    required String itemName,
    required double price,
    required String reminder,
    required String categoryId,
    required String category,
  }) =>
      _call((api) => api.saveGroupRoutine(
            groupId: groupId,
            routineId: routineId ?? _uuid.v4(),
            itemName: itemName,
            price: price,
            reminder: reminder,
            categoryId: categoryId,
            category: category,
          ));

  Future<void> deleteRoutine(GroupRoutine routine) =>
      _call((api) => api.deleteGroupRoutine(routine.groupId, routine.id));

  /// Pays from the caller's [sourceId].
  Future<void> payRoutine(GroupRoutine routine,
          {required double price, required String sourceId}) =>
      _call((api) => api.payGroupRoutine(
            groupId: routine.groupId,
            routineId: routine.id,
            paymentId: _uuid.v4(),
            price: price,
            sourceId: sourceId,
          ));

  /// Returns the saved item, whose status says whether it was added
  /// (`planned`, leader) or only requested (`requested`, member).
  Future<GroupPlannedExpense> addPlannedExpense({
    required String groupId,
    required String itemName,
    required double price,
    required String categoryId,
    required String category,
    String notes = '',
  }) =>
      _call((api) async => GroupPlannedExpense.fromApi(
            await api.addGroupPlannedExpense(
              groupId: groupId,
              id: _uuid.v4(),
              itemName: itemName,
              price: price,
              categoryId: categoryId,
              category: category,
              notes: notes,
            ),
          ));

  Future<void> reviewPlannedExpense(GroupPlannedExpense item, bool approve) =>
      _call((api) =>
          api.reviewGroupPlannedExpense(item.groupId, item.id, approve));

  /// Pays from the caller's [sourceId].
  Future<void> fulfillPlannedExpense(GroupPlannedExpense item,
          {required double price, required String sourceId}) =>
      _call((api) => api.fulfillGroupPlannedExpense(
            groupId: item.groupId,
            id: item.id,
            paymentId: _uuid.v4(),
            price: price,
            sourceId: sourceId,
          ));

  Future<void> cancelPlannedExpense(GroupPlannedExpense item) =>
      _call((api) => api.cancelGroupPlannedExpense(item.groupId, item.id));

  Future<GroupTargets> targets(String groupId) => _call(
      (api) async => GroupTargets.fromApi(await api.getGroupTargets(groupId)));

  /// Sets the caller's own monthly target in [groupId]; zero clears it.
  Future<GroupTargets> setTarget(String groupId, double amount) =>
      _call((api) async =>
          GroupTargets.fromApi(await api.setGroupTarget(groupId, amount)));

  /// Leader only: turns target spendings on or off for the whole group.
  Future<GroupTargets> setTargetsEnabled(String groupId, bool enabled) =>
      _call((api) async => GroupTargets.fromApi(
          await api.setGroupTargetsEnabled(groupId, enabled)));

  /// Adds a category to [groupId], or renames [categoryId]. Group admin
  /// only - the server refuses anyone else.
  Future<GroupCategory> saveCategory({
    required String groupId,
    String? categoryId,
    required String name,
    String kind = 'spending',
  }) =>
      _call((api) async => GroupCategory.fromApi(await api.saveGroupCategory(
            groupId: groupId,
            categoryId: categoryId ?? _uuid.v4(),
            name: name.trim(),
            kind: kind,
          )));

  /// Removes a group category. Group admin only. Transactions already filed
  /// under it keep its name.
  Future<void> deleteCategory(GroupCategory category) =>
      _call((api) => api.deleteGroupCategory(category.groupId, category.id));

  Future<GroupSettlements> settlements(String groupId) => _call((api) async =>
      GroupSettlements.fromApi(await api.getGroupSettlements(groupId)));

  /// Pays the owner of a group spending back [amount], from the caller's
  /// [fromSourceId] into the owner's [toSourceId]. Returns the new
  /// reimbursement's id, which a proof of transfer is attached to.
  Future<String> reimburse({
    required String groupId,
    required String transactionId,
    required String fromSourceId,
    required double amount,
    required String toSourceId,
    String description = '',
  }) async {
    final id = _uuid.v4();
    await _call((api) => api.reimburseGroupTransaction(
          groupId: groupId,
          reimbursementId: id,
          transactionId: transactionId,
          fromSourceId: fromSourceId,
          amount: amount,
          toSourceId: toSourceId,
          description: description,
        ));
    return id;
  }

  /// Splits part of the caller's group spending to a group member
  /// ([username]) or to someone outside the app ([name]).
  Future<void> addSplitShare({
    required String groupId,
    required String transactionId,
    String? username,
    String? name,
    required double amount,
  }) =>
      _call((api) => api.addGroupSplitShare(
            groupId: groupId,
            shareId: _uuid.v4(),
            transactionId: transactionId,
            username: username,
            name: name,
            amount: amount,
          ));

  Future<void> removeSplitShare(GroupSplitShare share) =>
      _call((api) => api.removeGroupSplitShare(share.groupId, share.id));

  /// Pays part or all of the caller's share from [fromSourceId]. Waits for
  /// the owner's approval. Returns the payment's id, which a proof of
  /// transfer is attached to.
  Future<String> paySplitShare(GroupSplitShare share,
      {required double amount,
      required String fromSourceId,
      String note = ''}) async {
    final id = _uuid.v4();
    await _call((api) => api.payGroupSplitShare(
          groupId: share.groupId,
          shareId: share.id,
          paymentId: id,
          amount: amount,
          fromSourceId: fromSourceId,
          note: note,
        ));
    return id;
  }

  /// The owner records money from a name-only person, into [toSourceId].
  /// Returns the payment's id.
  Future<String> recordSplitPayment(GroupSplitShare share,
      {required double amount,
      required String toSourceId,
      String note = ''}) async {
    final id = _uuid.v4();
    await _call((api) => api.recordGroupSplitPayment(
          groupId: share.groupId,
          shareId: share.id,
          paymentId: id,
          amount: amount,
          toSourceId: toSourceId,
          note: note,
        ));
    return id;
  }

  /// Approves into [toSourceId], or rejects.
  Future<void> reviewSplitPayment(GroupSplitPayment payment,
          {required bool approve, String? toSourceId}) =>
      _call((api) => api.reviewGroupSplitPayment(
            groupId: payment.groupId,
            paymentId: payment.id,
            approve: approve,
            toSourceId: toSourceId,
          ));

  Future<void> withdrawSplitPayment(GroupSplitPayment payment) => _call(
      (api) => api.withdrawGroupSplitPayment(payment.groupId, payment.id));

  Future<void> forgetName(String groupId, String name) =>
      _call((api) => api.forgetGroupName(groupId, name));

  /// Source names of [username], who must share a group with the caller.
  Future<List<MemberSource>> memberSources(String username) =>
      _call((api) async => (await api.getMemberSources(username))
          .map(MemberSource.fromApi)
          .toList());

  /// Moves [amount] from the caller's [fromSourceId] to [toUsername]'s
  /// [toSourceId]: a spending for the caller, an earning for the recipient.
  /// Only the sender can do this - nothing is ever pulled from someone else.
  Future<void> transferToMember({
    required String toUsername,
    required String fromSourceId,
    required String toSourceId,
    required double amount,
    String description = '',
  }) =>
      _call((api) => api.sendMemberTransfer(
            transferId: _uuid.v4(),
            toUsername: toUsername,
            fromSourceId: fromSourceId,
            toSourceId: toSourceId,
            amount: amount,
            description: description,
          ));
}
