import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_dashboard/core/ocr_layout.dart';
import 'package:personal_dashboard/core/receipt_parser.dart';

/// Helper mirroring an ML Kit `TextLine`: text plus an axis-aligned box.
OcrFragment frag(String text, double left, double top,
        {double width = 160, double height = 26}) =>
    OcrFragment(text: text, box: Rect.fromLTWH(left, top, width, height));

void main() {
  group('row grouping', () {
    test('merges two ML Kit column blocks into visual rows', () {
      // Exactly what ML Kit hands back for a two-column receipt: the name
      // column as one block, the price column as another.
      final fragments = [
        // Names block
        frag('Indomie Goreng', 40, 100),
        frag('Telur 1kg', 40, 140),
        frag('Aqua 600ml', 40, 180),
        // Prices block, right-aligned, same vertical positions
        frag('7.000', 420, 101, width: 80),
        frag('32.000', 420, 141, width: 80),
        frag('4.500', 420, 181, width: 80),
      ];

      expect(OcrLayout.toRows(fragments), [
        'Indomie Goreng 7.000',
        'Telur 1kg 32.000',
        'Aqua 600ml 4.500',
      ]);
    });

    test('orders fragments within a row left to right, not by input order', () {
      final fragments = [
        frag('9.000', 500, 100, width: 70),
        frag('2', 300, 100, width: 20),
        frag('Kopi', 40, 100),
        frag('4.500', 400, 100, width: 70),
      ];
      expect(OcrLayout.toRows(fragments).single, 'Kopi 2 4.500 9.000');
    });

    test('tolerates baseline drift across a skewed photo', () {
      // Left column sits a few pixels higher than the right on each row.
      final fragments = [
        frag('Nasi Goreng', 40, 100),
        frag('25.000', 420, 108, width: 80),
        frag('Es Teh', 40, 140),
        frag('8.000', 420, 149, width: 80),
      ];
      expect(OcrLayout.toRows(fragments),
          ['Nasi Goreng 25.000', 'Es Teh 8.000']);
    });

    test('keeps genuinely separate lines apart', () {
      final fragments = [
        frag('Item A', 40, 100),
        frag('Item B', 40, 140),
        frag('Item C', 40, 180),
      ];
      expect(OcrLayout.toRows(fragments), ['Item A', 'Item B', 'Item C']);
    });

    test('handles a line that already spans the whole row', () {
      final fragments = [
        frag('Gula Pasir 1kg      19.000', 40, 100, width: 460),
      ];
      expect(OcrLayout.toRows(fragments).single, 'Gula Pasir 1kg      19.000');
    });

    test('sorts rows top to bottom regardless of input order', () {
      final fragments = [
        frag('Third', 40, 180),
        frag('First', 40, 100),
        frag('Second', 40, 140),
      ];
      expect(OcrLayout.toRows(fragments), ['First', 'Second', 'Third']);
    });

    test('ignores blank and zero-height fragments', () {
      final fragments = [
        frag('   ', 40, 100),
        frag('Real Item', 40, 140),
        OcrFragment(text: 'Flat', box: Rect.fromLTWH(40, 180, 100, 0)),
      ];
      expect(OcrLayout.toRows(fragments), ['Real Item']);
    });

    test('empty input yields no rows', () {
      expect(OcrLayout.toRows(const []), isEmpty);
      expect(OcrLayout.toRowMajorText(const []), '');
    });

    test('toRowMajorText joins rows with newlines', () {
      final fragments = [
        frag('A', 40, 100),
        frag('1.000', 420, 100, width: 70),
        frag('B', 40, 140),
        frag('2.000', 420, 140, width: 70),
      ];
      expect(OcrLayout.toRowMajorText(fragments), 'A 1.000\nB 2.000');
    });
  });

  group('end to end: column-major OCR through the parser', () {
    test('produces correctly paired items', () {
      final fragments = [
        // Header block
        frag('INDOMARET PASKAL', 40, 40, width: 300),
        // Name column
        frag('Aqua 600ml', 40, 120),
        frag('Chitato Sapi', 40, 160),
        frag('Telur Ayam 1KG', 40, 200),
        // Price column
        frag('4.500', 420, 121, width: 80),
        frag('12.000', 420, 161, width: 80),
        frag('32.000', 420, 201, width: 80),
        // Totals block
        frag('TOTAL', 40, 260, width: 90),
        frag('48.500', 420, 261, width: 80),
      ];

      final result =
          ReceiptParser.parse(OcrLayout.toRowMajorText(fragments));

      expect(
        result.items.map((i) => (i.name, i.amount)),
        [
          ('Aqua 600ml', 4500.0),
          ('Chitato Sapi', 12000.0),
          ('Telur Ayam 1KG', 32000.0),
        ],
      );
      expect(result.printedTotal, 48500);
      expect(result.itemsTotal, 48500);
    });

    test('qty and unit-price columns survive the regrouping', () {
      final fragments = [
        frag('Kopi Susu', 40, 100),
        frag('2', 300, 100, width: 20),
        frag('18.000', 360, 100, width: 80),
        frag('36.000', 460, 100, width: 80),
      ];

      final item =
          ReceiptParser.parse(OcrLayout.toRowMajorText(fragments)).items.single;
      expect(item.name, 'Kopi Susu');
      expect(item.quantity, 2);
      expect(item.unitPrice, 18000);
      expect(item.amount, 36000);
    });

    test('minimarket layout with the price line under the name still pairs', () {
      // Alfamart/Indomaret style: name on one row, "2 x 3.500  7.000" beneath.
      final fragments = [
        frag('INDOMIE GORENG', 40, 100),
        frag('2 x 3.500', 60, 136, width: 120),
        frag('7.000', 420, 136, width: 80),
      ];

      final item =
          ReceiptParser.parse(OcrLayout.toRowMajorText(fragments)).items.single;
      expect(item.name, 'INDOMIE GORENG');
      expect(item.quantity, 2);
      expect(item.unitPrice, 3500);
      expect(item.amount, 7000);
    });
  });
}
