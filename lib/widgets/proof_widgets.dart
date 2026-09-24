import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/proof_service.dart';
import '../core/remote_api.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

/// Proofs of one record, fetched live. Keyed by (ref type, ref id).
final proofsProvider = FutureProvider.autoDispose
    .family<List<Proof>, (ProofRef, String)>((ref, key) {
  ref.watch(configProvider.select((cfg) => cfg.userId));
  return ProofService.instance.list(key.$1, key.$2);
});

/// One proof's image. [ProofService] caches it, so this stays cheap.
final proofImageProvider =
    FutureProvider.autoDispose.family<Uint8List, String>(
        (ref, proofId) => ProofService.instance.image(proofId));

/// Asks camera or gallery, then returns the picture compressed - or null
/// when the user backs out. Errors are shown as a snackbar.
Future<Uint8List?> pickProofImage(BuildContext context) async {
  final service = ProofService.instance;
  final fromCamera = service.canUseCamera
      ? await showModalBottomSheet<bool>(
          context: context,
          showDragHandle: true,
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a photo'),
                  onTap: () => Navigator.pop(sheetContext, true),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose from gallery'),
                  onTap: () => Navigator.pop(sheetContext, false),
                ),
              ],
            ),
          ),
        )
      : false;
  if (fromCamera == null) return null;
  try {
    return await service.pick(fromCamera: fromCamera);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e is FormatException
              ? e.message
              : 'Could not read that picture.')));
    }
    return null;
  }
}

/// Full-screen, zoomable view of a proof.
Future<void> showProofViewer(
  BuildContext context, {
  Uint8List? bytes,
  String? proofId,
  String? caption,
  Future<void> Function()? onDelete,
}) {
  return Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _ProofViewer(
        bytes: bytes, proofId: proofId, caption: caption, onDelete: onDelete),
  ));
}

class _ProofViewer extends ConsumerWidget {
  final Uint8List? bytes;
  final String? proofId;
  final String? caption;
  final Future<void> Function()? onDelete;

  const _ProofViewer(
      {this.bytes, this.proofId, this.caption, this.onDelete});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = bytes != null
        ? AsyncValue.data(bytes!)
        : ref.watch(proofImageProvider(proofId!));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(caption ?? 'Proof', style: const TextStyle(fontSize: 16)),
        actions: [
          if (onDelete != null)
            IconButton(
              tooltip: 'Remove proof',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Remove this proof?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Remove')),
                    ],
                  ),
                );
                if (ok != true) return;
                await onDelete!();
                if (context.mounted) Navigator.pop(context);
              },
            ),
        ],
      ),
      body: image.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.white)),
        error: (e, _) => Center(
          child: Text(e is ApiException ? e.message : 'Could not load it.',
              style: const TextStyle(color: Colors.white70)),
        ),
        data: (data) => InteractiveViewer(
          maxScale: 6,
          child: Center(child: Image.memory(data, gaplessPlayback: true)),
        ),
      ),
    );
  }
}

/// A proof picked for a record that is not saved yet: an "Attach proof"
/// button, or the picture with remove. The picture is already compressed.
class ProofPickerField extends StatefulWidget {
  final Uint8List? image;
  final ValueChanged<Uint8List?> onChanged;
  final String label;
  final String? hint;

  const ProofPickerField({
    super.key,
    required this.image,
    required this.onChanged,
    this.label = 'Proof (optional)',
    this.hint,
  });

  @override
  State<ProofPickerField> createState() => _ProofPickerFieldState();
}

class _ProofPickerFieldState extends State<ProofPickerField> {
  bool _busy = false;

  Future<void> _pick() async {
    setState(() => _busy = true);
    final picked = await pickProofImage(context);
    if (!mounted) return;
    setState(() => _busy = false);
    if (picked != null) widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final image = widget.image;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: [
          if (image != null)
            GestureDetector(
              onTap: () => showProofViewer(context, bytes: image),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(image,
                    width: 56, height: 56, fit: BoxFit.cover),
              ),
            )
          else
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _busy
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: c.accent),
                    )
                  : Icon(Icons.receipt_long_outlined, color: c.muted),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.label,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink)),
                const SizedBox(height: 2),
                Text(
                  image != null
                      ? 'Attached · ${_kb(image.length)}. Tap to view.'
                      : widget.hint ??
                          'A photo of the transfer receipt or the bill.',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ],
            ),
          ),
          if (image != null)
            IconButton(
              tooltip: 'Remove',
              icon: Icon(Icons.close_rounded, color: c.muted),
              onPressed: () => widget.onChanged(null),
            )
          else
            TextButton(
              onPressed: _busy ? null : _pick,
              child: const Text('Attach'),
            ),
        ],
      ),
    );
  }
}

String _kb(int bytes) => '${(bytes / 1024).round()} kB';

/// Proofs attached to a saved record, as thumbnails. With [canAdd] the user
/// can attach more; they can remove the ones they uploaded.
class ProofGallery extends ConsumerStatefulWidget {
  final ProofRef proofRef;
  final String refId;
  final bool canAdd;
  final String title;

  const ProofGallery({
    super.key,
    required this.proofRef,
    required this.refId,
    this.canAdd = false,
    this.title = 'Proof',
  });

  @override
  ConsumerState<ProofGallery> createState() => _ProofGalleryState();
}

class _ProofGalleryState extends ConsumerState<ProofGallery> {
  bool _uploading = false;

  (ProofRef, String) get _key => (widget.proofRef, widget.refId);

  Future<void> _add() async {
    final picked = await pickProofImage(context);
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      await ProofService.instance.upload(widget.proofRef, widget.refId, picked);
      ref.invalidate(proofsProvider(_key));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final me = ref.watch(configProvider.select((cfg) => cfg.username.trim()));
    final proofs = ref.watch(proofsProvider(_key));

    final Widget content = proofs.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(color: c.accent),
      ),
      error: (e, _) => Row(
        children: [
          Expanded(
            child: Text(e is ApiException ? e.message : 'Could not load proofs.',
                style: TextStyle(fontSize: 12, color: c.muted)),
          ),
          TextButton(
              onPressed: () => ref.invalidate(proofsProvider(_key)),
              child: const Text('Retry')),
        ],
      ),
      data: (items) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in items)
            _Thumb(
              proof: p,
              c: c,
              onTap: () => showProofViewer(
                context,
                proofId: p.id,
                caption: '${p.uploadedBy == me ? 'You' : p.uploadedBy} · '
                    '${fmtDate(p.createdDate, 'long')}',
                onDelete: p.uploadedBy.toLowerCase() == me.toLowerCase()
                    ? () async {
                        try {
                          await ProofService.instance.delete(p);
                        } on ApiException catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.message)));
                          }
                          return;
                        }
                        ref.invalidate(proofsProvider(_key));
                      }
                    : null,
              ),
            ),
          if (widget.canAdd)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _uploading ? null : _add,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.line2),
                ),
                child: _uploading
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: c.accent),
                      )
                    : Icon(Icons.add_a_photo_outlined, color: c.accent),
              ),
            ),
          if (items.isEmpty && !widget.canAdd)
            Text('No proof attached.',
                style: TextStyle(fontSize: 12, color: c.muted)),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: c.ink)),
          const SizedBox(height: 10),
          content,
        ],
      ),
    );
  }
}

class _Thumb extends ConsumerWidget {
  final Proof proof;
  final AppColors c;
  final VoidCallback onTap;

  const _Thumb({required this.proof, required this.c, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = ref.watch(proofImageProvider(proof.id));
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 64,
          height: 64,
          child: image.when(
            loading: () => Container(color: c.surface2),
            error: (_, __) => Container(
                color: c.surface2,
                child: Icon(Icons.broken_image_outlined, color: c.muted)),
            data: (bytes) => Image.memory(bytes,
                fit: BoxFit.cover, cacheWidth: 192, gaplessPlayback: true),
          ),
        ),
      ),
    );
  }
}

/// [ProofGallery] in a bottom sheet - for rows (a reimbursement, a split
/// payment) where loading every proof up front would be wasteful.
Future<void> showProofSheet(
  BuildContext context, {
  required ProofRef proofRef,
  required String refId,
  required bool canAdd,
  String title = 'Proof of transfer',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ProofGallery(
            proofRef: proofRef, refId: refId, canAdd: canAdd, title: title),
      ),
    ),
  );
}

/// Proofs picked for a transaction that is still queued offline. They are
/// uploaded once it syncs.
class PendingProofStrip extends StatelessWidget {
  final String localTransactionId;
  const PendingProofStrip({super.key, required this.localTransactionId});

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    return FutureBuilder(
      future: ProofService.instance.pendingFor(localTransactionId),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        if (items.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.line2, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Proof',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: c.ink)),
              const SizedBox(height: 4),
              Text('Uploaded once this transaction syncs.',
                  style: TextStyle(fontSize: 12, color: c.muted)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final p in items)
                    GestureDetector(
                      onTap: () => showProofViewer(context, bytes: p.bytes),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(p.bytes,
                            width: 64,
                            height: 64,
                            fit: BoxFit.cover,
                            cacheWidth: 192),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
