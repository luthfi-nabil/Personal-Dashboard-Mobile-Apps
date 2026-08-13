import 'package:flutter_test/flutter_test.dart';
import 'package:personal_dashboard/core/receipt_parser.dart';

void main() {
  group('money token parsing', () {
    test('reads Indonesian dot-grouped thousands', () {
      final result = ReceiptParser.parse('Gula Pasir 1kg 19.000');
      expect(result.items, hasLength(1));
      expect(result.items.single.name, 'Gula Pasir 1kg');
      expect(result.items.single.amount, 19000);
    });

    test('reads comma-grouped thousands', () {
      final result = ReceiptParser.parse('Kopi Kapal Api 15,000');
      expect(result.items.single.amount, 15000);
    });

    test('reads a rupiah decimal tail', () {
      final result = ReceiptParser.parse('Roti Tawar 7.000,00');
      expect(result.items.single.amount, 7000);
    });

    test('reads an English decimal', () {
      final result = ReceiptParser.parse('Imported Cheese 1,234.56');
      expect(result.items.single.amount, closeTo(1234.56, 0.001));
    });

    test('ignores an Rp prefix glued to the number', () {
      final result = ReceiptParser.parse('Teh Kotak Rp3.500');
      expect(result.items.single.amount, 3500);
      expect(result.items.single.name, 'Teh Kotak');
    });
  });

  group('quantity columns', () {
    test('qty / unit price / total', () {
      final result = ReceiptParser.parse('INDOMIE GORENG 2 3.500 7.000');
      final item = result.items.single;
      expect(item.name, 'INDOMIE GORENG');
      expect(item.quantity, 2);
      expect(item.unitPrice, 3500);
      expect(item.amount, 7000);
    });

    test('qty then unit price only, total derived', () {
      final result = ReceiptParser.parse('Kopi Susu 2 18.000');
      final item = result.items.single;
      expect(item.quantity, 2);
      expect(item.unitPrice, 18000);
      expect(item.amount, 36000);
    });

    test('unit price and total without a qty column', () {
      final result = ReceiptParser.parse('Nasi Goreng 15.000 30.000');
      final item = result.items.single;
      expect(item.quantity, 1);
      expect(item.unitPrice, 15000);
      expect(item.amount, 30000);
    });

    test('leading "2 x" prefix splits the printed line total', () {
      final result = ReceiptParser.parse('2 x Nasi Goreng 30.000');
      final item = result.items.single;
      expect(item.name, 'Nasi Goreng');
      expect(item.quantity, 2);
      expect(item.unitPrice, 15000);
      expect(item.amount, 30000);
    });

    test('a number glued to a unit stays in the name', () {
      final result = ReceiptParser.parse('TELUR AYAM 1KG 32.000');
      final item = result.items.single;
      expect(item.name, 'TELUR AYAM 1KG');
      expect(item.quantity, 1);
      expect(item.amount, 32000);
    });
  });

  group('noise filtering', () {
    test('drops totals, payment and change lines but keeps the tax', () {
      const receipt = '''
INDOMARET PASKAL
Jl. Pasirkaliki No. 25
Kasir: 02  Tanggal: 27/07/2026

Aqua 600ml            4.500
Chitato Sapi         12.000

SUBTOTAL             16.500
PPN 11%               1.815
TOTAL                18.315
TUNAI                20.000
KEMBALIAN             1.685

TERIMA KASIH
''';
      final result = ReceiptParser.parse(receipt);
      expect(result.items.map((i) => i.name),
          containsAll(<String>['Aqua 600ml', 'Chitato Sapi', 'PPN 11%']));
      expect(result.items, hasLength(3));
      expect(result.printedTotal, 18315);
      // Tax counts as a line item, so the breakdown adds up to what was paid.
      expect(result.itemsTotal, 18315);
    });

    test('skips figures below the minimum price', () {
      final result = ReceiptParser.parse('Meja 4\nPlastik 500');
      expect(result.items.map((i) => i.name), ['Plastik']);
    });

    test('honours a custom minAmount', () {
      final result = ReceiptParser.parse('Permen 200', minAmount: 1000);
      expect(result.items, isEmpty);
    });
  });

  group('tax and service charges', () {
    test('imports a service charge as a flagged line item', () {
      const receipt = '''
Nasi Goreng          32.000
Es Teh Manis          8.000
Service Charge 5%     2.000
PB1 10%               4.200
''';
      final result = ReceiptParser.parse(receipt);
      expect(result.items, hasLength(4));

      final charges = result.items.where((i) => i.isCharge).toList();
      expect(charges.map((i) => i.name),
          <String>['Service Charge 5%', 'PB1 10%']);
      // A charge is billed once for the whole bill, never per unit.
      expect(charges.every((i) => i.quantity == 1), isTrue);
      expect(charges.first.amount, 2000);
      expect(charges.last.amount, 4200);
      expect(result.itemsTotal, 46200);
    });

    test('leaves products whose name merely contains a charge word alone', () {
      final result = ReceiptParser.parse('Taxi ke kantor  45.000');
      expect(result.items, hasLength(1));
      expect(result.items.single.isCharge, isFalse);
      expect(result.items.single.name, 'Taxi ke kantor');
    });

    test('still drops the tax base and the total', () {
      const receipt = '''
Kopi Susu            25.000
DPP                  22.523
PPN                   2.477
TOTAL                25.000
''';
      final result = ReceiptParser.parse(receipt);
      expect(result.items.map((i) => i.name), <String>['Kopi Susu', 'PPN']);
      expect(result.items.last.isCharge, isTrue);
    });
  });

  group('column splitting across OCR lines', () {
    test('pairs a name with the price on the next line', () {
      const receipt = '''
Susu UHT Coklat
18.500
Sereal Coco
24.000
''';
      final result = ReceiptParser.parse(receipt);
      expect(result.items, hasLength(2));
      expect(result.items.first.name, 'Susu UHT Coklat');
      expect(result.items.first.amount, 18500);
      expect(result.items.last.name, 'Sereal Coco');
      expect(result.items.last.amount, 24000);
    });

    test('a price with no name above it is dropped', () {
      final result = ReceiptParser.parse('12.000');
      expect(result.items, isEmpty);
    });
  });

  group('edge cases', () {
    test('empty input yields no items', () {
      final result = ReceiptParser.parse('');
      expect(result.items, isEmpty);
      expect(result.printedTotal, isNull);
    });

    test('falls back to the subtotal when no total is printed', () {
      final result = ReceiptParser.parse('Kue 20.000\nSUB TOTAL 20.000');
      expect(result.printedTotal, 20000);
    });

    test('keeps the raw text for the debug panel', () {
      const raw = 'Kue 20.000';
      expect(ReceiptParser.parse(raw).rawText, raw);
    });
  });
}
