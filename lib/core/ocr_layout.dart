/// Reassembles OCR output into reading order (left to right, row by row).
///
/// Why this exists: ML Kit returns text grouped into *blocks*, and on a receipt
/// the item names are usually one block and the prices another. Reading
/// `RecognizedText.text` therefore gives every name top-to-bottom, then every
/// price top-to-bottom — column-major — so names and prices never line up:
///
/// ```text
/// Indomie Goreng      ← block 1
/// Telur 1kg
/// Aqua 600ml
/// 7.000               ← block 2
/// 32.000
/// 4.500
/// ```
///
/// [OcrLayout.toRowMajorText] uses each fragment's bounding box to rebuild the
/// visual rows instead, which is what the receipt actually says:
///
/// ```text
/// Indomie Goreng 7.000
/// Telur 1kg 32.000
/// Aqua 600ml 4.500
/// ```
///
/// This file has no plugin imports so the grouping is unit-testable; the ML Kit
/// types are mapped to [OcrFragment] in `receipt_scanner.dart`.
library;

import 'dart:ui' show Rect;

/// A recognised piece of text plus where it sat on the page.
class OcrFragment {
  final String text;
  final Rect box;

  const OcrFragment({required this.text, required this.box});

  double get centerY => box.center.dy;
  double get height => box.height;

  @override
  String toString() => 'OcrFragment("$text", $box)';
}

class OcrLayout {
  const OcrLayout._();

  /// Fragments whose vertical centres differ by more than this fraction of the
  /// taller fragment's height are treated as different rows. 0.6 tolerates the
  /// baseline drift of hand-held photos and slightly curled thermal paper
  /// without merging genuinely adjacent lines.
  static const defaultRowTolerance = 0.6;

  /// Groups [fragments] into visual rows and returns each row as one line of
  /// text, fragments ordered left to right.
  static List<String> toRows(
    List<OcrFragment> fragments, {
    double rowTolerance = defaultRowTolerance,
  }) {
    final usable = fragments
        .where((f) => f.text.trim().isNotEmpty && f.height > 0)
        .toList();
    if (usable.isEmpty) return const [];

    // Top to bottom, so rows are discovered in reading order.
    usable.sort((a, b) => a.centerY.compareTo(b.centerY));

    final rows = <_Row>[];
    for (final fragment in usable) {
      _Row? target;
      // Search newest rows first: with fragments arriving top-to-bottom the
      // match is nearly always the last row, and stopping early keeps a skewed
      // page from dragging far-apart lines together.
      for (var i = rows.length - 1; i >= 0; i--) {
        final row = rows[i];
        if (row.accepts(fragment, rowTolerance)) {
          target = row;
          break;
        }
        if (row.centerY < fragment.centerY - 3 * fragment.height) break;
      }
      if (target != null) {
        target.add(fragment);
      } else {
        rows.add(_Row(fragment));
      }
    }

    rows.sort((a, b) => a.centerY.compareTo(b.centerY));
    return rows.map((row) => row.text).toList();
  }

  /// [toRows] joined with newlines, ready for `ReceiptParser.parse`.
  static String toRowMajorText(
    List<OcrFragment> fragments, {
    double rowTolerance = defaultRowTolerance,
  }) =>
      toRows(fragments, rowTolerance: rowTolerance).join('\n');
}

/// A row under construction. Tracks running averages rather than a union box:
/// the average centre follows a gradually skewed line, while a union box would
/// keep growing and start swallowing neighbouring rows.
class _Row {
  final List<OcrFragment> _fragments = [];
  double _centerSum = 0;
  double _heightSum = 0;

  _Row(OcrFragment first) {
    add(first);
  }

  void add(OcrFragment fragment) {
    _fragments.add(fragment);
    _centerSum += fragment.centerY;
    _heightSum += fragment.height;
  }

  double get centerY => _centerSum / _fragments.length;
  double get height => _heightSum / _fragments.length;

  bool accepts(OcrFragment fragment, double tolerance) {
    final reference =
        fragment.height > height ? fragment.height : height;
    return (fragment.centerY - centerY).abs() <= tolerance * reference;
  }

  String get text {
    final ordered = [..._fragments]
      ..sort((a, b) => a.box.left.compareTo(b.box.left));
    return ordered
        .map((f) => f.text.trim())
        .where((t) => t.isNotEmpty)
        .join(' ');
  }
}
