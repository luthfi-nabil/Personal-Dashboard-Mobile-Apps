/// Due-date arithmetic for routine transactions.
///
/// [RoutineTransaction.reminder] only carries a *frequency* ('weekly',
/// 'monthly', …) - there is no due date on the record and the API has no
/// column for one. The cycle is therefore anchored on the routine's own
/// history: the last payment if there is one, otherwise the day it was
/// created. Every confirmed payment re-anchors the cycle, so a routine paid
/// late simply shifts forward instead of accumulating drift.
///
/// Everything here is pure date math on calendar days - no plugins, no
/// clock reads except the `today`/`now` that callers pass in - so it is
/// unit-testable and safe to run inside the background isolate.
library;

import 'models.dart';

/// A routine together with the day its next payment falls due.
class RoutineDue {
  final RoutineTransaction routine;

  /// Midnight on the day the next payment is expected.
  final DateTime dueDate;

  const RoutineDue({required this.routine, required this.dueDate});

  /// Whether [dueDate] has already passed relative to [today].
  bool isOverdue(DateTime today) => dueDate.isBefore(dateOnly(today));

  /// Days until due; negative once overdue.
  int daysUntil(DateTime today) => dueDate.difference(dateOnly(today)).inDays;
}

/// Strips the time of day, leaving midnight local time.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Parses the leading `yyyy-MM-dd` of the ISO-ish strings the app stores.
///
/// Timestamps are written as naive GMT+7 wall-clock strings (see
/// `Repo._nowGmtPlus7Iso`), so only the date part is trustworthy - reading
/// them as instants would shift the day for anyone in another zone.
DateTime? parseIsoDay(String? s) {
  if (s == null || s.length < 10) return null;
  final year = int.tryParse(s.substring(0, 4));
  final month = int.tryParse(s.substring(5, 7));
  final day = int.tryParse(s.substring(8, 10));
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

/// Adds [months] calendar months, clamping the day to the length of the
/// target month so 31 Jan + 1 month lands on 28/29 Feb rather than spilling
/// into March.
DateTime addMonths(DateTime from, int months) {
  final totalMonths = from.month - 1 + months;
  final year = from.year + (totalMonths ~/ 12);
  final month = totalMonths % 12 + 1;
  final lastDayOfMonth = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, from.day.clamp(1, lastDayOfMonth));
}

/// Advances [from] by one cycle of [reminder].
///
/// 'bi-monthly' means every second month, matching how the routine screen
/// prices it (a monthly estimate of `price / 2`). Unknown values fall back to
/// monthly, which is also the model's default.
DateTime addReminderPeriod(DateTime from, String reminder) =>
    switch (reminder) {
      'weekly' => from.add(const Duration(days: 7)),
      'bi-monthly' => addMonths(from, 2),
      'quarterly' => addMonths(from, 3),
      'yearly' => addMonths(from, 12),
      _ => addMonths(from, 1),
    };

/// The day [routine]'s next payment falls due, or `null` when the record
/// carries no usable anchor date at all.
///
/// A routine that has never been paid falls due one cycle after it was
/// created. One that is behind reports the *earliest* unpaid due date rather
/// than catching up to the present, so an overdue bill keeps reading as
/// overdue by its real age instead of silently rolling forward.
DateTime? nextDueDate(RoutineTransaction routine) {
  final anchor =
      parseIsoDay(routine.lastBoughtAt) ?? parseIsoDay(routine.createdDate);
  if (anchor == null) return null;
  return addReminderPeriod(anchor, routine.reminder);
}

/// Pairs every active routine with its due date, earliest first.
///
/// Routines that are cancelled, or whose dates are unparseable, are dropped -
/// there is nothing meaningful to remind about.
List<RoutineDue> dueSchedule(Iterable<RoutineTransaction> routines) {
  final out = <RoutineDue>[];
  for (final routine in routines) {
    if (routine.status != 'active') continue;
    final due = nextDueDate(routine);
    if (due == null) continue;
    out.add(RoutineDue(routine: routine, dueDate: due));
  }
  out.sort((a, b) => a.dueDate.compareTo(b.dueDate));
  return out;
}

/// When the reminder for [due] should actually fire.
///
/// Normally that is [leadDays] before the due date at the user's chosen time.
/// If that moment has already passed - the routine is due today, or overdue,
/// or the app was not running when the lead time elapsed - the reminder
/// becomes a daily nudge at the next occurrence of [hour]:[minute]. Because
/// the schedule is rebuilt on every sync and every payment, that nudge
/// repeats each day until the routine is confirmed paid and disappears the
/// moment it is.
///
/// Returns `null` only when [due] is so far out that nothing needs
/// scheduling yet is impossible - it always yields a future instant.
DateTime reminderFireTime(
  RoutineDue due, {
  required DateTime now,
  required int leadDays,
  required int hour,
  required int minute,
}) {
  final planned = due.dueDate.subtract(Duration(days: leadDays));
  final plannedAt =
      DateTime(planned.year, planned.month, planned.day, hour, minute);
  if (plannedAt.isAfter(now)) return plannedAt;

  // The lead-time moment is behind us: nudge at the next occurrence of the
  // configured time instead.
  final todayAt = DateTime(now.year, now.month, now.day, hour, minute);
  if (todayAt.isAfter(now)) return todayAt;
  return todayAt.add(const Duration(days: 1));
}
