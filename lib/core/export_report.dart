import 'models.dart';
import 'utils.dart';

/// Data model for the finance export (Excel / Word).
///
/// Everything the writers need is precomputed here so `export_xlsx.dart` and
/// `export_docx.dart` stay dumb formatters, and so the desktop (Electron) port
/// in `renderer/js/export.js` can mirror the exact same numbers.

class MonthSummary {
  final String ym; // 'YYYY-MM'
  final double earn;
  final double spend;
  final int earnCount;
  final int spendCount;
  final int transferCount;

  const MonthSummary({
    required this.ym,
    required this.earn,
    required this.spend,
    required this.earnCount,
    required this.spendCount,
    required this.transferCount,
  });

  double get net => earn - spend;
  String get label => '${monthLabel(ym)} ${ym.substring(0, 4)}';
}

class CategoryBreakdown {
  final String ym;
  final String type; // 'earning' | 'spending'
  final String category;
  final int count;
  final double amount;

  /// Share of the month's total for that type, 0..1.
  final double share;

  const CategoryBreakdown({
    required this.ym,
    required this.type,
    required this.category,
    required this.count,
    required this.amount,
    required this.share,
  });
}

class SourceBalance {
  final String name;
  final String kind;
  final double balance;

  const SourceBalance(
      {required this.name, required this.kind, required this.balance});
}

class ExportReport {
  /// Selected months, ascending ('YYYY-MM').
  final List<String> months;
  final DateTime generatedAt;
  final List<MonthSummary> summaries;
  final List<CategoryBreakdown> categories;

  /// Transactions inside the selected months, newest first.
  final List<Transaction> transactions;

  /// Balances across *all* history, i.e. a snapshot at export time.
  final List<SourceBalance> sources;

  const ExportReport({
    required this.months,
    required this.generatedAt,
    required this.summaries,
    required this.categories,
    required this.transactions,
    required this.sources,
  });

  double get totalEarn => summaries.fold(0.0, (s, m) => s + m.earn);
  double get totalSpend => summaries.fold(0.0, (s, m) => s + m.spend);
  double get totalNet => totalEarn - totalSpend;
  double get liquid => sources.fold(0.0, (s, x) => s + x.balance);

  double get avgEarn => summaries.isEmpty ? 0 : totalEarn / summaries.length;
  double get avgSpend => summaries.isEmpty ? 0 : totalSpend / summaries.length;

  MonthSummary? get bestMonth => summaries.isEmpty
      ? null
      : summaries.reduce((a, b) => b.net > a.net ? b : a);

  MonthSummary? get worstMonth => summaries.isEmpty
      ? null
      : summaries.reduce((a, b) => b.net < a.net ? b : a);

  /// Category rows for one month and type, biggest first.
  List<CategoryBreakdown> categoriesFor(String ym, String type) => categories
      .where((c) => c.ym == ym && c.type == type)
      .toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));

  List<Transaction> transactionsFor(String ym) =>
      transactions.where((t) => isoMonth(t.date) == ym).toList();

  /// Label used for the range, e.g. "Jan 2026 – Mar 2026".
  String get rangeLabel {
    if (months.isEmpty) return '—';
    final first = summaries.first.label;
    if (months.length == 1) return first;
    return '$first – ${summaries.last.label}';
  }

  /// Default file name stem, e.g. `finance-recap_2026-01_2026-03`.
  String get fileStem {
    if (months.isEmpty) return 'finance-recap';
    if (months.length == 1) return 'finance-recap_${months.first}';
    return 'finance-recap_${months.first}_${months.last}';
  }

  /// Builds the report for [months] (any order, duplicates tolerated).
  static ExportReport build(AppData data, Iterable<String> months) {
    final selected = months.toSet().toList()..sort();

    final summaries = <MonthSummary>[];
    final categories = <CategoryBreakdown>[];

    for (final ym in selected) {
      double earn = 0, spend = 0;
      int earnCount = 0, spendCount = 0, transferCount = 0;
      final byCat = <String, Map<String, ({int count, double amount})>>{
        'earning': {},
        'spending': {},
      };

      for (final t in data.transactions) {
        if (isoMonth(t.date) != ym) continue;
        if (t.type == 'transfer') {
          transferCount++;
          continue;
        }
        final cat = (t.category == null || t.category!.trim().isEmpty)
            ? 'Uncategorized'
            : t.category!;
        final bucket = byCat[t.type];
        if (bucket == null) continue; // unknown type – ignore defensively
        final prev = bucket[cat] ?? (count: 0, amount: 0.0);
        bucket[cat] = (count: prev.count + 1, amount: prev.amount + t.amount);

        if (t.type == 'earning') {
          earn += t.amount;
          earnCount++;
        } else if (t.type == 'spending') {
          spend += t.amount;
          spendCount++;
        }
      }

      summaries.add(MonthSummary(
        ym: ym,
        earn: earn,
        spend: spend,
        earnCount: earnCount,
        spendCount: spendCount,
        transferCount: transferCount,
      ));

      for (final type in const ['spending', 'earning']) {
        final total = type == 'spending' ? spend : earn;
        final rows = byCat[type]!.entries.toList()
          ..sort((a, b) => b.value.amount.compareTo(a.value.amount));
        for (final e in rows) {
          categories.add(CategoryBreakdown(
            ym: ym,
            type: type,
            category: e.key,
            count: e.value.count,
            amount: e.value.amount,
            share: total > 0 ? e.value.amount / total : 0,
          ));
        }
      }
    }

    final txns = data.transactions
        .where((t) => selected.contains(isoMonth(t.date)))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    final balances = computeBalances(data.transactions);
    final sources = <SourceBalance>[];
    final seen = <String>{};
    for (final s in data.sources) {
      seen.add(s.name);
      sources.add(
          SourceBalance(name: s.name, kind: s.kind, balance: balances[s.name] ?? 0));
    }
    // Sources that only exist on transactions (deleted / not yet synced).
    for (final entry in balances.entries) {
      if (entry.key.isEmpty || seen.contains(entry.key)) continue;
      sources.add(
          SourceBalance(name: entry.key, kind: 'unknown', balance: entry.value));
    }
    sources.sort((a, b) => b.balance.compareTo(a.balance));

    return ExportReport(
      months: selected,
      generatedAt: DateTime.now(),
      summaries: summaries,
      categories: categories,
      transactions: txns,
      sources: sources,
    );
  }

  /// Every month that has at least one transaction, newest first.
  static List<String> availableMonths(AppData data) {
    final set = <String>{};
    for (final t in data.transactions) {
      final m = isoMonth(t.date);
      if (m.length == 7) set.add(m);
    }
    // Always offer the current month, even on a fresh account.
    final now = DateTime.now();
    set.add('${now.year}-${now.month.toString().padLeft(2, '0')}');
    final list = set.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }
}
