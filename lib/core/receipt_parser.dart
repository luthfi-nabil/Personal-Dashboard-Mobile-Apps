/// Turns the raw text of a photographed receipt / price list into a list of
/// candidate line items the user can confirm before saving.
///
/// This file deliberately has **no plugin imports** so the heuristics can be
/// unit-tested on any platform (see `test/receipt_parser_test.dart`). The
/// platform-specific OCR step lives in `receipt_scanner.dart`.
///
/// The rules target Indonesian receipts, where thousands are grouped with `.`
/// (`32.000`) or `,` (`15,000`) and decimals are rare.
library;

/// One candidate row recognised on the receipt.
class ScannedItem {
  final String name;
  final double quantity;
  final double unitPrice;
  final double amount;

  /// True for a tax or service line (PPN, PB1, service charge). These are part
  /// of what was paid, so they are imported as line items like any product -
  /// only labelled differently on the review list.
  final bool isCharge;

  /// The receipt line this row came from, kept so the review screen can show
  /// the user what was actually read.
  final String sourceLine;

  const ScannedItem({
    required this.name,
    this.quantity = 1,
    this.unitPrice = 0,
    required this.amount,
    this.isCharge = false,
    this.sourceLine = '',
  });

  ScannedItem copyWith({
    String? name,
    double? quantity,
    double? unitPrice,
    double? amount,
    bool? isCharge,
  }) =>
      ScannedItem(
        name: name ?? this.name,
        quantity: quantity ?? this.quantity,
        unitPrice: unitPrice ?? this.unitPrice,
        amount: amount ?? this.amount,
        isCharge: isCharge ?? this.isCharge,
        sourceLine: sourceLine,
      );

  @override
  String toString() => 'ScannedItem($name, qty: $quantity, unit: $unitPrice, '
      'amount: $amount${isCharge ? ', charge' : ''})';
}

/// Everything the parser could make of one photo.
class ReceiptScanResult {
  final List<ScannedItem> items;

  /// The total printed on the receipt, when one was recognised. Lets the
  /// review screen flag a mismatch between the items and the paid amount.
  final double? printedTotal;

  /// Full OCR output, shown behind a "raw text" expander for debugging.
  final String rawText;

  const ReceiptScanResult({
    required this.items,
    this.printedTotal,
    this.rawText = '',
  });

  static const empty = ReceiptScanResult(items: []);

  double get itemsTotal =>
      items.fold<double>(0, (sum, item) => sum + item.amount);

  bool get isEmpty => items.isEmpty;
}

/// Lines matching these describe the receipt itself (totals, taxes, payment,
/// store details) rather than a purchased item.
///
/// Over-filtering is the safer failure mode: the review screen always lets the
/// user add a row by hand, but silently importing "KEMBALIAN 12.000" as an
/// expense would corrupt the transaction total.
///
/// Matched anywhere in the line - each of these is unambiguous enough that no
/// product name would contain it.
const _noiseSubstrings = <String>[
  'sub total',
  'subtotal',
  'sub-total',
  'grand total',
  'terima kasih',
  'thank you',
  'kembali',
  'tunai',
  'diskon',
  'discount',
  'potongan',
  'voucher',
  'pembulatan',
  'rounding',
  'npwp',
  'struk',
  'invoice',
  'faktur',
  'kasir',
  'cashier',
  'tanggal',
  'telepon',
  'telp',
  'alamat',
  'jalan',
  'jl.',
  'no.',
  'ref.',
  'approval',
  'shopeepay',
  'gopay',
  'qris',
  'saldo',
];

/// Matched as whole words only, so real products survive: "Ballpoint" keeps its
/// "point", "Cashew" keeps its "cash".
const _noiseWords = <String>[
  'total',
  'jumlah',
  'cash',
  'change',
  'dpp',
  'poin',
  'point',
  'member',
  'bayar',
  'payment',
  'debit',
  'kredit',
  'ovo',
  'dana',
  'harga',
  'qty',
  'kode',
  'void',
  'batch',
  'trace',
  'nota',
  'bill',
  'item',
  'waktu',
];

final _noiseWordPattern =
    RegExp('\\b(?:${_noiseWords.join('|')})\\b', caseSensitive: false);

/// Tax and service lines. They are not products, but they are part of what was
/// paid, so they are imported as line items rather than filtered out.
///
/// Checked before the noise rules and matched as whole words, so "Taxi ke
/// kantor" and "Serviceroti" stay ordinary items.
const _chargeWords = <String>[
  'ppn',
  'pb1',
  'pb-1',
  'pajak',
  'tax',
  'service',
  'svc',
  'layanan',
  'gratuity',
];

final _chargeWordPattern =
    RegExp('\\b(?:${_chargeWords.join('|')})\\b', caseSensitive: false);

/// Words that are pure currency markers and should never end up in an item name.
const _currencyWords = <String>['rp', 'rp.', 'idr', 'idr.', 'x', '@'];

final _moneyToken = RegExp(r'^(?:rp\.?|idr\.?)?(\d[\d.,]*)$', caseSensitive: false);
final _leadingQty = RegExp(r'^\s*(\d{1,3})\s*[x*]\s*', caseSensitive: false);
final _whitespace = RegExp(r'\s+');

class ReceiptParser {
  const ReceiptParser._();

  /// Parses [rawText] (the OCR output) into confirmable line items.
  ///
  /// [minAmount] guards against reading dates, table numbers or quantities as
  /// prices. The default suits Indonesian rupiah, where nothing costs < 100.
  static ReceiptScanResult parse(String rawText, {double minAmount = 100}) {
    final lines = rawText
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final items = <ScannedItem>[];
    double? printedTotal;
    double? subtotalCandidate;

    // A name whose price landed on the next OCR line. ML Kit splits widely
    // spaced columns into separate lines often enough to be worth handling.
    String? danglingName;

    for (final line in lines) {
      final lower = line.toLowerCase();
      final parsed = _parseLine(line);

      if (_looksLikeTotal(lower)) {
        final amount = parsed?.amount ?? _lastAmountIn(line);
        if (amount != null && amount >= minAmount) {
          if (lower.contains('sub')) {
            subtotalCandidate = amount;
          } else {
            printedTotal = amount;
          }
        }
        danglingName = null;
        continue;
      }

      // Tax / service. Charges are billed once for the whole receipt, so a
      // quantity column read off such a line is meaningless.
      if (_isCharge(lower)) {
        danglingName = null;
        if (parsed == null || parsed.amount < minAmount) continue;
        final name = parsed.name.isEmpty ? _cleanName(line) : parsed.name;
        items.add(parsed.copyWith(
          name: name.isEmpty ? 'Tax / service' : name,
          quantity: 1,
          unitPrice: parsed.amount,
          isCharge: true,
        ));
        continue;
      }

      if (_isNoise(lower)) {
        danglingName = null;
        continue;
      }

      if (parsed == null) {
        // No price on this line. If it reads like a product name, remember it
        // in case the price is on the line below.
        final name = _cleanName(line);
        danglingName = _looksLikeName(name) ? name : null;
        continue;
      }

      if (parsed.name.isEmpty) {
        // Price-only line - attach it to the name we saw just above.
        if (danglingName != null && parsed.amount >= minAmount) {
          items.add(parsed.copyWith(name: danglingName));
        }
        danglingName = null;
        continue;
      }

      danglingName = null;
      if (parsed.amount < minAmount) continue;
      items.add(parsed);
    }

    return ReceiptScanResult(
      items: items,
      printedTotal: printedTotal ?? subtotalCandidate,
      rawText: rawText,
    );
  }

  /// `TOTAL`, `GRAND TOTAL`, `JUMLAH` - but not an item that merely mentions
  /// a total-ish word mid-sentence.
  static bool _looksLikeTotal(String lower) =>
      lower.contains('total') || lower.startsWith('jumlah');

  static bool _isCharge(String lower) => _chargeWordPattern.hasMatch(lower);

  static bool _isNoise(String lower) =>
      _noiseSubstrings.any((word) => lower.contains(word)) ||
      _noiseWordPattern.hasMatch(lower);

  /// A name must contain letters and not be a single stray character.
  static bool _looksLikeName(String name) =>
      name.length >= 3 && RegExp(r'[a-zA-Z]{2,}').hasMatch(name);

  static double? _lastAmountIn(String line) {
    double? last;
    for (final part in line.split(_whitespace)) {
      final value = _parseMoney(part);
      if (value != null) last = value;
    }
    return last;
  }

  static String _cleanName(String line) {
    final withoutQty = line.replaceFirst(_leadingQty, '');
    final kept = withoutQty
        .split(_whitespace)
        .where((part) => part.isNotEmpty)
        .where((part) => !_currencyWords.contains(part.toLowerCase()))
        .where((part) => _parseMoney(part) == null)
        .join(' ');
    return kept.replaceAll(RegExp(r'^[\-–—:.\s]+|[\-–—:.\s]+$'), '').trim();
  }

  /// Splits one line into `name` + trailing numeric column(s).
  ///
  /// Returns `null` when the line holds no money-looking token at all.
  static ScannedItem? _parseLine(String line) {
    var working = line;
    double? leadingQuantity;
    final qtyMatch = _leadingQty.firstMatch(working);
    if (qtyMatch != null) {
      leadingQuantity = double.tryParse(qtyMatch.group(1)!);
      working = working.substring(qtyMatch.end);
    }

    final parts = working
        .split(_whitespace)
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;

    // Walk backwards collecting the trailing run of numeric columns.
    final tail = <_MoneyPart>[];
    var index = parts.length - 1;
    while (index >= 0) {
      final part = parts[index];
      if (_currencyWords.contains(part.toLowerCase())) {
        index--;
        continue;
      }
      final value = _parseMoney(part);
      if (value == null) break;
      tail.insert(0, _MoneyPart(raw: part, value: value));
      index--;
    }
    if (tail.isEmpty) return null;

    final nameParts = parts
        .sublist(0, index + 1)
        .where((part) => !_currencyWords.contains(part.toLowerCase()));
    final name = _cleanName(nameParts.join(' '));

    var quantity = leadingQuantity ?? 1;
    double unitPrice;
    double amount;

    if (tail.length >= 3 && _isQuantityToken(tail[tail.length - 3])) {
      quantity = tail[tail.length - 3].value;
      unitPrice = tail[tail.length - 2].value;
      amount = tail.last.value;
    } else if (tail.length >= 2 && _isQuantityToken(tail[tail.length - 2])) {
      quantity = tail[tail.length - 2].value;
      unitPrice = tail.last.value;
      amount = quantity * unitPrice;
    } else if (tail.length >= 2) {
      unitPrice = tail[tail.length - 2].value;
      amount = tail.last.value;
    } else {
      // Single figure: it is the line total. With a leading "2 x" the unit
      // price is derived from it ("2 x Nasi Goreng 30.000" -> 15.000 each).
      amount = tail.last.value;
      unitPrice = (leadingQuantity != null && leadingQuantity > 0)
          ? amount / leadingQuantity
          : amount;
    }

    if (quantity <= 0) quantity = 1;
    if (unitPrice <= 0) unitPrice = amount / quantity;

    return ScannedItem(
      name: name,
      quantity: quantity,
      unitPrice: unitPrice,
      amount: amount,
      sourceLine: line,
    );
  }

  /// A bare small integer (`2`, `12`) in a numeric column is a quantity, not a
  /// price. Anything with a thousands separator is money.
  static bool _isQuantityToken(_MoneyPart part) {
    if (part.raw.contains('.') || part.raw.contains(',')) return false;
    if (part.value != part.value.roundToDouble()) return false;
    return part.value >= 1 && part.value <= 99;
  }

  /// Reads an Indonesian- or English-formatted money token.
  ///
  /// `32.000` -> 32000, `15,000` -> 15000, `7.000,00` -> 7000,
  /// `1,234.56` -> 1234.56, `12,50` -> 12.5.
  static double? _parseMoney(String token) {
    final match = _moneyToken.firstMatch(token);
    if (match == null) return null;
    var digits = match.group(1)!;
    // Trailing separators are OCR noise ("32.000." at end of line).
    digits = digits.replaceAll(RegExp(r'[.,]+$'), '');
    if (digits.isEmpty) return null;

    final hasDot = digits.contains('.');
    final hasComma = digits.contains(',');

    if (hasDot && hasComma) {
      final decimalIsComma = digits.lastIndexOf(',') > digits.lastIndexOf('.');
      digits = decimalIsComma
          ? digits.replaceAll('.', '').replaceAll(',', '.')
          : digits.replaceAll(',', '');
    } else if (hasDot || hasComma) {
      final separator = hasDot ? '.' : ',';
      final groups = digits.split(separator);
      final isThousandGrouped =
          groups.skip(1).every((group) => group.length == 3);
      digits = isThousandGrouped
          ? groups.join()
          : '${groups.sublist(0, groups.length - 1).join()}.${groups.last}';
    }

    return double.tryParse(digits);
  }
}

class _MoneyPart {
  final String raw;
  final double value;
  const _MoneyPart({required this.raw, required this.value});
}
