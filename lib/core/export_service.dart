import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'config.dart';
import 'export_docx.dart';
import 'export_report.dart';
import 'export_xlsx.dart';
import 'models.dart';

enum ExportFormat { xlsx, docx }

extension ExportFormatX on ExportFormat {
  String get extension => this == ExportFormat.xlsx ? 'xlsx' : 'docx';
  String get label => this == ExportFormat.xlsx ? 'Excel (.xlsx)' : 'Word (.docx)';
  String get mimeType => this == ExportFormat.xlsx
      ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
}

class ExportResult {
  final String path;

  /// True when the file was handed to the OS share sheet (mobile) instead of
  /// being written to a folder the user can browse.
  final bool shared;

  const ExportResult({required this.path, required this.shared});

  String get message => shared
      ? 'Exported ${_basename(path)}'
      : 'Saved to $path';
}

String _basename(String path) =>
    path.split(Platform.pathSeparator).last.split('/').last;

class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Builds the recap for [months] and writes it as [format].
  Future<ExportResult> exportFinance({
    required AppData data,
    required Iterable<String> months,
    required ExportFormat format,
  }) async {
    final report = ExportReport.build(data, months);
    final currency = ConfigService.instance.current.currency;
    final bytes = format == ExportFormat.xlsx
        ? buildFinanceXlsx(report)
        : buildFinanceDocx(report, currency);
    return save(
      bytes: bytes,
      fileName: '${report.fileStem}.${format.extension}',
      mimeType: format.mimeType,
    );
  }

  /// Writes [bytes] somewhere the user can reach them: the share sheet on
  /// mobile, the Downloads folder on desktop.
  Future<ExportResult> save({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (_isMobile) {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: mimeType, name: fileName)],
        subject: fileName,
      );
      return ExportResult(path: file.path, shared: true);
    }

    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {
      dir = null;
    }
    dir ??= await getApplicationDocumentsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${_unique(dir, fileName)}');
    await file.writeAsBytes(bytes, flush: true);
    return ExportResult(path: file.path, shared: false);
  }

  /// Avoids silently overwriting a previous export: `name.xlsx`,
  /// `name (2).xlsx`, `name (3).xlsx`, …
  String _unique(Directory dir, String fileName) {
    final dot = fileName.lastIndexOf('.');
    final stem = dot == -1 ? fileName : fileName.substring(0, dot);
    final ext = dot == -1 ? '' : fileName.substring(dot);
    var candidate = fileName;
    var n = 2;
    while (File('${dir.path}${Platform.pathSeparator}$candidate').existsSync()) {
      candidate = '$stem ($n)$ext';
      n++;
    }
    return candidate;
  }
}
