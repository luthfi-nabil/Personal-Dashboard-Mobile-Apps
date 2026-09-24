import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/group_service.dart';
import '../core/models.dart';
import '../core/remote_api.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

/// The group's own categories. Transactions added to the group are filed
/// under these instead of the member's personal categories. Everyone sees
/// them; only the group admin (leader) can add or remove one.
Future<void> showGroupCategoriesSheet(
    BuildContext context, SpendingGroup group,
    {required bool isLeader}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _GroupCategoriesSheet(group: group, isLeader: isLeader),
  );
}

class _GroupCategoriesSheet extends ConsumerStatefulWidget {
  final SpendingGroup group;
  final bool isLeader;

  const _GroupCategoriesSheet({required this.group, required this.isLeader});

  @override
  ConsumerState<_GroupCategoriesSheet> createState() =>
      _GroupCategoriesSheetState();
}

class _GroupCategoriesSheetState extends ConsumerState<_GroupCategoriesSheet> {
  final _name = TextEditingController();
  String _kind = 'spending';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      // Categories come with the app data, like the rest of the group.
      await ref.read(appDataProvider.notifier).refreshFromServer();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    await _guard(
      () => GroupService.instance
          .saveCategory(groupId: widget.group.id, name: name, kind: _kind),
      'Added "$name".',
    );
    if (mounted) _name.clear();
  }

  Future<void> _remove(GroupCategory category) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove "${category.name}"?'),
        content: const Text('Transactions already filed under it keep the '
            'name. It can no longer be picked for new ones.'),
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
    await _guard(() => GroupService.instance.deleteCategory(category),
        'Removed "${category.name}".');
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final data = ref.watch(appDataProvider).valueOrNull;
    final categories =
        data?.groupCategoriesOf(widget.group.id) ?? const <GroupCategory>[];

    Widget section(String kind, String title) {
      final items = categories.where((cat) => cat.kind == kind).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(title,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: c.muted,
                    letterSpacing: 0.4)),
          ),
          if (items.isEmpty)
            Text('None yet.', style: TextStyle(fontSize: 13, color: c.muted))
          else
            for (final cat in items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.label_outline_rounded,
                    size: 20, color: c.accent),
                title: Text(cat.name,
                    style: TextStyle(fontSize: 14, color: c.ink)),
                trailing: widget.isLeader
                    ? IconButton(
                        tooltip: 'Remove',
                        icon: Icon(Icons.close_rounded,
                            size: 18, color: c.muted),
                        onPressed: _busy ? null : () => _remove(cat),
                      )
                    : null,
              ),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${widget.group.name} · categories',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: c.ink)),
            const SizedBox(height: 4),
            Text(
              widget.isLeader
                  ? 'Transactions added to this group use these categories. '
                      'Only you, as admin, can change them.'
                  : 'Transactions added to this group use these categories. '
                      'Only the group admin can change them.',
              style: TextStyle(fontSize: 12, color: c.muted, height: 1.4),
            ),
            section('spending', 'SPENDING'),
            section('earning', 'EARNING'),
            if (widget.isLeader) ...[
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'spending', label: Text('Spending')),
                  ButtonSegment(value: 'earning', label: Text('Earning')),
                ],
                selected: {_kind},
                onSelectionChanged: (v) => setState(() => _kind = v.first),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _name,
                      enabled: !_busy,
                      textCapitalization: TextCapitalization.sentences,
                      decoration:
                          const InputDecoration(labelText: 'New category'),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _add,
                    child: const Text('Add'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
