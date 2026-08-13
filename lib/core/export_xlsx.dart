import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'export_report.dart';
import 'utils.dart';

/// Minimal SpreadsheetML (.xlsx) writer.
///
/// Only what this app needs: inline strings, numbers, a bold header row with a
/// frozen pane + autofilter, and a thousands number format. No external
/// spreadsheet package, so nothing here can break on a Flutter upgrade.

/// Style indexes into `cellXfs` in [_stylesXml].
const int _sText = 0;
const int _sHeader = 1;
const int _sNumber = 2;
const int _sNumberBold = 3;
const int _sTextBold = 4;
const int _sPercent = 5;

class XlsxCell {
  /// Inline string value, or null for a numeric / empty cell. Named
  /// `textValue` (not `text`) so it does not clash with the `XlsxCell.text`
  /// constructor — Dart forbids a named constructor matching a member name.
  final String? textValue;
  final num? numberValue;
  final int style;

  const XlsxCell._(this.textValue, this.numberValue, this.style);

  const XlsxCell.text(String value) : this._(value, null, _sText);
  const XlsxCell.bold(String value) : this._(value, null, _sTextBold);
  const XlsxCell.header(String value) : this._(value, null, _sHeader);
  const XlsxCell.number(num value) : this._(null, value, _sNumber);
  const XlsxCell.numberBold(num value) : this._(null, value, _sNumberBold);
  const XlsxCell.percent(num value) : this._(null, value, _sPercent);
  const XlsxCell.empty() : this._(null, null, _sText);
}

class XlsxSheet {
  final String name;
  final List<double> columnWidths;
  final List<List<XlsxCell>> rows;

  /// Freeze the first row and add an autofilter over the header.
  final bool headerRow;

  XlsxSheet({
    required this.name,
    required this.rows,
    this.columnWidths = const [],
    this.headerRow = true,
  });
}

/// Builds the four-sheet workbook: Summary, Categories, Transactions, Sources.
Uint8List buildFinanceXlsx(ExportReport r) {
  return buildXlsx([
    _summarySheet(r),
    _categorySheet(r),
    _transactionSheet(r),
    _sourceSheet(r),
  ]);
}

XlsxSheet _summarySheet(ExportReport r) {
  final rows = <List<XlsxCell>>[
    const [
      XlsxCell.header('Month'),
      XlsxCell.header('Earned'),
      XlsxCell.header('Spent'),
      XlsxCell.header('Net'),
      XlsxCell.header('Earning txns'),
      XlsxCell.header('Spending txns'),
      XlsxCell.header('Transfers'),
    ],
  ];
  for (final m in r.summaries) {
    rows.add([
      XlsxCell.text(m.label),
      XlsxCell.number(m.earn),
      XlsxCell.number(m.spend),
      XlsxCell.number(m.net),
      XlsxCell.number(m.earnCount),
      XlsxCell.number(m.spendCount),
      XlsxCell.number(m.transferCount),
    ]);
  }
  rows.add([
    const XlsxCell.bold('Total'),
    XlsxCell.numberBold(r.totalEarn),
    XlsxCell.numberBold(r.totalSpend),
    XlsxCell.numberBold(r.totalNet),
    XlsxCell.numberBold(r.summaries.fold<int>(0, (s, m) => s + m.earnCount)),
    XlsxCell.numberBold(r.summaries.fold<int>(0, (s, m) => s + m.spendCount)),
    XlsxCell.numberBold(r.summaries.fold<int>(0, (s, m) => s + m.transferCount)),
  ]);
  rows.add([
    const XlsxCell.bold('Average / month'),
    XlsxCell.numberBold(r.avgEarn),
    XlsxCell.numberBold(r.avgSpend),
    XlsxCell.numberBold(r.summaries.isEmpty ? 0 : r.totalNet / r.summaries.length),
  ]);
  return XlsxSheet(
    name: 'Summary',
    rows: rows,
    columnWidths: const [16, 16, 16, 16, 13, 14, 11],
  );
}

XlsxSheet _categorySheet(ExportReport r) {
  final rows = <List<XlsxCell>>[
    const [
      XlsxCell.header('Month'),
      XlsxCell.header('Type'),
      XlsxCell.header('Category'),
      XlsxCell.header('Transactions'),
      XlsxCell.header('Amount'),
      XlsxCell.header('Share of month'),
    ],
  ];
  for (final m in r.summaries) {
    for (final type in const ['spending', 'earning']) {
      for (final c in r.categoriesFor(m.ym, type)) {
        rows.add([
          XlsxCell.text(m.label),
          XlsxCell.text(type),
          XlsxCell.text(c.category),
          XlsxCell.number(c.count),
          XlsxCell.number(c.amount),
          XlsxCell.percent(c.share),
        ]);
      }
    }
  }
  return XlsxSheet(
    name: 'By Category',
    rows: rows,
    columnWidths: const [16, 11, 26, 13, 16, 15],
  );
}

XlsxSheet _transactionSheet(ExportReport r) {
  final rows = <List<XlsxCell>>[
    const [
      XlsxCell.header('Date'),
      XlsxCell.header('Time'),
      XlsxCell.header('Type'),
      XlsxCell.header('Category'),
      XlsxCell.header('Source'),
      XlsxCell.header('From'),
      XlsxCell.header('To'),
      XlsxCell.header('Description'),
      XlsxCell.header('Amount'),
      XlsxCell.header('Signed amount'),
      XlsxCell.header('Sync'),
    ],
  ];
  for (final t in r.transactions) {
    final signed = switch (t.type) {
      'earning' => t.amount,
      'spending' => -t.amount,
      _ => 0.0,
    };
    rows.add([
      XlsxCell.text(isoDay(t.date)),
      XlsxCell.text(fmtDate(t.date, 'time')),
      XlsxCell.text(t.type),
      XlsxCell.text(t.category ?? ''),
      XlsxCell.text(t.source ?? ''),
      XlsxCell.text(t.fromSource ?? ''),
      XlsxCell.text(t.toSource ?? ''),
      XlsxCell.text(t.description),
      XlsxCell.number(t.amount),
      XlsxCell.number(signed),
      XlsxCell.text(t.syncState),
    ]);
  }
  return XlsxSheet(
    name: 'Transactions',
    rows: rows,
    columnWidths: const [12, 8, 11, 22, 16, 16, 16, 34, 16, 16, 10],
  );
}

XlsxSheet _sourceSheet(ExportReport r) {
  final rows = <List<XlsxCell>>[
    const [
      XlsxCell.header('Source'),
      XlsxCell.header('Kind'),
      XlsxCell.header('Balance'),
    ],
  ];
  for (final s in r.sources) {
    rows.add([
      XlsxCell.text(s.name),
      XlsxCell.text(s.kind),
      XlsxCell.number(s.balance),
    ]);
  }
  rows.add([
    const XlsxCell.bold('Liquid'),
    const XlsxCell.empty(),
    XlsxCell.numberBold(r.liquid),
  ]);
  return XlsxSheet(
    name: 'Sources',
    rows: rows,
    columnWidths: const [26, 14, 18],
  );
}

// ── OOXML plumbing ─────────────────────────────────────────────────────────

Uint8List buildXlsx(List<XlsxSheet> sheets) {
  final archive = Archive();

  void add(String path, String xml) {
    final bytes = utf8.encode(xml);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('[Content_Types].xml', _contentTypesXml(sheets.length));
  add('_rels/.rels', _rootRelsXml);
  add('xl/workbook.xml', _workbookXml(sheets));
  add('xl/_rels/workbook.xml.rels', _workbookRelsXml(sheets.length));
  add('xl/styles.xml', _stylesXml);
  for (var i = 0; i < sheets.length; i++) {
    add('xl/worksheets/sheet${i + 1}.xml', _sheetXml(sheets[i]));
  }

  final zipped = ZipEncoder().encode(archive);
  return Uint8List.fromList(zipped!);
}

String _contentTypesXml(int sheetCount) {
  final sheets = List.generate(
    sheetCount,
    (i) => '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
  ).join();
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '$sheets</Types>';
}

const _rootRelsXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    '</Relationships>';

String _workbookXml(List<XlsxSheet> sheets) {
  final entries = <String>[];
  for (var i = 0; i < sheets.length; i++) {
    entries.add('<sheet name="${_attr(_sheetName(sheets[i].name))}" '
        'sheetId="${i + 1}" r:id="rId${i + 1}"/>');
  }
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>${entries.join()}</sheets></workbook>';
}

String _workbookRelsXml(int sheetCount) {
  final rels = List.generate(
    sheetCount,
    (i) => '<Relationship Id="rId${i + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
        'Target="worksheets/sheet${i + 1}.xml"/>',
  ).join();
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '$rels'
      '<Relationship Id="rId${sheetCount + 1}" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
      'Target="styles.xml"/>'
      '</Relationships>';
}

const _stylesXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="2">'
    '<numFmt numFmtId="164" formatCode="#,##0"/>'
    '<numFmt numFmtId="165" formatCode="0.0%"/>'
    '</numFmts>'
    '<fonts count="2">'
    '<font><sz val="11"/><name val="Calibri"/></font>'
    '<font><b/><sz val="11"/><name val="Calibri"/></font>'
    '</fonts>'
    '<fills count="3">'
    '<fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FFEFEBE0"/><bgColor indexed="64"/></patternFill></fill>'
    '</fills>'
    '<borders count="2">'
    '<border><left/><right/><top/><bottom/><diagonal/></border>'
    '<border><left/><right/><top/><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border>'
    '</borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="6">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>'
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '</cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>';

String _sheetXml(XlsxSheet sheet) {
  final buf = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');

  if (sheet.headerRow && sheet.rows.isNotEmpty) {
    buf.write('<sheetViews><sheetView workbookViewId="0">'
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
        '</sheetView></sheetViews>');
  }

  if (sheet.columnWidths.isNotEmpty) {
    buf.write('<cols>');
    for (var i = 0; i < sheet.columnWidths.length; i++) {
      buf.write('<col min="${i + 1}" max="${i + 1}" '
          'width="${sheet.columnWidths[i]}" customWidth="1"/>');
    }
    buf.write('</cols>');
  }

  buf.write('<sheetData>');
  for (var r = 0; r < sheet.rows.length; r++) {
    final row = sheet.rows[r];
    buf.write('<row r="${r + 1}">');
    for (var c = 0; c < row.length; c++) {
      final cell = row[c];
      final ref = '${_columnName(c)}${r + 1}';
      if (cell.numberValue != null) {
        buf.write('<c r="$ref" s="${cell.style}"><v>${_num(cell.numberValue!)}</v></c>');
      } else if (cell.textValue != null && cell.textValue!.isNotEmpty) {
        buf.write('<c r="$ref" s="${cell.style}" t="inlineStr"><is><t xml:space="preserve">'
            '${_esc(cell.textValue!)}</t></is></c>');
      } else {
        buf.write('<c r="$ref" s="${cell.style}"/>');
      }
    }
    buf.write('</row>');
  }
  buf.write('</sheetData>');

  if (sheet.headerRow && sheet.rows.length > 1) {
    final lastCol = _columnName(sheet.rows.first.length - 1);
    buf.write('<autoFilter ref="A1:$lastCol${sheet.rows.length}"/>');
  }

  buf.write('</worksheet>');
  return buf.toString();
}

String _columnName(int index) {
  var i = index;
  var name = '';
  while (i >= 0) {
    name = String.fromCharCode(65 + (i % 26)) + name;
    i = (i ~/ 26) - 1;
  }
  return name;
}

String _num(num v) {
  if (v is int) return v.toString();
  final d = v.toDouble();
  if (d == d.roundToDouble() && d.abs() < 1e15) return d.toInt().toString();
  return d.toStringAsFixed(6);
}

/// Excel sheet names: max 31 chars, no `[]:*?/\`.
String _sheetName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  return cleaned.length <= 31 ? cleaned : cleaned.substring(0, 31);
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    // Control characters are illegal in XML 1.0 and make Excel refuse the file.
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

String _attr(String s) => _esc(s).replaceAll('"', '&quot;');
