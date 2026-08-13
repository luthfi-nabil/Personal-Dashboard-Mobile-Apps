import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'export_report.dart';
import 'utils.dart';

/// Minimal WordprocessingML (.docx) writer — headings, paragraphs and tables.
/// Same approach as `export_xlsx.dart`: hand-rolled OOXML, zipped with
/// `archive`, so there is no heavyweight document dependency.

class DocxTable {
  final List<String> headers;
  final List<List<String>> rows;

  /// Column widths in percent of the page width; must sum to ~100.
  final List<int> widths;

  /// Columns rendered right-aligned (amounts).
  final Set<int> rightAlign;

  const DocxTable({
    required this.headers,
    required this.rows,
    required this.widths,
    this.rightAlign = const {},
  });
}

Uint8List buildFinanceDocx(ExportReport r, String currency) {
  String rp(double v) => fmtRp(v, currency);

  final body = StringBuffer();

  body.write(_title('Finance Recap'));
  body.write(_para(r.rangeLabel, size: 24, color: '6B6857'));
  body.write(_para(
      'Generated ${_stamp(r.generatedAt)} · ${r.months.length} month(s) · '
      '${r.transactions.length} transactions',
      size: 18,
      color: '6B6857'));

  // ── Overview ─────────────────────────────────────────────────────────────
  body.write(_heading('Overview', 1));
  body.write(_table(DocxTable(
    headers: const ['Metric', 'Value'],
    widths: const [55, 45],
    rightAlign: const {1},
    rows: [
      ['Total earned', rp(r.totalEarn)],
      ['Total spent', rp(r.totalSpend)],
      ['Net', rp(r.totalNet)],
      ['Average earned / month', rp(r.avgEarn)],
      ['Average spent / month', rp(r.avgSpend)],
      if (r.bestMonth != null)
        ['Best month', '${r.bestMonth!.label} (${rp(r.bestMonth!.net)})'],
      if (r.worstMonth != null)
        ['Weakest month', '${r.worstMonth!.label} (${rp(r.worstMonth!.net)})'],
      ['Liquid (all sources, today)', rp(r.liquid)],
    ],
  )));

  // ── Monthly recap ────────────────────────────────────────────────────────
  body.write(_heading('Monthly recap', 1));
  body.write(_table(DocxTable(
    headers: const ['Month', 'Earned', 'Spent', 'Net', 'Txns'],
    widths: const [28, 19, 19, 19, 15],
    rightAlign: const {1, 2, 3, 4},
    rows: [
      for (final m in r.summaries)
        [
          m.label,
          rp(m.earn),
          rp(m.spend),
          rp(m.net),
          '${m.earnCount + m.spendCount + m.transferCount}',
        ],
      [
        'Total',
        rp(r.totalEarn),
        rp(r.totalSpend),
        rp(r.totalNet),
        '${r.transactions.length}',
      ],
    ],
  )));

  // ── Per month ────────────────────────────────────────────────────────────
  for (final m in r.summaries) {
    body.write(_pageBreak());
    body.write(_heading(m.label, 1));
    body.write(_para(
      'In ${rp(m.earn)}   ·   Out ${rp(m.spend)}   ·   Net ${rp(m.net)}',
      size: 22,
      bold: true,
    ));

    for (final type in const ['spending', 'earning']) {
      final rows = r.categoriesFor(m.ym, type);
      final label = type == 'spending' ? 'Spending by category' : 'Earning by category';
      body.write(_heading(label, 2));
      if (rows.isEmpty) {
        body.write(_para('No $type recorded this month.', color: '6B6857'));
        continue;
      }
      body.write(_table(DocxTable(
        headers: const ['Category', 'Txns', 'Amount', 'Share'],
        widths: const [46, 14, 24, 16],
        rightAlign: const {1, 2, 3},
        rows: [
          for (final c in rows)
            [
              c.category,
              '${c.count}',
              rp(c.amount),
              '${(c.share * 100).toStringAsFixed(1)}%',
            ],
          [
            'Total',
            '${rows.fold<int>(0, (s, c) => s + c.count)}',
            rp(type == 'spending' ? m.spend : m.earn),
            '100.0%',
          ],
        ],
      )));
    }

    final txns = r.transactionsFor(m.ym);
    body.write(_heading('Transactions (${txns.length})', 2));
    if (txns.isEmpty) {
      body.write(_para('No transactions this month.', color: '6B6857'));
    } else {
      body.write(_table(DocxTable(
        headers: const ['Date', 'Type', 'Category', 'Source', 'Description', 'Amount'],
        widths: const [12, 12, 18, 17, 24, 17],
        rightAlign: const {5},
        rows: [
          for (final t in txns)
            [
              fmtDate(t.date, 'short'),
              t.type,
              t.type == 'transfer' ? '—' : (t.category ?? ''),
              t.type == 'transfer'
                  ? '${t.fromSource ?? '?'} → ${t.toSource ?? '?'}'
                  : (t.source ?? ''),
              t.description,
              switch (t.type) {
                'earning' => '+${rp(t.amount)}',
                'spending' => '−${rp(t.amount)}',
                _ => rp(t.amount),
              },
            ],
        ],
      )));
    }
  }

  // ── Sources ──────────────────────────────────────────────────────────────
  body.write(_pageBreak());
  body.write(_heading('Source balances', 1));
  body.write(_para('Snapshot across all history, taken at export time.',
      color: '6B6857'));
  body.write(_table(DocxTable(
    headers: const ['Source', 'Kind', 'Balance'],
    widths: const [50, 22, 28],
    rightAlign: const {2},
    rows: [
      for (final s in r.sources) [s.name, s.kind, rp(s.balance)],
      ['Liquid', '', rp(r.liquid)],
    ],
  )));

  return _package(body.toString());
}

// ── OOXML plumbing ─────────────────────────────────────────────────────────

Uint8List _package(String bodyXml) {
  final archive = Archive();
  void add(String path, String xml) {
    final bytes = utf8.encode(xml);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('[Content_Types].xml', _contentTypesXml);
  add('_rels/.rels', _rootRelsXml);
  add('word/_rels/document.xml.rels', _documentRelsXml);
  add('word/styles.xml', _stylesXml);
  add(
    'word/document.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:body>$bodyXml'
    '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
    '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" '
    'w:header="709" w:footer="709" w:gutter="0"/></w:sectPr>'
    '</w:body></w:document>',
  );

  final zipped = ZipEncoder().encode(archive);
  return Uint8List.fromList(zipped!);
}

const _contentTypesXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
    '</Types>';

const _rootRelsXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
    '</Relationships>';

const _documentRelsXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>';

const _stylesXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:docDefaults><w:rPrDefault><w:rPr>'
    '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>'
    '<w:sz w:val="20"/><w:szCs w:val="20"/>'
    '</w:rPr></w:rPrDefault></w:docDefaults>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
    '<w:name w:val="Normal"/><w:pPr><w:spacing w:after="120"/></w:pPr></w:style>'
    '</w:styles>';

String _title(String text) =>
    '<w:p><w:pPr><w:spacing w:after="60"/></w:pPr>'
    '<w:r><w:rPr><w:b/><w:sz w:val="44"/></w:rPr>'
    '<w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';

String _heading(String text, int level) {
  final size = level == 1 ? 30 : 24;
  final before = level == 1 ? 320 : 240;
  return '<w:p><w:pPr><w:spacing w:before="$before" w:after="120"/></w:pPr>'
      '<w:r><w:rPr><w:b/><w:sz w:val="$size"/><w:color w:val="1A1A1A"/></w:rPr>'
      '<w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';
}

String _para(String text, {int size = 20, bool bold = false, String? color}) {
  final rpr = StringBuffer('<w:rPr>');
  if (bold) rpr.write('<w:b/>');
  rpr.write('<w:sz w:val="$size"/>');
  if (color != null) rpr.write('<w:color w:val="$color"/>');
  rpr.write('</w:rPr>');
  return '<w:p><w:r>$rpr<w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';
}

String _pageBreak() =>
    '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';

String _table(DocxTable t) {
  final buf = StringBuffer()
    ..write('<w:tbl><w:tblPr>'
        '<w:tblW w:w="5000" w:type="pct"/>'
        '<w:tblBorders>'
        '<w:top w:val="single" w:sz="4" w:color="D5D0C4"/>'
        '<w:left w:val="none" w:sz="0" w:color="auto"/>'
        '<w:bottom w:val="single" w:sz="4" w:color="D5D0C4"/>'
        '<w:right w:val="none" w:sz="0" w:color="auto"/>'
        '<w:insideH w:val="single" w:sz="4" w:color="EAE6DB"/>'
        '<w:insideV w:val="none" w:sz="0" w:color="auto"/>'
        '</w:tblBorders>'
        '<w:tblCellMar>'
        '<w:top w:w="60" w:type="dxa"/><w:left w:w="90" w:type="dxa"/>'
        '<w:bottom w:w="60" w:type="dxa"/><w:right w:w="90" w:type="dxa"/>'
        '</w:tblCellMar>'
        '</w:tblPr><w:tblGrid>');
  for (final w in t.widths) {
    buf.write('<w:gridCol w:w="${(w * 92).round()}"/>');
  }
  buf.write('</w:tblGrid>');

  // Header row: repeats on every page.
  buf.write('<w:tr><w:trPr><w:tblHeader/></w:trPr>');
  for (var i = 0; i < t.headers.length; i++) {
    buf.write(_cell(t.headers[i], t.widths[i],
        bold: true, shade: 'EFEBE0', right: t.rightAlign.contains(i)));
  }
  buf.write('</w:tr>');

  for (var r = 0; r < t.rows.length; r++) {
    final row = t.rows[r];
    final isTotal = r == t.rows.length - 1 &&
        row.isNotEmpty &&
        (row.first == 'Total' || row.first == 'Liquid');
    buf.write('<w:tr>');
    for (var i = 0; i < t.widths.length; i++) {
      final value = i < row.length ? row[i] : '';
      buf.write(_cell(value, t.widths[i],
          bold: isTotal, right: t.rightAlign.contains(i)));
    }
    buf.write('</w:tr>');
  }

  buf.write('</w:tbl>');
  // Word needs a paragraph after a table, otherwise consecutive tables merge.
  buf.write('<w:p><w:pPr><w:spacing w:after="0"/></w:pPr></w:p>');
  return buf.toString();
}

String _cell(String text, int widthPct,
    {bool bold = false, bool right = false, String? shade}) {
  final shading =
      shade == null ? '' : '<w:shd w:val="clear" w:color="auto" w:fill="$shade"/>';
  final align = right ? '<w:jc w:val="right"/>' : '';
  final rpr = bold ? '<w:rPr><w:b/></w:rPr>' : '';
  return '<w:tc><w:tcPr><w:tcW w:w="${widthPct * 50}" w:type="pct"/>$shading</w:tcPr>'
      '<w:p><w:pPr><w:spacing w:after="0"/>$align</w:pPr>'
      '<w:r>$rpr<w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p></w:tc>';
}

String _stamp(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
