import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../core/image_crop.dart';
import '../core/models.dart';
import '../core/receipt_scanner.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import 'add_transaction_screen.dart';
import 'crop_receipt_screen.dart';

/// Photograph a price list, read it on-device with OCR, then let the user
/// confirm every recognised row before it becomes a transaction's detail.
///
/// The screen never saves anything itself: on confirm it hands an
/// [AddTransactionDraft] to the normal Add-transaction flow, so category,
/// source and validation behave exactly like a manually entered spending.
class ScanReceiptScreen extends ConsumerStatefulWidget {
  final String? returnPath;
  const ScanReceiptScreen({super.key, this.returnPath});

  @override
  ConsumerState<ScanReceiptScreen> createState() => _ScanReceiptScreenState();
}

class _ScanReceiptScreenState extends ConsumerState<ScanReceiptScreen> {
  final _scanner = ReceiptScanner();
  final _uuid = const Uuid();

  final List<_EditableItem> _items = [];
  bool _scanning = false;
  bool _hasScanned = false;
  String? _error;
  double? _printedTotal;
  String _rawText = '';

  /// The photo as captured. Kept so the user can re-crop and re-read it without
  /// shooting the receipt again.
  File? _sourceImage;

  /// What was actually fed to OCR - shown as a thumbnail on the review list.
  File? _scannedImage;

  /// Selected region in 0..1 image coordinates, reused as the crop screen's
  /// starting rectangle on every subsequent adjustment.
  Rect? _cropRect;

  @override
  void dispose() {
    for (final item in _items) {
      item.dispose();
    }
    _scanner.dispose();
    ImageCrop.discard(_scannedImage);
    super.dispose();
  }

  double get _selectedTotal => _items
      .where((item) => item.selected)
      .fold<double>(0, (sum, item) => sum + item.amount);

  int get _selectedCount => _items.where((item) => item.selected).length;

  /// Capture -> crop -> OCR. Backing out of either the picker or the crop
  /// screen leaves the current results untouched.
  Future<void> _captureAndScan({required bool fromGallery}) async {
    setState(() => _error = null);
    try {
      final photo = await _scanner.pickImage(fromGallery: fromGallery);
      if (!mounted || photo == null) return;
      _sourceImage = photo;
      await _cropAndScan(initialCrop: null);
    } on ReceiptScanException catch (e) {
      if (!mounted) return;
      setState(() {
        _hasScanned = true;
        _error = e.message;
      });
    }
  }

  /// Reopens the crop screen for the photo already taken, then re-reads it.
  Future<void> _adjustAreaAndRescan() =>
      _cropAndScan(initialCrop: _cropRect);

  Future<void> _cropAndScan({required Rect? initialCrop}) async {
    final source = _sourceImage;
    if (source == null) return;

    // Review step: the user marks the region that should be read. Excluding the
    // store header and the totals footer is what makes the parse clean.
    final crop = await Navigator.of(context).push<Rect?>(
      MaterialPageRoute<Rect?>(
        builder: (_) => CropReceiptScreen(
          image: source,
          initialCrop: initialCrop,
        ),
        fullscreenDialog: true,
      ),
    );
    if (!mounted || crop == null) return;

    setState(() {
      _scanning = true;
      _error = null;
      _cropRect = crop;
    });

    final previousScanned = _scannedImage;
    File? cropped;
    try {
      cropped = await ImageCrop.cropToFile(source: source, normalizedCrop: crop);
      final result = await _scanner.scanFile(cropped);
      if (!mounted) {
        await ImageCrop.discard(cropped);
        return;
      }

      _replaceItems(result.items);
      _scannedImage = cropped;
      setState(() {
        _scanning = false;
        _hasScanned = true;
        _printedTotal = result.printedTotal;
        _rawText = result.rawText;
        _error = result.isEmpty
            ? 'No prices recognised in that area. Try selecting a tighter box '
                'around the item and price columns, or retake the photo closer.'
            : null;
      });
      await ImageCrop.discard(previousScanned);
    } catch (e) {
      // The crop that failed is useless, and so is the preview of the previous
      // one - it would no longer match the message on screen.
      await ImageCrop.discard(cropped);
      await ImageCrop.discard(previousScanned);
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _hasScanned = true;
        _scannedImage = null;
        _error = e is ReceiptScanException ? e.message : 'Scan failed: $e';
      });
    }
  }

  void _replaceItems(List<ScannedItem> scanned) {
    for (final item in _items) {
      item.dispose();
    }
    _items
      ..clear()
      ..addAll(scanned.map(_EditableItem.fromScan));
  }

  void _addBlankItem() {
    setState(() => _items.add(_EditableItem.blank()));
  }

  void _removeItem(_EditableItem item) {
    setState(() {
      _items.remove(item);
      item.dispose();
    });
  }

  void _confirm() {
    final selected = _items.where((item) => item.selected).toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one item to continue.')),
      );
      return;
    }

    final details = selected
        .map((item) => TransactionDetail(
              id: _uuid.v4(),
              transactionId: '',
              itemName: item.name,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
              amount: item.amount,
              note: item.isCharge ? 'Tax / service' : '',
              updatedAt: DateTime.now().toIso8601String(),
            ))
        .toList();

    final draft = AddTransactionDraft(
      details: details,
      description: _suggestDescription(details),
      amount: _selectedTotal,
    );

    final target = widget.returnPath == null || widget.returnPath!.isEmpty
        ? '/add'
        : Uri(path: '/add', queryParameters: {'returnTo': widget.returnPath!})
            .toString();
    context.replace(target, extra: draft);
  }

  /// A short, human description so the transaction list stays readable:
  /// "Indomie Goreng, Telur 1kg +3 more". Tax and service rows are skipped -
  /// they say nothing about what the spending was for.
  String _suggestDescription(List<TransactionDetail> details) {
    final products = details.where((d) => d.note.isEmpty).toList();
    final names = (products.isEmpty ? details : products)
        .map((d) => d.itemName.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (names.isEmpty) return 'Scanned receipt';
    final head = names.take(2).join(', ');
    final rest = names.length - 2;
    return rest > 0 ? '$head +$rest more' : head;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final supported = ReceiptScanner.isSupported;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            _Header(c: c, onClose: () => context.pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                children: [
                  if (!supported)
                    _Notice(
                      c: c,
                      icon: Icons.desktop_access_disabled_rounded,
                      text: 'On-device receipt OCR is available on Android and '
                          'iOS only. You can still build the item list by hand '
                          'and continue.',
                    )
                  else if (!_hasScanned && _items.isEmpty)
                    _Notice(
                      c: c,
                      icon: Icons.document_scanner_outlined,
                      text: 'Photograph the printed price list, then mark the '
                          'area to read. Everything is processed on your phone - '
                          'the image is never uploaded, and you confirm each row '
                          'before anything is saved.',
                    ),
                  const SizedBox(height: 12),
                  if (supported)
                    Row(
                      children: [
                        Expanded(
                          child: _ScanButton(
                            icon: Icons.photo_camera_outlined,
                            label: _sourceImage == null
                                ? 'Take photo'
                                : 'New photo',
                            enabled: !_scanning,
                            c: c,
                            onTap: () => _captureAndScan(fromGallery: false),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ScanButton(
                            icon: Icons.photo_library_outlined,
                            label: 'From gallery',
                            enabled: !_scanning,
                            filled: false,
                            c: c,
                            onTap: () => _captureAndScan(fromGallery: true),
                          ),
                        ),
                      ],
                    ),
                  // Re-crop the photo already taken and read it again. This is
                  // the quickest fix when the first pass grabbed the header or
                  // missed a column.
                  if (_sourceImage != null) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 46,
                      child: OutlinedButton.icon(
                        onPressed: _scanning ? null : _adjustAreaAndRescan,
                        icon: Icon(Icons.crop_rounded, size: 18, color: c.ink),
                        label: Text('Adjust area & rescan',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: c.ink)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: c.line, width: 0.8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                  if (_scanning) ...[
                    const SizedBox(height: 20),
                    Center(
                      child: Column(
                        children: [
                          CircularProgressIndicator(color: c.accent),
                          const SizedBox(height: 10),
                          Text('Reading the selected area…',
                              style: TextStyle(color: c.muted, fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    _Notice(
                      c: c,
                      icon: Icons.error_outline_rounded,
                      text: _error!,
                      tone: c.neg,
                    ),
                  ],
                  // What OCR actually saw, so a bad crop is obvious at a glance.
                  if (_scannedImage != null && !_scanning) ...[
                    const SizedBox(height: 14),
                    _ScannedPreview(
                      image: _scannedImage!,
                      c: c,
                      onTap: _adjustAreaAndRescan,
                    ),
                  ],
                  if (_items.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Recognised items',
                            style: TextStyle(
                              color: c.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Text('$_selectedCount of ${_items.length} selected',
                            style: TextStyle(color: c.muted, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Check the amounts against the receipt - OCR can misread '
                      'digits. Tax and service lines are included as items; '
                      'untick anything that is not part of what you paid.',
                      style:
                          TextStyle(color: c.muted, fontSize: 12, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    ..._items.map((item) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _ItemCard(
                            item: item,
                            c: c,
                            onChanged: () => setState(() {}),
                            onRemove: () => _removeItem(item),
                          ),
                        )),
                  ],
                  const SizedBox(height: 6),
                  if (_hasScanned || _items.isNotEmpty || !supported)
                    TextButton.icon(
                      onPressed: _addBlankItem,
                      icon: Icon(Icons.add_rounded, size: 18, color: c.accent),
                      label: Text('Add item manually',
                          style: TextStyle(color: c.accent)),
                    ),
                  if (_printedTotal != null && _items.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _TotalCheck(
                      printedTotal: _printedTotal!,
                      selectedTotal: _selectedTotal,
                      currency: cfg.currency,
                      c: c,
                    ),
                  ],
                  if (_rawText.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _RawTextPanel(text: _rawText, c: c),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _items.isEmpty
          ? null
          : _ConfirmBar(
              total: _selectedTotal,
              count: _selectedCount,
              currency: cfg.currency,
              c: c,
              onConfirm: _confirm,
            ),
    );
  }
}

/// One editable row on the review list. Holds its own controllers so text
/// stays put while the user tweaks other rows.
class _EditableItem {
  final TextEditingController nameCtl;
  final TextEditingController qtyCtl;
  final TextEditingController amountCtl;
  final String sourceLine;

  /// Recognised as a tax or service line. Carried through to the saved detail
  /// as its note, so the breakdown still says which rows were not products.
  final bool isCharge;
  bool selected;

  _EditableItem({
    required this.nameCtl,
    required this.qtyCtl,
    required this.amountCtl,
    this.sourceLine = '',
    this.isCharge = false,
    this.selected = true,
  });

  factory _EditableItem.fromScan(ScannedItem item) => _EditableItem(
        nameCtl: TextEditingController(text: item.name),
        qtyCtl: TextEditingController(text: _trimNumber(item.quantity)),
        amountCtl: TextEditingController(text: _trimNumber(item.amount)),
        sourceLine: item.sourceLine,
        isCharge: item.isCharge,
      );

  factory _EditableItem.blank() => _EditableItem(
        nameCtl: TextEditingController(),
        qtyCtl: TextEditingController(text: '1'),
        amountCtl: TextEditingController(),
      );

  String get name =>
      nameCtl.text.trim().isEmpty ? 'Item' : nameCtl.text.trim();

  double get quantity {
    final parsed = double.tryParse(qtyCtl.text.replaceAll(',', '.')) ?? 1;
    return parsed <= 0 ? 1 : parsed;
  }

  double get amount =>
      double.tryParse(amountCtl.text.replaceAll(',', '.')) ?? 0;

  double get unitPrice => quantity == 0 ? amount : amount / quantity;

  void dispose() {
    nameCtl.dispose();
    qtyCtl.dispose();
    amountCtl.dispose();
  }

  static String _trimNumber(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2);
}

class _Header extends StatelessWidget {
  final AppColors c;
  final VoidCallback onClose;
  const _Header({required this.c, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: onClose,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: c.surface, borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.close_rounded, size: 20, color: c.ink),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Scan price list',
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700, color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool filled;
  final AppColors c;
  final VoidCallback onTap;

  const _ScanButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.c,
    required this.onTap,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: filled
          ? ElevatedButton.icon(
              onPressed: enabled ? onTap : null,
              icon: Icon(icon, size: 19),
              label: Text(label,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: c.ink,
                foregroundColor: c.bg,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            )
          : OutlinedButton.icon(
              onPressed: enabled ? onTap : null,
              icon: Icon(icon, size: 19, color: c.ink),
              label: Text(label,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.ink)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.line, width: 0.8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  final _EditableItem item;
  final AppColors c;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _ItemCard({
    required this.item,
    required this.c,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final active = item.selected;
    return Opacity(
      opacity: active ? 1 : 0.5,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: active ? c.line : c.line2, width: active ? 0.8 : 0.5),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Checkbox(
                  value: item.selected,
                  activeColor: c.accent,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) {
                    item.selected = v ?? false;
                    onChanged();
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: item.nameCtl,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: c.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Item name',
                      hintStyle: TextStyle(color: c.muted, fontSize: 15),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                if (item.isCharge) _ChargeChip(c: c),
                GestureDetector(
                  onTap: onRemove,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.delete_outline_rounded,
                        size: 19, color: c.muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Row(
                children: [
                  SizedBox(
                    width: 62,
                    child: _MiniField(
                      controller: item.qtyCtl,
                      label: 'Qty',
                      c: c,
                      onChanged: onChanged,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MiniField(
                      controller: item.amountCtl,
                      label: 'Amount',
                      c: c,
                      onChanged: onChanged,
                    ),
                  ),
                ],
              ),
            ),
            if (item.sourceLine.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'read: ${item.sourceLine}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.muted,
                        fontSize: 11,
                        fontStyle: FontStyle.italic),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Marks a row the parser read as tax or service rather than a product.
class _ChargeChip extends StatelessWidget {
  final AppColors c;
  const _ChargeChip({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'tax / service',
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w600, color: c.muted),
      ),
    );
  }
}

class _MiniField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final AppColors c;
  final VoidCallback onChanged;

  const _MiniField({
    required this.controller,
    required this.label,
    required this.c,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      style: TextStyle(fontSize: 14, color: c.ink),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        labelStyle: TextStyle(color: c.muted, fontSize: 12),
        filled: true,
        fillColor: c.surface2,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: c.line2, width: 0.5)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: c.line2, width: 0.5)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      onChanged: (_) => onChanged(),
    );
  }
}

/// Thumbnail of the exact region handed to OCR. Tapping it reopens the crop
/// screen, which is the natural gesture when the preview looks wrong.
class _ScannedPreview extends StatelessWidget {
  final File image;
  final AppColors c;
  final VoidCallback onTap;

  const _ScannedPreview({
    required this.image,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.line2, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.crop_rounded, size: 15, color: c.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Area that was read — tap to adjust',
                      style: TextStyle(color: c.muted, fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 190),
                child: Image.file(
                  image,
                  width: double.infinity,
                  fit: BoxFit.contain,
                  alignment: Alignment.topCenter,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final AppColors c;
  final IconData icon;
  final String text;
  final Color? tone;

  const _Notice(
      {required this.c, required this.icon, required this.text, this.tone});

  @override
  Widget build(BuildContext context) {
    final color = tone ?? c.muted;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: color, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// Compares what was ticked against the total printed on the receipt, so a
/// misread digit or a missed row is obvious before saving.
class _TotalCheck extends StatelessWidget {
  final double printedTotal;
  final double selectedTotal;
  final String currency;
  final AppColors c;

  const _TotalCheck({
    required this.printedTotal,
    required this.selectedTotal,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final diff = selectedTotal - printedTotal;
    final matches = diff.abs() < 1;
    final color = matches ? c.pos : c.neg;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.8),
      ),
      child: Row(
        children: [
          Icon(matches ? Icons.check_circle_outline : Icons.info_outline,
              size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              matches
                  ? 'Items match the printed total of ${fmtRp(printedTotal, currency)}.'
                  : 'Printed total is ${fmtRp(printedTotal, currency)} — your '
                      'selection is off by ${fmtRp(diff.abs(), currency)}. Check '
                      'for a missed row, or a tax or service line that was not '
                      'recognised.',
              style: TextStyle(fontSize: 12, color: c.muted, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _RawTextPanel extends StatelessWidget {
  final String text;
  final AppColors c;
  const _RawTextPanel({required this.text, required this.c});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('Raw scanned text',
            style: TextStyle(fontSize: 13, color: c.muted)),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(text,
                style: TextStyle(
                    fontSize: 11, color: c.muted, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

class _ConfirmBar extends StatelessWidget {
  final double total;
  final int count;
  final String currency;
  final AppColors c;
  final VoidCallback onConfirm;

  const _ConfirmBar({
    required this.total,
    required this.count,
    required this.currency,
    required this.c,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, 10 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line2, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$count item${count == 1 ? '' : 's'}',
                    style: TextStyle(color: c.muted, fontSize: 12)),
                const SizedBox(height: 2),
                Text(
                  fmtRp(total, currency),
                  style: TextStyle(
                      color: c.ink, fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: onConfirm,
              style: ElevatedButton.styleFrom(
                backgroundColor: c.ink,
                foregroundColor: c.bg,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Confirm items',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}
