import 'package:uuid/uuid.dart';

import 'config.dart';
import 'group_models.dart';
import 'remote_api.dart';
import 'sync.dart';

/// Online-only calls for the group features that move money between
/// members' records (group routines, planned expenses, transfers to members,
/// group balances).
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

  Future<GroupPlans> loadPlans() => _call((api) async {
        final results = await Future.wait([
          api.getGroupRoutines(),
          api.getGroupRoutinePayments(),
          api.getGroupPlannedExpenses(),
        ]);
        return GroupPlans(
          routines: results[0].map(GroupRoutine.fromApi).toList(),
          routinePayments: results[1].map(GroupRoutinePayment.fromApi).toList(),
          plannedExpenses:
              results[2].map(GroupPlannedExpense.fromApi).toList(),
        );
      });

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

  /// Pays from [sourceId], or from the caller's group balance when null.
  Future<void> payRoutine(GroupRoutine routine,
          {required double price, String? sourceId}) =>
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

  /// Pays from [sourceId], or from the caller's group balance when null.
  Future<void> fulfillPlannedExpense(GroupPlannedExpense item,
          {required double price, String? sourceId}) =>
      _call((api) => api.fulfillGroupPlannedExpense(
            groupId: item.groupId,
            id: item.id,
            paymentId: _uuid.v4(),
            price: price,
            sourceId: sourceId,
          ));

  Future<void> cancelPlannedExpense(GroupPlannedExpense item) =>
      _call((api) => api.cancelGroupPlannedExpense(item.groupId, item.id));

  Future<GroupBalances> balances(String groupId) => _call((api) async =>
      GroupBalances.fromApi(await api.getGroupBalances(groupId)));

  /// Adds [amount] to the caller's own balance in [groupId].
  Future<void> topUp(String groupId, double amount,
          {String description = ''}) =>
      _call((api) => api.topUpGroupBalance(
            groupId: groupId,
            entryId: _uuid.v4(),
            amount: amount,
            description: description,
          ));

  /// A group transaction paid from the caller's balance in [groupId].
  Future<void> spendFromBalance({
    required String groupId,
    required double amount,
    required String categoryId,
    required String category,
    String description = '',
  }) =>
      _call((api) => api.spendGroupBalance(
            groupId: groupId,
            entryId: _uuid.v4(),
            amount: amount,
            categoryId: categoryId,
            category: category,
            description: description,
          ));

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
