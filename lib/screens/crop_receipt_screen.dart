import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/image_crop.dart';

/// Which part of the crop rectangle a drag is manipulating.
enum _Handle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  left,
  right,
  top,
  bottom,
  move,
  none,
}

/// Lets the user mark the part of a photographed receipt that should be read.
///
/// Pops a normalized [Rect] (0..1 in image coordinates) when the user confirms,
/// or `null` when they back out. Restricting OCR to the price-list block is the
/// single biggest accuracy win: store headers, addresses, loyalty blurb and the
/// totals footer never reach the parser.
class CropReceiptScreen extends StatefulWidget {
  final File image;

  /// Rectangle to start from, so "adjust area & rescan" reopens where the user
  /// left off. Defaults to a slight inset of the full frame.
  final Rect? initialCrop;

  const CropReceiptScreen({super.key, required this.image, this.initialCrop});

  @override
  State<CropReceiptScreen> createState() => _CropReceiptScreenState();
}

class _CropReceiptScreenState extends State<CropReceiptScreen> {
  /// A little inside the frame, hinting that the edges can be pulled in.
  static const _defaultCrop =
      Rect.fromLTRB(0.06, 0.06, 0.94, 0.94);
  static const _minSide = 0.06;
  static const _touchSlop = 30.0;

  ui.Image? _image;
  String? _error;
  late Rect _crop = widget.initialCrop ?? _defaultCrop;

  _Handle _active = _Handle.none;
  Rect _imageRect = Rect.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final decoded = await ImageCrop.decodeFile(widget.image);
      if (!mounted) {
        decoded.dispose();
        return;
      }
      setState(() => _image = decoded);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not open the photo: $e');
    }
  }

  // ── Coordinate conversion ────────────────────────────────────────────────
  /// Where the letterboxed image sits inside [viewSize] under `BoxFit.contain`.
  Rect _computeImageRect(Size viewSize, ui.Image image) {
    final imageAspect = image.width / image.height;
    final viewAspect = viewSize.width / viewSize.height;
    final double width, height;
    if (viewAspect > imageAspect) {
      height = viewSize.height;
      width = height * imageAspect;
    } else {
      width = viewSize.width;
      height = width / imageAspect;
    }
    return Rect.fromLTWH(
      (viewSize.width - width) / 2,
      (viewSize.height - height) / 2,
      width,
      height,
    );
  }

  Rect _toView(Rect normalized) => Rect.fromLTRB(
        _imageRect.left + normalized.left * _imageRect.width,
        _imageRect.top + normalized.top * _imageRect.height,
        _imageRect.left + normalized.right * _imageRect.width,
        _imageRect.top + normalized.bottom * _imageRect.height,
      );

  // ── Gestures ─────────────────────────────────────────────────────────────
  _Handle _hitTest(Offset point) {
    final view = _toView(_crop);
    bool near(double a, double b) => (a - b).abs() <= _touchSlop;

    final nearLeft = near(point.dx, view.left);
    final nearRight = near(point.dx, view.right);
    final nearTop = near(point.dy, view.top);
    final nearBottom = near(point.dy, view.bottom);
    final withinX =
        point.dx >= view.left - _touchSlop && point.dx <= view.right + _touchSlop;
    final withinY =
        point.dy >= view.top - _touchSlop && point.dy <= view.bottom + _touchSlop;

    if (nearLeft && nearTop) return _Handle.topLeft;
    if (nearRight && nearTop) return _Handle.topRight;
    if (nearLeft && nearBottom) return _Handle.bottomLeft;
    if (nearRight && nearBottom) return _Handle.bottomRight;
    if (nearLeft && withinY) return _Handle.left;
    if (nearRight && withinY) return _Handle.right;
    if (nearTop && withinX) return _Handle.top;
    if (nearBottom && withinX) return _Handle.bottom;
    if (view.contains(point)) return _Handle.move;
    return _Handle.none;
  }

  void _onPanStart(DragStartDetails details) {
    setState(() => _active = _hitTest(details.localPosition));
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_active == _Handle.none || _imageRect.isEmpty) return;

    // Work in normalized space so the rectangle is resolution independent.
    final dx = details.delta.dx / _imageRect.width;
    final dy = details.delta.dy / _imageRect.height;

    var left = _crop.left;
    var top = _crop.top;
    var right = _crop.right;
    var bottom = _crop.bottom;

    switch (_active) {
      case _Handle.move:
        final width = right - left;
        final height = bottom - top;
        left = (left + dx).clamp(0.0, 1.0 - width);
        top = (top + dy).clamp(0.0, 1.0 - height);
        right = left + width;
        bottom = top + height;
      case _Handle.topLeft:
        left = (left + dx).clamp(0.0, right - _minSide);
        top = (top + dy).clamp(0.0, bottom - _minSide);
      case _Handle.topRight:
        right = (right + dx).clamp(left + _minSide, 1.0);
        top = (top + dy).clamp(0.0, bottom - _minSide);
      case _Handle.bottomLeft:
        left = (left + dx).clamp(0.0, right - _minSide);
        bottom = (bottom + dy).clamp(top + _minSide, 1.0);
      case _Handle.bottomRight:
        right = (right + dx).clamp(left + _minSide, 1.0);
        bottom = (bottom + dy).clamp(top + _minSide, 1.0);
      case _Handle.left:
        left = (left + dx).clamp(0.0, right - _minSide);
      case _Handle.right:
        right = (right + dx).clamp(left + _minSide, 1.0);
      case _Handle.top:
        top = (top + dy).clamp(0.0, bottom - _minSide);
      case _Handle.bottom:
        bottom = (bottom + dy).clamp(top + _minSide, 1.0);
      case _Handle.none:
        return;
    }

    setState(() => _crop = Rect.fromLTRB(left, top, right, bottom));
  }

  void _onPanEnd() => setState(() => _active = _Handle.none);

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Select area to read',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop<Rect?>(context, null),
        ),
        actions: [
          TextButton(
            onPressed: image == null
                ? null
                : () => setState(() => _crop = _defaultCrop),
            child: const Text('Reset', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Text(
                'Drag the corners so only the item and price columns are inside '
                'the box. Leaving out the header and the totals gives much '
                'cleaner results.',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                    height: 1.4),
              ),
            ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70)),
                      ),
                    )
                  : image == null
                      ? const Center(
                          child: CircularProgressIndicator(color: Colors.white))
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final size = Size(
                                constraints.maxWidth, constraints.maxHeight);
                            _imageRect = _computeImageRect(size, image);
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: _onPanStart,
                              onPanUpdate: _onPanUpdate,
                              onPanEnd: (_) => _onPanEnd(),
                              onPanCancel: _onPanEnd,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  RawImage(
                                    image: image,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                  ),
                                  CustomPaint(
                                    painter: _CropOverlayPainter(
                                      cropRect: _toView(_crop),
                                      dragging: _active != _Handle.none,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: OutlinedButton(
                        onPressed: image == null
                            ? null
                            : () => Navigator.pop<Rect?>(
                                context, const Rect.fromLTRB(0, 0, 1, 1)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.4)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text('Whole photo',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: image == null
                            ? null
                            : () => Navigator.pop<Rect?>(context, _crop),
                        icon: const Icon(Icons.check_rounded, size: 19),
                        label: const Text('Read this area',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dims everything outside the selection and draws the border, thirds guides
/// and corner grips.
class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;
  final bool dragging;

  const _CropOverlayPainter({required this.cropRect, required this.dragging});

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(cropRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      shade,
      Paint()..color = Colors.black.withValues(alpha: 0.62),
    );

    canvas.drawRect(
      cropRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: 0.9),
    );

    // Rule-of-thirds guides, only while dragging so the view stays clean.
    if (dragging) {
      final guide = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = Colors.white.withValues(alpha: 0.35);
      for (var i = 1; i < 3; i++) {
        final dx = cropRect.left + cropRect.width * i / 3;
        final dy = cropRect.top + cropRect.height * i / 3;
        canvas.drawLine(
            Offset(dx, cropRect.top), Offset(dx, cropRect.bottom), guide);
        canvas.drawLine(
            Offset(cropRect.left, dy), Offset(cropRect.right, dy), guide);
      }
    }

    final grip = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    final length = (cropRect.shortestSide * 0.18).clamp(14.0, 30.0);

    void corner(Offset at, double sx, double sy) {
      canvas.drawLine(at, at.translate(length * sx, 0), grip);
      canvas.drawLine(at, at.translate(0, length * sy), grip);
    }

    corner(cropRect.topLeft, 1, 1);
    corner(cropRect.topRight, -1, 1);
    corner(cropRect.bottomLeft, 1, -1);
    corner(cropRect.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(_CropOverlayPainter old) =>
      old.cropRect != cropRect || old.dragging != dragging;
}
