import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'config.dart';
import 'db.dart';
import 'models.dart';
import 'remote_api.dart';
import 'sync.dart';

/// What a proof is attached to. The string values are transaction-api's
/// `ref_type`.
enum ProofRef {
  spending('spending'),
  earning('earning'),
  reimbursement('reimbursement'),
  splitPayment('split_payment');

  final String value;
  const ProofRef(this.value);

  /// A spending or an earning. A transfer's proof goes on its spending half.
  static ProofRef forTransactionType(String type) =>
      type == 'earning' ? ProofRef.earning : ProofRef.spending;
}

/// A picture proving a transaction or a group settlement happened.
class Proof {
  final String id;
  final String refType;
  final String refId;
  final String uploadedBy;
  final int sizeBytes;
  final String createdDate;

  const Proof({
    required this.id,
    required this.refType,
    required this.refId,
    required this.uploadedBy,
    required this.sizeBytes,
    required this.createdDate,
  });

  factory Proof.fromApi(Map<String, dynamic> m) => Proof(
        id: '${m['proof_id'] ?? ''}',
        refType: '${m['ref_type'] ?? ''}',
        refId: '${m['ref_id'] ?? ''}',
        uploadedBy: '${m['uploaded_by'] ?? ''}',
        sizeBytes: (m['size_bytes'] as num?)?.toInt() ?? 0,
        createdDate: '${m['created_date'] ?? ''}',
      );
}

/// Longest side of an uploaded proof, in pixels. Enough to read a transfer
/// receipt or a printed bill.
const proofMaxSide = 1600;

/// Proofs above this are re-encoded at lower quality.
const proofTargetBytes = 400 * 1024;

/// Decodes any picture (JPEG, PNG, WebP, HEIC as delivered by the picker…),
/// bakes in its EXIF rotation, scales it down to [proofMaxSide] and
/// re-encodes it as JPEG - lowering the quality until it fits
/// [proofTargetBytes]. Throws [FormatException] for something that is not
/// an image.
Uint8List compressProofImage(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // The decoders throw range errors on truncated or foreign data.
    decoded = null;
  }
  if (decoded == null) {
    throw const FormatException('That file is not an image.');
  }
  var image = img.bakeOrientation(decoded);
  final longest = image.width > image.height ? image.width : image.height;
  if (longest > proofMaxSide) {
    image = image.width >= image.height
        ? img.copyResize(image,
            width: proofMaxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image,
            height: proofMaxSide, interpolation: img.Interpolation.average);
  }
  var quality = 80;
  var out = img.encodeJpg(image, quality: quality);
  while (out.length > proofTargetBytes && quality > 40) {
    quality -= 10;
    out = img.encodeJpg(image, quality: quality);
  }
  return out;
}

/// Proof images: picking and compressing on the device, uploading, and
/// showing them. Uploads made offline are kept in SQLite and sent by
/// [syncPending] once the device is back online (and, for a transaction
/// saved offline, once that transaction has its server id).
class ProofService {
  static final ProofService instance = ProofService._();
  ProofService._();

  static const _uuid = Uuid();
  final _picker = ImagePicker();

  /// Decoded images by proof id, so scrolling back does not download again.
  final Map<String, Uint8List> _imageCache = {};

  AppConfig get _cfg => ConfigService.instance.current;

  bool get canUseCamera =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Lets the user take or choose a picture and returns it compressed, or
  /// null when they back out.
  Future<Uint8List?> pick({required bool fromCamera}) async {
    final file = await _picker.pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      // A first cut on the platform side keeps a 50 MP photo from being
      // decoded at full size below.
      maxWidth: proofMaxSide * 2,
      maxHeight: proofMaxSide * 2,
    );
    if (file == null) return null;
    return compress(await file.readAsBytes());
  }

  /// [compressProofImage] off the UI thread.
  Future<Uint8List> compress(Uint8List bytes) =>
      compute(compressProofImage, bytes);

  Future<T> _call<T>(Future<T> Function(RemoteApi api) call) async {
    if (!SyncService.instance.isOnline) {
      throw const ApiException('You are offline. Proofs need a connection.');
    }
    try {
      return await call(RemoteApi(_cfg));
    } on ApiUnauthorizedException {
      if (!await ConfigService.instance.tryRefreshToken()) rethrow;
      return await call(RemoteApi(_cfg));
    }
  }

  Future<List<Proof>> list(ProofRef ref, String refId) => _call((api) async =>
      (await api.getProofs(ref.value, refId)).map(Proof.fromApi).toList());

  Future<Uint8List> image(String proofId) async {
    final cached = _imageCache[proofId];
    if (cached != null) return cached;
    final m = await _call((api) => api.getProof(proofId));
    final bytes = base64Decode('${m['image_base64'] ?? ''}');
    _imageCache[proofId] = bytes;
    return bytes;
  }

  /// Uploads [bytes] (already compressed) now. Throws when that fails.
  Future<Proof> upload(ProofRef ref, String refId, Uint8List bytes,
      {String? proofId}) async {
    final id = proofId ?? _uuid.v4();
    final m = await _call((api) => api.uploadProof(
          proofId: id,
          refType: ref.value,
          refId: refId,
          imageBase64: base64Encode(bytes),
        ));
    _imageCache[id] = bytes;
    return Proof.fromApi(m);
  }

  /// Uploads now when possible; otherwise keeps it for [syncPending].
  /// Returns true when it was queued rather than uploaded.
  Future<bool> uploadOrQueue(ProofRef ref, String refId, Uint8List bytes) async {
    final id = _uuid.v4();
    try {
      await upload(ref, refId, bytes, proofId: id);
      return false;
    } on ApiUnavailableException {
      // fall through to queue
    } on ApiException {
      // Offline is reported as an ApiException by [_call]; anything else
      // the server said is a real refusal.
      if (SyncService.instance.isOnline) rethrow;
    }
    await queue(ref, refId, bytes, proofId: id);
    return true;
  }

  /// Keeps a proof for a transaction still queued offline under
  /// [localTransactionId]; it is uploaded once the transaction syncs.
  Future<void> queueForLocalTransaction(
          ProofRef ref, String localTransactionId, Uint8List bytes) =>
      queue(ref, localTransactionId, bytes, isLocalRef: true);

  Future<void> queue(ProofRef ref, String refId, Uint8List bytes,
          {String? proofId, bool isLocalRef = false}) =>
      AppDb.instance.putPendingProof(
        id: proofId ?? _uuid.v4(),
        refType: ref.value,
        refId: refId,
        isLocalRef: isLocalRef,
        bytes: bytes,
        userId: _cfg.userId,
      );

  Future<void> delete(Proof proof) async {
    await _call((api) => api.deleteProof(proof.id));
    _imageCache.remove(proof.id);
  }

  /// Proofs queued for a transaction that is itself still pending.
  Future<List<PendingProof>> pendingFor(String localTransactionId) async =>
      (await AppDb.instance.getPendingProofs(_cfg.userId))
          .where((p) => p.isLocalRef && p.refId == localTransactionId)
          .toList();

  /// Uploads every queued proof whose record exists on the server. Stops at
  /// the first unreachable-server error; a proof the server refuses (its
  /// record is gone) is dropped so it cannot block the queue.
  Future<void> syncPending() async {
    final cfg = _cfg;
    final pending = await AppDb.instance.getPendingProofs(cfg.userId);
    final remote = RemoteApi(cfg);
    for (final p in pending.where((p) => !p.isLocalRef)) {
      try {
        await remote.uploadProof(
          proofId: p.id,
          refType: p.refType,
          refId: p.refId,
          imageBase64: base64Encode(p.bytes),
        );
        await AppDb.instance.deletePendingProof(p.id, cfg.userId);
      } on ApiUnavailableException {
        return;
      } on ApiUnauthorizedException {
        return;
      } on ApiException {
        await AppDb.instance.deletePendingProof(p.id, cfg.userId);
      }
    }
  }
}

/// Where a [Transaction]'s proof lives on the server: its own id, or the
/// spending half of a transfer (`spendingId_earningId`).
({ProofRef ref, String id}) proofRefOf(Transaction t) => t.type == 'transfer'
    ? (ref: ProofRef.spending, id: t.id.split('_').first)
    : (ref: ProofRef.forTransactionType(t.type), id: t.id);
