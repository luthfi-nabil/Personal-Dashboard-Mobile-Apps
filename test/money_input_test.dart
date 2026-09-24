import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:personal_dashboard/core/money_input.dart';
import 'package:personal_dashboard/core/proof_service.dart';

/// Types [text] into an empty field with the cursor at the end.
TextEditingValue type(String text, {MoneyInputFormatter? formatter}) =>
    (formatter ?? const MoneyInputFormatter()).formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(
          text: text, selection: TextSelection.collapsed(offset: text.length)),
    );

void main() {
  group('money input', () {
    test('groups thousands with dots as it is typed', () {
      expect(type('1').text, '1');
      expect(type('1500').text, '1.500');
      expect(type('1500000').text, '1.500.000');
      expect(type('1500000').selection.baseOffset, '1.500.000'.length);
    });

    test('a typed dot is only grouping; the comma starts decimals', () {
      expect(type('1.5').text, '15');
      expect(type('1500,5').text, '1.500,5');
      expect(type('1500,567').text, '1.500,56');
      expect(type('1,2,3').text, '1,23');
      expect(type(',5').text, '0,5');
      expect(type('007').text, '7');
      expect(type('Rp 12a3').text, '123');
    });

    test('decimals can be turned off or widened', () {
      expect(type('12,5', formatter: const MoneyInputFormatter(decimals: 0)).text,
          '125');
      expect(
          type('1234,5678', formatter: const MoneyInputFormatter(decimals: 4))
              .text,
          '1.234,5678');
    });

    test('the cursor stays after the same digit when regrouping', () {
      // "1.500" with the cursor after the 1, then a 2 typed there.
      final result = const MoneyInputFormatter().formatEditUpdate(
        const TextEditingValue(
            text: '1.500', selection: TextSelection.collapsed(offset: 1)),
        const TextEditingValue(
            text: '12.500', selection: TextSelection.collapsed(offset: 2)),
      );
      expect(result.text, '12.500');
      expect(result.selection.baseOffset, 2);
    });

    test('parse and format round-trip', () {
      expect(parseMoney('1.500.000'), 1500000);
      expect(parseMoney('1.500,50'), 1500.5);
      expect(parseMoney(''), isNull);
      expect(formatMoneyInput(1500000), '1.500.000');
      expect(formatMoneyInput(12.5), '12,5');
      expect(formatMoneyInput(0), '0');
      expect(formatMoneyInput(0, emptyForZero: true), '');
      expect(formatMoneyInput(1234.5678, decimals: 4), '1.234,5678');
      expect(parseMoney(formatMoneyInput(987654.32)), 987654.32);
    });
  });

  group('proof compression', () {
    test('scales a large picture down and re-encodes it as JPEG', () {
      final big = img.Image(width: 4000, height: 3000);
      img.fill(big, color: img.ColorRgb8(200, 120, 40));
      final png = img.encodePng(big);

      final out = compressProofImage(png);
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, proofMaxSide);
      expect(decoded.height, 1200);
      expect(out.length, lessThanOrEqualTo(proofTargetBytes));
    });

    test('keeps a small picture its size and portrait stays portrait', () {
      final small = img.Image(width: 300, height: 800);
      final out = compressProofImage(img.encodePng(small));
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 300);
      expect(decoded.height, 800);
    });

    test('refuses something that is not an image', () {
      expect(() => compressProofImage(Uint8List.fromList([1, 2, 3, 4])),
          throwsFormatException);
    });
  });
}
