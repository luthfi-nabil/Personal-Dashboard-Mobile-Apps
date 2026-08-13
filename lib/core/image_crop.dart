import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Decoding + cropping helpers for the receipt scanner, built on `dart:ui` so
/// no extra image-processing dependency is needed.
///
/// Orientation note: `image_picker` is called with `imageQuality`, which makes
/// it re-encode the photo and bake any EXIF rotation into the pixels. Both this
/// decoder and ML Kit therefore see the same upright image.
class ImageCrop {
  const ImageCrop._();

  /// Decodes [bytes] into a `ui.Image`. Callers own the result and must call
  /// `dispose()` on it.
  static Future<ui.Image> decode(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  static Future<ui.Image> decodeFile(File file) async =>
      decode(await file.readAsBytes());

  /// Writes the region of [source] described by [normalizedCrop] to a new PNG
  /// in the temp directory and returns it.
  ///
  /// [normalizedCrop] is expressed in 0..1 image coordinates so it survives
  /// layout changes and can be handed straight back to the crop screen as its
  /// starting rectangle.
  ///
  /// Returns [source] unchanged when the rectangle covers (almost) the whole
  /// image, avoiding a pointless re-encode.
  static Future<File> cropToFile({
    required File source,
    required ui.Rect normalizedCrop,
  }) async {
    if (_isFullFrame(normalizedCrop)) return source;

    final image = await decodeFile(source);
    try {
      // Note the explicit doubles: `double.clamp(int, int)` is statically `num`,
      // which Rect.fromLTRB will not accept.
      final maxX = image.width.toDouble();
      final maxY = image.height.toDouble();
      final srcRect = ui.Rect.fromLTRB(
        (normalizedCrop.left * maxX).clamp(0.0, maxX - 1),
        (normalizedCrop.top * maxY).clamp(0.0, maxY - 1),
        (normalizedCrop.right * maxX).clamp(1.0, maxX),
        (normalizedCrop.bottom * maxY).clamp(1.0, maxY),
      );
      final width = srcRect.width.round().clamp(1, image.width);
      final height = srcRect.height.round().clamp(1, image.height);

      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        image,
        srcRect,
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final picture = recorder.endRecording();

      final cropped = await picture.toImage(width, height);
      picture.dispose();
      try {
        final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw StateError('Could not encode the cropped image.');
        }
        final dir = await getTemporaryDirectory();
        final file = File(p.join(dir.path,
            'receipt_crop_${DateTime.now().microsecondsSinceEpoch}.png'));
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
        return file;
      } finally {
        cropped.dispose();
      }
    } finally {
      image.dispose();
    }
  }

  /// Deletes a previously generated crop, ignoring failures - it lives in the
  /// OS temp directory, so a leftover file is harmless.
  static Future<void> discard(File? file) async {
    if (file == null) return;
    if (!p.basename(file.path).startsWith('receipt_crop_')) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Nothing to do - the OS will reclaim it.
    }
  }

  static bool _isFullFrame(ui.Rect r) =>
      r.left <= 0.002 &&
      r.top <= 0.002 &&
      r.right >= 0.998 &&
      r.bottom >= 0.998;
}
