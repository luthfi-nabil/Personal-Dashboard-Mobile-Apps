import 'package:flutter_test/flutter_test.dart';
import 'package:personal_dashboard/core/models.dart';

GroupStatusChange _switch(String id, bool on, String at,
        {String groupId = 'g1'}) =>
    GroupStatusChange(
        id: id, groupId: groupId, isActive: on, changedBy: 'lead', changedAt: at);

GroupTransaction _txn(String id, String date, {String type = 'spending'}) =>
    GroupTransaction(
      groupId: 'g1',
      transactionType: type,
      transactionId: id,
      amount: 100,
      date: date,
      createdBy: 'other',
    );

AppData _data({
  List<GroupStatusChange> log = const [],
  List<GroupTransaction> groupTxns = const [],
  List<Transaction> transactions = const [],
}) =>
    AppData(
      sources: const [],
      categories: const [],
      transactions: transactions,
      spendingGroups: const [
        SpendingGroup(
            id: 'g1',
            name: 'Household',
            leader: 'lead',
            createdDate: '2026-09-01T00:00:00',
            updatedAt: '2026-09-01T00:00:00'),
      ],
      groupStatusChanges: log,
      groupTransactions: groupTxns,
    );

void main() {
  group('isGroupActive', () {
    test('a group nobody has switched is on', () {
      expect(_data().isGroupActive('g1'), isTrue);
      expect(_data().activeGroups.map((g) => g.id), ['g1']);
    });

    test('the latest switch by time wins, not the order it arrived in', () {
      final data = _data(log: [
        _switch('b', true, '2026-09-20T10:00:00'),
        _switch('a', false, '2026-09-10T10:00:00'),
      ]);
      expect(data.isGroupActive('g1'), isTrue);
      expect(data.isGroupActive('g1', at: '2026-09-15T00:00:00'), isFalse);
      expect(data.isGroupActive('g1', at: '2026-09-05T00:00:00'), isTrue);
    });

    test('a switched-off group is not offered for new transactions', () {
      final data = _data(log: [_switch('a', false, '2026-09-10T10:00:00')]);
      expect(data.activeGroups, isEmpty);
    });
  });

  group('isAfterTurnedOff', () {
    test('flags only transactions made while the group was off', () {
      final data = _data(log: [
        _switch('a', false, '2026-09-10T10:00:00'),
        _switch('b', true, '2026-09-12T10:00:00'),
      ]);
      expect(data.isAfterTurnedOff(_txn('1', '2026-09-09T09:00:00')), isFalse);
      expect(data.isAfterTurnedOff(_txn('2', '2026-09-11T09:00:00')), isTrue);
      expect(data.isAfterTurnedOff(_txn('3', '2026-09-13T09:00:00')), isFalse);
    });

    test('accepts the server space-separated timestamp form', () {
      final data = _data(log: [_switch('a', false, '2026-09-10 10:00:00')]);
      expect(data.isAfterTurnedOff(_txn('1', '2026-09-10T10:00:01.500')),
          isTrue);
    });
  });

  group('groupTransactionsFor', () {
    test('adds the user\'s own offline-queued tagged transactions', () {
      final data = _data(
        groupTxns: [_txn('server-1', '2026-09-02T08:00:00')],
        transactions: const [
          Transaction(
            id: 'local-1',
            type: 'earning',
            amount: 50,
            date: '2026-09-03T08:00:00',
            syncState: 'pending',
            updatedAt: '2026-09-03T08:00:00',
            groupId: 'g1',
          ),
          Transaction(
            id: 'local-2',
            type: 'spending',
            amount: 70,
            date: '2026-09-04T08:00:00',
            syncState: 'pending',
            updatedAt: '2026-09-04T08:00:00',
          ),
        ],
      );
      final rows = data.groupTransactionsFor('g1', 'me');
      expect(rows.map((t) => t.transactionId), ['local-1', 'server-1']);
      expect(rows.first.createdBy, 'me');
      expect(rows.first.syncState, 'pending');
    });
  });
}
