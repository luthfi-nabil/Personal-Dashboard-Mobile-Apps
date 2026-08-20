import 'package:flutter_test/flutter_test.dart';
import 'package:personal_dashboard/core/models.dart';
import 'package:personal_dashboard/core/routine_schedule.dart';

RoutineTransaction routine({
  String id = 'r1',
  String reminder = 'monthly',
  String createdDate = '2026-01-10T08:00:00.000',
  String? lastBoughtAt,
  String status = 'active',
}) =>
    RoutineTransaction(
      id: id,
      itemName: 'Internet',
      price: 350000,
      reminder: reminder,
      categoryId: 'c1',
      categoryName: 'Utilities',
      status: status,
      lastBoughtAt: lastBoughtAt,
      createdDate: createdDate,
      updatedAt: createdDate,
    );

void main() {
  group('parseIsoDay', () {
    test('reads the date out of the naive GMT+7 timestamps the app stores', () {
      expect(parseIsoDay('2026-08-20T23:45:12.007'), DateTime(2026, 8, 20));
    });

    test('accepts a bare date', () {
      expect(parseIsoDay('2026-08-20'), DateTime(2026, 8, 20));
    });

    test('rejects null, short and non-numeric input', () {
      expect(parseIsoDay(null), isNull);
      expect(parseIsoDay('2026-08'), isNull);
      expect(parseIsoDay('not-a-date'), isNull);
      expect(parseIsoDay('2026-13-01'), isNull);
    });
  });

  group('addMonths', () {
    test('clamps to the last day when the target month is shorter', () {
      expect(addMonths(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
      expect(addMonths(DateTime(2028, 1, 31), 1), DateTime(2028, 2, 29));
      expect(addMonths(DateTime(2026, 3, 31), 1), DateTime(2026, 4, 30));
    });

    test('rolls over the year boundary', () {
      expect(addMonths(DateTime(2026, 11, 15), 3), DateTime(2027, 2, 15));
      expect(addMonths(DateTime(2026, 6, 1), 12), DateTime(2027, 6, 1));
    });
  });

  group('addReminderPeriod', () {
    final from = DateTime(2026, 1, 15);

    test('weekly steps seven days', () {
      expect(addReminderPeriod(from, 'weekly'), DateTime(2026, 1, 22));
    });

    test('bi-monthly means every second month, matching the cost estimate', () {
      expect(addReminderPeriod(from, 'bi-monthly'), DateTime(2026, 3, 15));
    });

    test('quarterly and yearly step three and twelve months', () {
      expect(addReminderPeriod(from, 'quarterly'), DateTime(2026, 4, 15));
      expect(addReminderPeriod(from, 'yearly'), DateTime(2027, 1, 15));
    });

    test('an unrecognised frequency falls back to monthly', () {
      expect(addReminderPeriod(from, 'fortnightly'), DateTime(2026, 2, 15));
    });
  });

  group('nextDueDate', () {
    test('anchors on the last payment when there is one', () {
      final due = nextDueDate(routine(
        createdDate: '2026-01-10T08:00:00.000',
        lastBoughtAt: '2026-05-03T19:20:00.000',
      ));
      expect(due, DateTime(2026, 6, 3));
    });

    test('falls back to the creation date for a routine never paid', () {
      expect(nextDueDate(routine(createdDate: '2026-01-10T08:00:00.000')),
          DateTime(2026, 2, 10));
    });

    test('reports the earliest unpaid date rather than catching up to now', () {
      // Paid once, long ago: the bill is months overdue and should read that
      // way instead of quietly rolling forward to next month.
      final due = nextDueDate(routine(lastBoughtAt: '2025-01-05T08:00:00.000'));
      expect(due, DateTime(2025, 2, 5));
    });

    test('returns null when no date on the record can be parsed', () {
      expect(nextDueDate(routine(createdDate: 'garbage')), isNull);
    });
  });

  group('dueSchedule', () {
    test('keeps only active routines and orders them earliest first', () {
      final schedule = dueSchedule([
        routine(id: 'late', lastBoughtAt: '2026-07-20T08:00:00.000'),
        routine(id: 'cancelled', status: 'inactive'),
        routine(id: 'early', lastBoughtAt: '2026-06-01T08:00:00.000'),
        routine(id: 'broken', createdDate: 'nope'),
      ]);

      expect(schedule.map((d) => d.routine.id), ['early', 'late']);
      expect(schedule.first.dueDate, DateTime(2026, 7, 1));
    });

    test('exposes overdue state and day counts against a given today', () {
      final schedule =
          dueSchedule([routine(lastBoughtAt: '2026-07-01T08:00:00.000')]);
      final due = schedule.single; // due 2026-08-01

      expect(due.isOverdue(DateTime(2026, 8, 20, 13, 5)), isTrue);
      expect(due.daysUntil(DateTime(2026, 8, 20, 13, 5)), -19);
      expect(due.isOverdue(DateTime(2026, 7, 25)), isFalse);
      expect(due.daysUntil(DateTime(2026, 7, 25)), 7);
    });
  });

  group('reminderFireTime', () {
    RoutineDue dueOn(DateTime day) =>
        RoutineDue(routine: routine(), dueDate: day);

    test('fires at the configured time, the lead days before the due date', () {
      final fire = reminderFireTime(
        dueOn(DateTime(2026, 9, 10)),
        now: DateTime(2026, 9, 1, 12, 0),
        leadDays: 3,
        hour: 9,
        minute: 30,
      );
      expect(fire, DateTime(2026, 9, 7, 9, 30));
    });

    test('a zero lead notifies on the due date itself', () {
      final fire = reminderFireTime(
        dueOn(DateTime(2026, 9, 10)),
        now: DateTime(2026, 9, 1, 12, 0),
        leadDays: 0,
        hour: 9,
        minute: 0,
      );
      expect(fire, DateTime(2026, 9, 10, 9, 0));
    });

    test('an overdue routine nudges at today\'s time when it is still ahead',
        () {
      final fire = reminderFireTime(
        dueOn(DateTime(2026, 8, 1)),
        now: DateTime(2026, 8, 20, 7, 0),
        leadDays: 1,
        hour: 9,
        minute: 0,
      );
      expect(fire, DateTime(2026, 8, 20, 9, 0));
    });

    test('once today\'s time has passed the nudge moves to tomorrow', () {
      final fire = reminderFireTime(
        dueOn(DateTime(2026, 8, 1)),
        now: DateTime(2026, 8, 20, 21, 15),
        leadDays: 1,
        hour: 9,
        minute: 0,
      );
      expect(fire, DateTime(2026, 8, 21, 9, 0));
    });

    test('always returns an instant in the future', () {
      final now = DateTime(2026, 8, 20, 9, 0, 1);
      for (final day in [
        DateTime(2020, 1, 1),
        DateTime(2026, 8, 20),
        DateTime(2026, 8, 21),
        DateTime(2030, 1, 1),
      ]) {
        final fire = reminderFireTime(dueOn(day),
            now: now, leadDays: 1, hour: 9, minute: 0);
        expect(fire.isAfter(now), isTrue, reason: 'due $day');
      }
    });
  });
}
