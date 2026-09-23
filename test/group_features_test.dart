import 'package:flutter_test/flutter_test.dart';
import 'package:personal_dashboard/core/group_models.dart';

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

  group('group balances', () {
    test('parses balances and history; balanceOf ignores name case', () {
      final balances = GroupBalances.fromApi({
        'group_id': 'g1',
        'is_leader': true,
        'balances': [
          {
            'username': 'Alice',
            'balance': 25000,
            'total_top_up': 100000,
            'total_spent': 75000,
          },
          {
            'username': 'bob',
            'balance': 0.0,
            'total_top_up': 0,
            'total_spent': 0,
          },
        ],
        'entries': [
          {
            'entry_id': 'e1',
            'group_id': 'g1',
            'username': 'Alice',
            'amount': -75000,
            'entry_type': 'spending',
            'description': 'groceries',
            'spending_category': 'Food',
            'created_date': '2026-09-22T21:00:00',
          },
          {
            'entry_id': 'e2',
            'group_id': 'g1',
            'username': 'Alice',
            'amount': 100000,
            'entry_type': 'top_up',
            'description': 'Add balance',
            'spending_category': null,
            'created_date': '2026-09-22T20:00:00',
          },
        ],
      });
      expect(balances.isLeader, isTrue);
      expect(balances.balanceOf('alice'), 25000.0);
      expect(balances.balanceOf('carol'), 0);
      expect(balances.entries.first.isTopUp, isFalse);
      expect(balances.entries.first.amount, -75000.0);
      expect(balances.entries.last.isTopUp, isTrue);
      expect(balances.entries.last.category, '');
    });

    test('a member only sees their own balance', () {
      final balances = GroupBalances.fromApi({
        'is_leader': false,
        'balances': [
          {'username': 'bob', 'balance': 5, 'total_top_up': 5, 'total_spent': 0},
        ],
        'entries': [],
      });
      expect(balances.isLeader, isFalse);
      expect(balances.balances.length, 1);
      expect(balances.balanceOf('bob'), 5.0);
    });
  });
}
