import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import 'ocr_layout.dart';
import 'receipt_parser.dart';

export 'receipt_parser.dart' show ScannedItem, ReceiptScanResult;

/// Thrown when a photo could be taken but no usable text came out of it.
class ReceiptScanException implements Exception {
  final String message;
  const ReceiptScanException(this.message);

  @override
  String toString() => message;
}

/// Reads a printed price list / receipt with on-device OCR (Google ML Kit) and
/// hands the recognised rows to [ReceiptParser] for interpretation.
///
/// Everything runs locally - no image ever leaves the phone and no API key is
/// needed. ML Kit's text recogniser only ships for Android and iOS, so
/// [isSupported] gates the feature on other platforms.
class ReceiptScanner {
  ReceiptScanner();

  static final ImagePicker _picker = ImagePicker();
  TextRecognizer? _recognizer;

  /// ML Kit text recognition is Android/iOS only. Desktop and web builds fall
  /// back to entering the line items by hand.
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Opens the camera (or gallery when [fromGallery] is true) and returns the
  /// captured file, or `null` when the user backs out without taking a photo.
  ///
  /// Picking is deliberately separate from [scanFile] so the crop step can sit
  /// between them, and so the same photo can be re-cropped and re-read without
  /// asking the user to shoot it again.
  Future<File?> pickImage({bool fromGallery = false}) async {
    if (!isSupported) {
      throw const ReceiptScanException(
          'Receipt scanning needs Android or iOS. Add the items manually here.');
    }

    final photo = await _picker.pickImage(
      source: fromGallery ? ImageSource.gallery : ImageSource.camera,
      // Full resolution matters: downscaling makes small receipt print
      // unreadable, which is the single biggest cause of empty results.
      // Passing imageQuality also makes image_picker re-encode the file, which
      // bakes EXIF rotation into the pixels so the crop overlay and ML Kit
      // agree on which way is up.
      imageQuality: 100,
    );
    return photo == null ? null : File(photo.path);
  }

  /// Runs OCR over an already-captured image.
  Future<ReceiptScanResult> scanFile(File file) async {
    final recognizer =
        _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);

    final RecognizedText recognized;
    try {
      recognized = await recognizer.processImage(InputImage.fromFile(file));
    } catch (e) {
      throw ReceiptScanException('Could not read the image: $e');
    }

    if (recognized.text.trim().isEmpty) {
      throw const ReceiptScanException(
          'No text found. Try again with more light and the receipt flat in frame.');
    }

    // Rebuild reading order from the line geometry. ML Kit's own
    // `recognized.text` walks whole blocks, and on a receipt the item names are
    // one block and the prices another - so it reads each column top-to-bottom
    // and nothing lines up. See OcrLayout for the details.
    final fragments = <OcrFragment>[
      for (final block in recognized.blocks)
        for (final line in block.lines)
          OcrFragment(text: line.text, box: line.boundingBox),
    ];

    final rowMajor = OcrLayout.toRowMajorText(fragments).trim();

    // If the platform gave us no usable boxes, fall back to block order rather
    // than returning nothing.
    final text = rowMajor.isEmpty ? recognized.text.trim() : rowMajor;

    return ReceiptParser.parse(text);
  }

  /// Releases the native recogniser. Call from the owning widget's `dispose`.
  Future<void> dispose() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}
