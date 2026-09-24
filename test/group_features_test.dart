import 'package:flutter_test/flutter_test.dart';
import 'package:personal_dashboard/core/group_models.dart';
import 'package:personal_dashboard/core/models.dart';

void main() {
  group('group plans', () {
    test('parses routines and planned expenses from the API shape', () {
      final routine = GroupRoutine.fromApi({
        'routine_id': 'r1',
        'group_id': 'g1',
        'item_name': 'Internet',
        'price': 300000,
        'reminder': 'monthly',
        'spending_category_id': 'c1',
        'spending_category': 'Bills',
        'last_paid_at': null,
        'last_paid_by': null,
        'created_by': 'alice',
      });
      expect(routine.price, 300000.0);
      expect(routine.lastPaidAt, isNull);

      final item = GroupPlannedExpense.fromApi({
        'planned_expense_id': 'p1',
        'group_id': 'g1',
        'item_name': 'Fan',
        'price': 400000.0,
        'spending_category_id': 'c1',
        'spending_category': 'Home',
        'notes': '',
        'status': 'requested',
        'requested_by': 'bob',
        'reviewed_by': null,
        'fulfilled_price': null,
        'created_date': '2026-09-22T21:17:30',
      });
      expect(item.isRequested, isTrue);
      expect(item.isOpen, isTrue);
      expect(item.fulfilledPrice, isNull);
    });

    test('filters everything by group', () {
      GroupPlannedExpense item(String group, String status) =>
          GroupPlannedExpense.fromApi({
            'planned_expense_id': '$group-$status',
            'group_id': group,
            'status': status,
            'price': 1,
          });
      final plans = GroupPlans(plannedExpenses: [
        item('g1', 'planned'),
        item('g2', 'planned'),
        item('g1', 'fulfilled'),
      ]);
      expect(plans.plannedExpensesOf('g1').length, 2);
      expect(plans.plannedExpensesOf('g1').where((i) => i.isOpen).length, 1);
      expect(plans.routinesOf('g1'), isEmpty);
    });
  });

  group('group targets', () {
    test('parses targets; targetOf ignores name case', () {
      final targets = GroupTargets.fromApi({
        'group_id': 'g1',
        'is_leader': true,
        'enabled': true,
        'targets': [
          {
            'group_id': 'g1',
            'username': 'Alice',
            'amount': 500000,
            'updated_date': '2026-09-22T20:00:00',
          },
          {'username': 'bob', 'amount': 250000.0},
        ],
      });
      expect(targets.isLeader, isTrue);
      expect(targets.enabled, isTrue);
      expect(targets.targetOf('alice'), 500000.0);
      expect(targets.targetOf('BOB'), 250000.0);
      expect(targets.targetOf('carol'), isNull);
    });

    test('switched off by the leader; older servers count as on', () {
      expect(
          GroupTargets.fromApi({'is_leader': false, 'enabled': false}).enabled,
          isFalse);
      final old = GroupTargets.fromApi({'is_leader': false, 'targets': []});
      expect(old.enabled, isTrue);
      expect(old.targets, isEmpty);
    });

    test('progress: left, over and the bar ratio', () {
      const under = TargetProgress(target: 400000, spent: 100000);
      expect(under.left, 300000);
      expect(under.isOver, isFalse);
      expect(under.ratio, 0.25);
      const over = TargetProgress(target: 400000, spent: 450000);
      expect(over.isOver, isTrue);
      expect(over.left, -50000);
      expect(over.ratio, 1.0);
      const exact = TargetProgress(target: 400000, spent: 400000);
      expect(exact.isOver, isFalse);
      expect(exact.ratio, 1.0);
    });
  });

  group('reimbursements & split bills', () {
    final settlements = GroupSettlements.fromApi({
      'reimbursements': [
        {
          'reimbursement_id': 'r1',
          'transaction_id': 't1',
          'owner': 'alice',
          'paid_by': 'bob',
          'from_source': 'Bob BCA',
          'personal_amount': 200000,
          'to_source': 'Alice BCA',
          'group_amount': 50000,
          'amount': 250000,
          'created_date': '2026-09-23T10:00:00',
        },
        {
          'reimbursement_id': 'r2',
          'transaction_id': 'other',
          'personal_amount': 0,
          'to_source': null,
          'group_amount': 10,
          'amount': 10,
        },
      ],
      'shares': [
        {
          'share_id': 's1',
          'transaction_id': 't1',
          'owner': 'alice',
          'username': 'carol',
          'name': 'carol',
          'amount': 80000,
          'paid_amount': 50000,
          'pending_amount': 20000,
        },
        {
          'share_id': 's2',
          'transaction_id': 't1',
          'owner': 'alice',
          'username': null,
          'name': 'Eve',
          'amount': 20000,
          'paid_amount': 20000,
          'pending_amount': 0,
        },
      ],
      'payments': [
        {'payment_id': 'p1', 'share_id': 's1', 'status': 'pending', 'amount': 20000},
        {'payment_id': 'p2', 'share_id': 'x', 'status': 'approved', 'amount': 1},
      ],
      'names': ['Eve'],
    });

    test('splits reimbursements into personal and group parts', () {
      final s = settlements.forTransaction('t1');
      expect(s.reimbursements.length, 1);
      expect(s.reimbursedPersonal, 200000.0);
      expect(s.reimbursedGroup, 50000.0);
      expect(s.reimbursed, 250000.0);
    });

    test('tracks split shares, payments and what is left', () {
      final s = settlements.forTransaction('t1');
      expect(s.shares.length, 2);
      expect(s.splitTotal, 100000.0);
      expect(s.splitPaid, 70000.0);
      expect(s.paymentsOf('s1').single.isPending, isTrue);
      expect(s.payments.length, 1, reason: 'payments of other shares excluded');
      // 400k spending - 250k reimbursed - 100k split out.
      expect(s.leftOf(400000), 50000.0);
      expect(s.leftOf(300000), 0.0);
    });

    test('share helpers', () {
      final s = settlements.forTransaction('t1');
      final carol = s.shares.first;
      final eve = s.shares.last;
      expect(carol.isRegistered, isTrue);
      expect(carol.isFor('Carol'), isTrue);
      expect(carol.unpaid, 30000.0);
      expect(carol.payable, 10000.0);
      expect(carol.isPaid, isFalse);
      expect(eve.isRegistered, isFalse);
      expect(eve.isFor('Eve'), isFalse);
      expect(eve.isPaid, isTrue);
      expect(settlements.names, ['Eve']);
    });
  });
  group('return balance, categories and names', () {
    // Reimbursements made while groups still had balances keep the flag.
    test('a reimbursement can return the amount to the group balance', () {
      final s = GroupSettlements.fromApi({
        'reimbursements': [
          {
            'reimbursement_id': 'r1',
            'transaction_id': 't1',
            'personal_amount': 30000,
            'group_amount': 0,
            'amount': 30000,
            'return_balance': true,
          },
          {
            'reimbursement_id': 'r2',
            'transaction_id': 't1',
            'personal_amount': 20000,
            'group_amount': 0,
            'amount': 20000,
            'return_balance': false,
          },
        ],
      }).forTransaction('t1');
      expect(s.reimbursed, 50000.0);
      expect(s.balanceReturned, 30000.0);
      expect(s.reimbursements.first.returnBalance, isTrue);
    });

    test('group categories, spender source and display names', () {
      final txn = GroupTransaction.fromApi({
        'group_id': 'g1',
        'transaction_type': 'spending',
        'transaction_id': 't1',
        'total_amount': 50000,
        'category': 'Groceries',
        'created_date': '2026-09-23T10:00:00',
        'created_by': 'alice',
        'source': 'BCA',
      });
      expect(txn.source, 'BCA');
      expect(GroupTransaction.fromMap(txn.toMap()).source, 'BCA');

      final data = const AppData(
        sources: [],
        categories: [],
        transactions: [],
      ).withGroups(
        spendingGroups: const [],
        groupMembers: const [],
        groupStatusChanges: const [],
        groupTransactions: [txn],
        groupCategories: [
          GroupCategory.fromApi({
            'category_id': 'c2',
            'group_id': 'g1',
            'category_name': 'snacks',
            'kind': 'spending',
          }),
          GroupCategory.fromApi({
            'category_id': 'c1',
            'group_id': 'g1',
            'category_name': 'Groceries',
            'kind': 'spending',
          }),
          const GroupCategory(
              id: 'c3', groupId: 'g1', name: 'Refund', kind: 'earning'),
          const GroupCategory(id: 'c4', groupId: 'g2', name: 'Fuel'),
        ],
        displayNames: const {'alice': 'Alice Doe'},
      );
      expect(
          data.groupCategoriesOf('g1', kind: 'spending').map((c) => c.name),
          ['Groceries', 'snacks']);
      expect(data.groupCategoriesOf('g1').length, 3);
      expect(data.displayName('Alice'), 'Alice Doe');
      expect(data.displayName('bob'), 'bob');
    });
  });

  group('fund requests', () {
    test('parses requests, usage and tag balances from the API shape', () {
      final funds = FundRequests.fromApi({
        'requests': [
          {
            'request_id': 'f1',
            'group_id': 'g1',
            'kind': 'request',
            'requester': 'bob',
            'payer': 'alice',
            'amount': 100000,
            'tag': 'Transportation',
            'note': '',
            'tracked': true,
            'status': 'sent',
            'to_source': 'Bob BCA',
            'created_by': 'bob',
            'created_date': '2026-09-24T10:00:00',
            'sent_at': '2026-09-24T11:00:00',
            'spent': 30000,
            'remaining': 70000,
            'waived_amount': 0,
            'usage': [
              {
                'spending_id': 's1',
                'description': 'Grab',
                'spending_amount': 30000,
                'amount': 30000,
                'created_date': '2026-09-24T12:00:00',
              },
            ],
          },
          {
            'request_id': 'f2',
            'group_id': 'g2',
            'kind': 'request',
            'requester': 'carol',
            'payer': 'bob',
            'amount': 5000,
            'tag': 'Snacks',
            'tracked': false,
            'status': 'requested',
            'created_by': 'carol',
            'created_date': '2026-09-24T10:00:00',
          },
        ],
        'balances': [
          {
            'group_id': 'g1',
            'username': 'bob',
            'tag': 'Transportation',
            'received': 100000,
            'spent': 30000,
            'waived': 0,
            'balance': 70000,
          },
        ],
      });
      final f1 = funds.of('g1').single;
      expect(f1.hasBalance, isTrue);
      expect(f1.remaining, 70000);
      expect(f1.usage.single.description, 'Grab');
      final f2 = funds.of('g2').single;
      expect(f2.isWaiting, isTrue);
      expect(f2.hasBalance, isFalse);
      expect(f2.toSourceId, isNull);
      expect(funds.balancesOf('g1').single.balance, 70000);
      expect(funds.balancesOf('g2'), isEmpty);
      expect(funds.cachedAt, isNull);
    });
  });
}
