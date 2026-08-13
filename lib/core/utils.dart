import 'dart:ui';
import 'package:personal_dashboard/core/models.dart';

const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

String _formatIDR(int amount) {
  final s = amount.toString();
  final len = s.length;
  final buf = StringBuffer();
  for (int i = 0; i < len; i++) {
    if (i > 0 && (len - i) % 3 == 0) buf.write('.');
    buf.write(s[i]);
  }
  return buf.toString();
}

String fmtRp(double n, String mode) {
  final sign = n < 0 ? '−' : '';
  final abs = n.abs();
  if (mode == 'short') {
    if (abs >= 1000000) {
      final jt = (abs / 1000000).toStringAsFixed(1).replaceAll('.', ',');
      return '${sign}Rp $jt jt';
    }
    if (abs >= 1000) return '${sign}Rp ${(abs / 1000).round()} rb';
    return '${sign}Rp ${abs.round()}';
  }
  return '${sign}Rp ${_formatIDR(abs.round())}';
}

String fmtDate(String s, String kind) {
  if (s.isEmpty) return '';
  final d = DateTime.tryParse(s);
  if (d == null) return s;
  if (kind == 'short') return '${d.day} ${_months[d.month - 1]}';
  if (kind == 'time') {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  if (kind == 'long') return '${d.day} ${_months[d.month - 1]} ${d.year}';
  if (kind == 'monthYear') return '${_months[d.month - 1]} ${d.year}';
  return s;
}

/// A quantity with no trailing zeros - "5", "2,5", "12,3456". Used for
/// investment units, which are whole grams for metal but run to several
/// decimals for reksa dana.
String fmtUnits(double value) {
  if (value == value.roundToDouble()) return value.round().toString();
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String isoDay(String s) => s.length >= 10 ? s.substring(0, 10) : s;
String isoMonth(String s) => s.length >= 7 ? s.substring(0, 7) : s;

String prevMonth(String ym) {
  final d = DateTime(int.parse(ym.substring(0, 4)), int.parse(ym.substring(5, 7)) - 1, 1);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

String nextMonth(String ym) {
  final d = DateTime(int.parse(ym.substring(0, 4)), int.parse(ym.substring(5, 7)) + 1, 1);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

String monthLabel(String ym) {
  final month = int.parse(ym.substring(5, 7));
  return _months[month - 1];
}

String todayIsoMinute() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}'
      'T${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
}

const _sourceTones = <String, ({String m, Color tone})>{
  'BCA Debit':           (m: 'BD', tone: Color(0xFF1D4ED8)),
  'BCA Kredit':          (m: 'BK', tone: Color(0xFF9D174D)),
  'Blu by BCA':          (m: 'BL', tone: Color(0xFF0891B2)),
  'BCA-Pocket-Tabungan': (m: 'BP', tone: Color(0xFF475569)),
  'BluSaving-Tabungan':  (m: 'BS', tone: Color(0xFF0E7490)),
  'Cash':                (m: 'CA', tone: Color(0xFF15803D)),
  'Mandiri':             (m: 'MD', tone: Color(0xFFB45309)),
  'Gopay':               (m: 'GP', tone: Color(0xFF047857)),
  'Shopeepay':           (m: 'SP', tone: Color(0xFFC2410C)),
};

const _sourcePalette = [
  Color(0xFF1D4ED8), Color(0xFF9D174D), Color(0xFF0891B2), Color(0xFF475569),
  Color(0xFF15803D), Color(0xFFB45309), Color(0xFF7C2D12), Color(0xFF365314),
  Color(0xFF155E75), Color(0xFF5B21B6),
];

({String m, Color tone}) sourceTone(String name) {
  if (name.isEmpty) return (m: '?', tone: const Color(0xFF475569));
  if (_sourceTones.containsKey(name)) return _sourceTones[name]!;
  final parts = name.split(RegExp(r'\s+'));
  final m = parts.take(2).map((w) => w.isEmpty ? '' : w[0].toUpperCase()).join();
  int h = 0;
  for (final c in name.codeUnits) h = ((h * 31) + c) & 0xFFFFFFFF;
  return (m: m, tone: _sourcePalette[h % _sourcePalette.length]);
}

const _catPalette = [
  Color(0xFF3A3AFF), Color(0xFF0891B2), Color(0xFF1F8A4C), Color(0xFFC98A13),
  Color(0xFFC43A2B), Color(0xFF9D174D), Color(0xFF5B21B6), Color(0xFF0E7490),
  Color(0xFF475569), Color(0xFFB45309), Color(0xFF047857), Color(0xFF7C2D12),
  Color(0xFF365314), Color(0xFF155E75),
];

Color catColor(String name) {
  if (name.isEmpty) return const Color(0xFFA09C8E);
  int h = 0;
  for (final c in name.codeUnits) h = ((h * 31) + c) & 0xFFFFFFFF;
  return _catPalette[h % _catPalette.length];
}

// ── Data computations ──────────────────────────────────────────────────────

Map<String, double> computeBalances(List<Transaction> txns) {
  final bal = <String, double>{};
  for (final t in txns) {
    if (t.type == 'earning')  bal[t.source ?? ''] = (bal[t.source ?? ''] ?? 0) + t.amount;
    if (t.type == 'spending') bal[t.source ?? ''] = (bal[t.source ?? ''] ?? 0) - t.amount;
    if (t.type == 'transfer') {
      bal[t.fromSource ?? ''] = (bal[t.fromSource ?? ''] ?? 0) - t.amount;
      bal[t.toSource ?? '']   = (bal[t.toSource ?? ''] ?? 0) + t.amount;
    }
  }
  return bal;
}

({double earn, double spend, double net}) monthTotals(List<Transaction> txns, String ym) {
  double earn = 0, spend = 0;
  for (final t in txns) {
    if (isoMonth(t.date) != ym) continue;
    if (t.type == 'earning')  earn  += t.amount;
    if (t.type == 'spending') spend += t.amount;
  }
  return (earn: earn, spend: spend, net: earn - spend);
}

List<({String name, double amount, Color color})> spendByCategory(List<Transaction> txns, String ym) {
  final m = <String, double>{};
  for (final t in txns) {
    if (t.type != 'spending') continue;
    if (isoMonth(t.date) != ym) continue;
    final c = t.category ?? 'Uncategorized';
    m[c] = (m[c] ?? 0) + t.amount;
  }
  final list = m.entries.map((e) => (name: e.key, amount: e.value, color: catColor(e.key))).toList();
  list.sort((a, b) => b.amount.compareTo(a.amount));
  return list;
}

/// Running balance across all cash sources over time - the "liquid" line.
/// Investments are tracked separately and are deliberately not part of this.
List<double> liquidSeries(List<Transaction> txns) {
  final sorted = [...txns]..sort((a, b) => a.date.compareTo(b.date));
  final series = <double>[];
  double total = 0;
  for (final t in sorted) {
    if (t.type == 'earning'  && t.category != 'Recount') total += t.amount;
    if (t.type == 'spending' && t.category != 'Recount') total -= t.amount;
    series.add(total);
  }
  return series;
}

List<({String key, double earn, double spend, double net})> cashflowByMonth(List<Transaction> txns) {
  final m = <String, ({double earn, double spend})>{};
  for (final t in txns) {
    if (t.type == 'transfer') continue;
    final k = isoMonth(t.date);
    final prev = m[k] ?? (earn: 0.0, spend: 0.0);
    m[k] = t.type == 'earning'
        ? (earn: prev.earn + t.amount, spend: prev.spend)
        : (earn: prev.earn, spend: prev.spend + t.amount);
  }
  final list = m.entries.map((e) => (
    key: e.key,
    earn: e.value.earn,
    spend: e.value.spend,
    net: e.value.earn - e.value.spend,
  )).toList();
  list.sort((a, b) => a.key.compareTo(b.key));
  return list;
}

List<({String day, List<Transaction> txns})> groupByDay(List<Transaction> txns) {
  final m = <String, List<Transaction>>{};
  for (final t in txns) {
    final k = isoDay(t.date);
    (m[k] ??= []).add(t);
  }
  final list = m.entries.map((e) => (day: e.key, txns: e.value)).toList();
  list.sort((a, b) => b.day.compareTo(a.day));
  return list;
}

double densityPad(String density) => switch (density) {
  'compact' => 12.0,
  'comfy'   => 20.0,
  _         => 16.0,
};

double densityRow(String density) => switch (density) {
  'compact' => 52.0,
  'comfy'   => 68.0,
  _         => 60.0,
};
