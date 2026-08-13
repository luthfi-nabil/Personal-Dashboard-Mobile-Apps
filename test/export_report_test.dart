import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_dashboard/core/export_docx.dart';
import 'package:personal_dashboard/core/export_report.dart';
import 'package:personal_dashboard/core/export_xlsx.dart';
import 'package:personal_dashboard/core/models.dart';

Transaction txn({
  required String id,
  required String type,
  required double amount,
  required String date,
  String? category,
  String? source,
  String? fromSource,
  String? toSource,
  String description = '',
}) =>
    Transaction(
      id: id,
      type: type,
      amount: amount,
      description: description,
      category: category,
      source: source,
      fromSource: fromSource,
      toSource: toSource,
      date: date,
      syncState: 'synced',
      updatedAt: date,
    );

AppData sampleData() => AppData(
      sources: const [
        Source(id: 's1', name: 'BCA Debit', kind: 'bank', updatedAt: ''),
        Source(id: 's2', name: 'Cash', kind: 'cash', updatedAt: ''),
      ],
      categories: const [],
      transactions: [
        txn(
            id: '1',
            type: 'earning',
            amount: 5000000,
            date: '2026-06-01T09:00',
            category: 'Salary',
            source: 'BCA Debit',
            description: 'June salary'),
        txn(
            id: '2',
            type: 'spending',
            amount: 150000,
            date: '2026-06-02T12:30',
            category: 'Food',
            source: 'Cash',
            description: 'Kopi & roti <warung>'),
        txn(
            id: '3',
            type: 'transfer',
            amount: 200000,
            date: '2026-06-03T08:00',
            fromSource: 'BCA Debit',
            toSource: 'Cash',
            description: 'topup'),
        txn(
            id: '4',
            type: 'spending',
            amount: 80000,
            date: '2026-07-05T08:00',
            category: 'Transport',
            source: 'Cash',
            description: 'Bensin'),
        // Outside the exported range.
        txn(
            id: '5',
            type: 'spending',
            amount: 999000,
            date: '2026-05-05T08:00',
            category: 'Food',
            source: 'Cash'),
      ],
    );

/// Reads a file out of an OOXML package.
String partOf(List<int> bytes, String path) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final file = archive.files.firstWhere((f) => f.name == path,
      orElse: () => throw StateError('missing part: $path'));
  return utf8.decode(file.content as List<int>);
}

void main() {
  group('ExportReport.build', () {
    final report = ExportReport.build(sampleData(), ['2026-07', '2026-06']);

    test('sorts months and labels the range', () {
      expect(report.months, ['2026-06', '2026-07']);
      expect(report.rangeLabel, 'Jun 2026 – Jul 2026');
      expect(report.fileStem, 'finance-recap_2026-06_2026-07');
    });

    test('excludes transfers from earned/spent but counts them', () {
      final june = report.summaries.first;
      expect(june.earn, 5000000);
      expect(june.spend, 150000);
      expect(june.net, 4850000);
      expect(june.transferCount, 1);
    });

    test('totals only cover the selected months', () {
      expect(report.totalEarn, 5000000);
      expect(report.totalSpend, 230000); // 150k June + 80k July, not May's 999k
      expect(report.totalNet, 4770000);
      expect(report.transactions.length, 4);
    });

    test('category shares are relative to the month and type', () {
      final food = report.categoriesFor('2026-06', 'spending').single;
      expect(food.category, 'Food');
      expect(food.count, 1);
      expect(food.share, 1.0);
    });

    test('source balances span all history, including the May spending', () {
      final cash = report.sources.firstWhere((s) => s.name == 'Cash');
      // +200k transfer in, −150k food, −80k bensin, −999k May food.
      expect(cash.balance, -1029000);
      expect(report.liquid, 3771000);
    });

    test('availableMonths lists every month with data, newest first', () {
      final months = ExportReport.availableMonths(sampleData());
      expect(months.take(3), ['2026-07', '2026-06', '2026-05']);
    });
  });

  group('xlsx package', () {
    final bytes = buildFinanceXlsx(
        ExportReport.build(sampleData(), ['2026-06', '2026-07']));

    test('is a zip with the expected parts', () {
      expect(bytes.sublist(0, 2), [0x50, 0x4b]); // 'PK'
      final names = ZipDecoder().decodeBytes(bytes).files.map((f) => f.name);
      expect(
          names,
          containsAll([
            '[Content_Types].xml',
            'xl/workbook.xml',
            'xl/styles.xml',
            'xl/worksheets/sheet1.xml',
            'xl/worksheets/sheet4.xml',
          ]));
    });

    test('names the four sheets', () {
      final workbook = partOf(bytes, 'xl/workbook.xml');
      for (final name in ['Summary', 'By Category', 'Transactions', 'Sources']) {
        expect(workbook, contains('name="$name"'));
      }
    });

    test('writes amounts as numbers and escapes text', () {
      final sheet1 = partOf(bytes, 'xl/worksheets/sheet1.xml');
      expect(sheet1, contains('<v>5000000</v>'));
      final sheet3 = partOf(bytes, 'xl/worksheets/sheet3.xml');
      expect(sheet3, contains('Kopi &amp; roti &lt;warung&gt;'));
      expect(sheet3, contains('<v>-150000</v>')); // signed amount
    });
  });

  group('docx package', () {
    final bytes = buildFinanceDocx(
        ExportReport.build(sampleData(), ['2026-06', '2026-07']), 'full');

    test('is a zip with a document part', () {
      expect(bytes.sublist(0, 2), [0x50, 0x4b]);
      final names = ZipDecoder().decodeBytes(bytes).files.map((f) => f.name);
      expect(names, containsAll(['word/document.xml', 'word/styles.xml']));
    });

    test('contains the recap headings and formatted currency', () {
      final doc = partOf(bytes, 'word/document.xml');
      expect(doc, contains('Finance Recap'));
      expect(doc, contains('Monthly recap'));
      expect(doc, contains('Jun 2026'));
      expect(doc, contains('Rp 5.000.000'));
      expect(doc, contains('Source balances'));
    });
  });
}
