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

/// Units a custom repeat can be counted in.
const customRepeatUnits = ['day', 'month', 'year'];

/// A routine's repeat rule, parsed from its `reminder` string.
///
/// The fixed choices are stored as before ('weekly', 'monthly', ...). A
/// custom timeline is stored as `custom:<every>:<unit>` - for example
/// `custom:10:day` or `custom:2:month` - in the same column, so the API and
/// older app builds need no schema change (older builds treat it as
/// monthly, the documented fallback for unknown values).
class RoutineRepeat {
  final int every;

  /// 'day', 'week', 'month' or 'year'.
  final String unit;
  final bool isCustom;

  const RoutineRepeat(this.every, this.unit, {this.isCustom = false});

  static RoutineRepeat parse(String reminder) {
    if (reminder.startsWith('custom:')) {
      final parts = reminder.split(':');
      final every = parts.length > 1 ? int.tryParse(parts[1]) : null;
      final unit = parts.length > 2 ? parts[2] : '';
      if (every != null && every > 0 && customRepeatUnits.contains(unit)) {
        return RoutineRepeat(every, unit, isCustom: true);
      }
      return const RoutineRepeat(1, 'month');
    }
    return switch (reminder) {
      'daily' => const RoutineRepeat(1, 'day'),
      'weekly' => const RoutineRepeat(1, 'week'),
      'bi-monthly' => const RoutineRepeat(2, 'month'),
      'quarterly' => const RoutineRepeat(3, 'month'),
      'yearly' => const RoutineRepeat(1, 'year'),
      _ => const RoutineRepeat(1, 'month'),
    };
  }
}

/// The stored form of a custom repeat.
String customReminder(int every, String unit) => 'custom:$every:$unit';

/// Whether [reminder] is a custom timeline.
bool isCustomReminder(String reminder) => reminder.startsWith('custom:');

/// Human wording of [reminder]: the fixed choices as they are, a custom one
/// as "every 10 days" / "every month".
String reminderLabel(String reminder) {
  if (!isCustomReminder(reminder)) return reminder;
  final r = RoutineRepeat.parse(reminder);
  return r.every == 1 ? 'every ${r.unit}' : 'every ${r.every} ${r.unit}s';
}

/// Rough cost per month of a routine costing [price] per cycle.
double monthlyEstimate(double price, String reminder) {
  final r = RoutineRepeat.parse(reminder);
  return switch (r.unit) {
    'day' => price * 30 / r.every,
    'week' => price * 4 / r.every,
    'year' => price / (12 * r.every),
    _ => price / r.every,
  };
}

/// Advances [from] by one cycle of [reminder].
///
/// 'bi-monthly' means every second month, matching how the routine screen
/// prices it (a monthly estimate of `price / 2`). Unknown values fall back to
/// monthly, which is also the model's default.
DateTime addReminderPeriod(DateTime from, String reminder) {
  final r = RoutineRepeat.parse(reminder);
  return switch (r.unit) {
    'day' => DateTime(from.year, from.month, from.day + r.every),
    'week' => DateTime(from.year, from.month, from.day + 7 * r.every),
    'year' => addMonths(from, 12 * r.every),
    _ => addMonths(from, r.every),
  };
}

/// First day of the billing period of [reminder] that contains [today].
///
/// This is what "paid" resets against. The fixed choices follow the
/// calendar: a weekly routine's period starts on Monday, monthly on the 1st,
/// bi-monthly / quarterly on the 1st of Jan, Mar, May... / Jan, Apr, Jul,
/// Oct, and yearly on 1 January. A custom timeline has no calendar to follow,
/// so its periods are counted from [anchor] (the day the routine was
/// created): every 10 days from then, or every 2 months from the 1st of the
/// anchor's month, or every 2 years from 1 January of the anchor's year.
DateTime currentPeriodStart(String reminder, DateTime today,
    {DateTime? anchor}) {
  final day = dateOnly(today);
  final r = RoutineRepeat.parse(reminder);
  final base = anchor == null ? null : dateOnly(anchor);
  switch (r.unit) {
    case 'day':
      if (base == null || r.every == 1) return day;
      final diff = _daysBetween(base, day);
      final k = (diff / r.every).floor();
      return DateTime(base.year, base.month, base.day + k * r.every);
    case 'week':
      final monday = DateTime(day.year, day.month, day.day - (day.weekday - 1));
      if (base == null || r.every == 1) return monday;
      final baseMonday =
          DateTime(base.year, base.month, base.day - (base.weekday - 1));
      final weeks = (_daysBetween(baseMonday, monday) / 7).round();
      final k = (weeks / r.every).floor();
      return DateTime(baseMonday.year, baseMonday.month,
          baseMonday.day + k * r.every * 7);
    case 'year':
      final origin = r.isCustom && base != null ? base.year : day.year;
      final k = ((day.year - origin) / r.every).floor();
      return DateTime(origin + k * r.every, 1, 1);
    default:
      final idx = day.year * 12 + day.month - 1;
      // Fixed choices line up with the calendar year (Jan, Mar, May... for
      // bi-monthly); a custom one lines up with the month it was created.
      final originIdx =
          r.isCustom && base != null ? base.year * 12 + base.month - 1 : 0;
      final k = ((idx - originIdx) / r.every).floor();
      final start = originIdx + k * r.every;
      return DateTime(start ~/ 12, start % 12 + 1, 1);
  }
}

/// Whole calendar days from [a] to [b] (negative when [b] is earlier),
/// immune to daylight-saving hours.
int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

/// Whether a routine repeating on [reminder] counts as paid for the period
/// containing [today], given the day it was last paid. The status resets to
/// "Not paid" as soon as the next period starts.
bool isPaidThisPeriod({
  required String reminder,
  required String? lastPaidAt,
  required DateTime today,
  String? createdDate,
}) {
  final paid = parseIsoDay(lastPaidAt);
  if (paid == null) return false;
  final start = currentPeriodStart(reminder, today,
      anchor: parseIsoDay(createdDate));
  return !paid.isBefore(start);
}

/// The day a period-based routine (a group routine) is due: the first day of
/// its current period while that period is still unpaid - the 1st of the
/// month for a monthly one - otherwise the first day of the next period.
DateTime periodDueDate({
  required String reminder,
  required String? lastPaidAt,
  required DateTime today,
  String? createdDate,
}) {
  final start =
      currentPeriodStart(reminder, today, anchor: parseIsoDay(createdDate));
  final paid = isPaidThisPeriod(
      reminder: reminder,
      lastPaidAt: lastPaidAt,
      createdDate: createdDate,
      today: today);
  if (!paid) return start;
  // The next period's start. For a custom day count that is simply one
  // cycle later; for calendar periods, recompute from a day inside it so the
  // result stays on the calendar boundary.
  return currentPeriodStart(reminder, addReminderPeriod(start, reminder),
      anchor: parseIsoDay(createdDate));
}

/// When to remind about a period-based routine due on [due]: on that day at
/// [hour]:[minute] - the 1st of the month for a monthly routine - and, once
/// that moment has passed while it is still unpaid, daily at the same time
/// until it is paid.
DateTime periodReminderFireTime(DateTime due,
    {required DateTime now, required int hour, required int minute}) {
  final planned = DateTime(due.year, due.month, due.day, hour, minute);
  if (planned.isAfter(now)) return planned;
  final todayAt = DateTime(now.year, now.month, now.day, hour, minute);
  if (todayAt.isAfter(now)) return todayAt;
  return todayAt.add(const Duration(days: 1));
}

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
