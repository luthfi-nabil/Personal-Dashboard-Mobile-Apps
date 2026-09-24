import 'package:flutter/services.dart';

/// Money typed into a field, written the Indonesian way: `.` groups
/// thousands as the user types (`1.500.000`) and `,` starts the decimals.
///
/// Every money field uses [moneyInputFormatters] for input, [parseMoney] to
/// read it back and [formatMoneyInput] to pre-fill it.
class MoneyInputFormatter extends TextInputFormatter {
  /// How many digits may follow the decimal comma. Zero disallows decimals.
  final int decimals;

  const MoneyInputFormatter({this.decimals = 2});

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    // Digits (and the decimal comma) left of the cursor decide where the
    // cursor lands after regrouping.
    final cursor = newValue.selection.baseOffset.clamp(0, raw.length);
    final keptBeforeCursor =
        _keep(raw.substring(0, cursor), decimals: decimals).length;

    final kept = _keep(raw, decimals: decimals);
    final formatted = _group(kept);

    var seen = 0;
    var offset = 0;
    while (offset < formatted.length && seen < keptBeforeCursor) {
      if (formatted[offset] != '.') seen++;
      offset++;
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  /// Digits plus at most one decimal comma (and [decimals] digits after it).
  /// Dots are dropped: they are only ever grouping.
  static String _keep(String text, {required int decimals}) {
    final buf = StringBuffer();
    var comma = false;
    var fraction = 0;
    for (final ch in text.split('')) {
      if (ch == ',') {
        if (comma || decimals == 0) continue;
        comma = true;
        buf.write(ch);
      } else if (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) {
        if (comma) {
          if (fraction >= decimals) continue;
          fraction++;
        }
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  static String _group(String kept) {
    final comma = kept.indexOf(',');
    var whole = comma < 0 ? kept : kept.substring(0, comma);
    final fraction = comma < 0 ? '' : kept.substring(comma);
    // "007" is not a number anyone means; keep a single leading zero for
    // "0,5".
    whole = whole.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    if (whole.isEmpty && fraction.isNotEmpty) whole = '0';
    return '${groupThousands(whole)}$fraction';
  }
}

/// Input formatters for a money field.
const List<TextInputFormatter> moneyInputFormatters = [MoneyInputFormatter()];

/// `1500000` -> `1.500.000`. [digits] must be plain digits.
String groupThousands(String digits) {
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// Reads a money field: `1.500.000` and `1.500,50` (dots group, comma is
/// the decimal). Null when there is no number.
double? parseMoney(String text) {
  final cleaned = text.trim().replaceAll('.', '').replaceAll(',', '.');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

/// A stored amount as a money field shows it: `1500000` -> `1.500.000`,
/// `12.5` -> `12,5`, keeping up to [decimals] decimals (trailing zeros
/// dropped). Empty for zero when [emptyForZero] is set.
String formatMoneyInput(double value,
    {int decimals = 2, bool emptyForZero = false}) {
  if (emptyForZero && value == 0) return '';
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(decimals);
  final dot = fixed.indexOf('.');
  final whole = groupThousands(dot < 0 ? fixed : fixed.substring(0, dot));
  final fraction =
      dot < 0 ? '' : fixed.substring(dot + 1).replaceFirst(RegExp(r'0+$'), '');
  return '${negative ? '-' : ''}$whole${fraction.isEmpty ? '' : ',$fraction'}';
}
