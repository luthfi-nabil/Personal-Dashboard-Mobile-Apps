import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/group_models.dart';
import '../core/group_service.dart';
import '../core/models.dart';
import '../core/money_input.dart';
import '../core/remote_api.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import 'group_plans_screen.dart' show OfflineCopyBanner;

/// Fund requests and tag balances, from the server or - offline - the copy
/// saved on the device.
final fundRequestsProvider = FutureProvider.autoDispose<FundRequests>((ref) {
  ref.watch(configProvider.select((cfg) => cfg.userId));
  return GroupService.instance.loadFundRequests();
});

bool _same(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// Request funds from a group mate, or send them some, for a purpose (a tag
/// such as "Transportation").
///
/// The money moves as a transfer between the two people's sources (Transfer
/// category, so it is not counted as spending). A *tracked* fund is
/// earmarked: the recipient's later spendings in the tag's category use it
/// up, and what is left shows as their tag balance. The group admin can
/// waive a tracked fund: what is left is dropped from the balance, the
/// spendings stay recorded, and the request is marked waived.
class GroupFundsScreen extends ConsumerWidget {
  final String groupId;
  const GroupFundsScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final data = ref.watch(appDataProvider).valueOrNull;
    final fundsAsync = ref.watch(fundRequestsProvider);
    final group = data?.groupById(groupId);
    final me = cfg.username.trim();
    final isLeader = group != null && _same(group.leader, me);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                    onPressed: () => context.pop(),
                  ),
                  Expanded(
                    child: Text(
                      group == null ? 'Fund requests' : '${group.name} · funds',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: c.ink),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: group == null || data == null
                  ? Center(
                      child: Text('This group is no longer available.',
                          style: TextStyle(color: c.muted)))
                  : fundsAsync.when(
                      loading: () => Center(
                          child: CircularProgressIndicator(color: c.accent)),
                      error: (e, _) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(e is ApiException ? e.message : '$e',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: c.muted)),
                              TextButton(
                                onPressed: () =>
                                    ref.invalidate(fundRequestsProvider),
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      data: (funds) => _Body(
                        group: group,
                        data: data,
                        funds: funds,
                        me: me,
                        isLeader: isLeader,
                        currency: cfg.currency,
                        c: c,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final SpendingGroup group;
  final AppData data;
  final FundRequests funds;
  final String me;
  final bool isLeader;
  final String currency;
  final AppColors c;

  const _Body({
    required this.group,
    required this.data,
    required this.funds,
    required this.me,
    required this.isLeader,
    required this.currency,
    required this.c,
  });

  String _name(String username) =>
      _same(username, me) ? 'You' : data.displayName(username);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = funds.of(group.id)
      ..sort((a, b) => b.createdDate.compareTo(a.createdDate));
    final forMe = all.where((r) => r.isWaiting && _same(r.payer, me)).toList();
    final mine =
        all.where((r) => r.isWaiting && _same(r.requester, me)).toList();
    final others = all.where((r) => !r.isWaiting).toList();
    final waitingOthers = all
        .where((r) =>
            r.isWaiting && !_same(r.payer, me) && !_same(r.requester, me))
        .toList();
    final balances = funds.balancesOf(group.id);

    return RefreshIndicator(
      onRefresh: () => ref.refresh(fundRequestsProvider.future),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
        children: [
          if (funds.cachedAt != null) ...[
            OfflineCopyBanner(savedAt: funds.cachedAt!, c: c),
            const SizedBox(height: 10),
          ],
          Text(
            'Ask a member for money for a purpose, or send some. Tracked '
            'funds are used up by the receiver\'s spendings in that '
            'category; ${isLeader ? 'you (admin) can' : 'the admin can'} '
            'waive what is left.',
            style: TextStyle(fontSize: 12, color: c.muted, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _create(context, ref, send: false),
                  icon: const Icon(Icons.call_received_rounded, size: 18),
                  label: const Text('Request funds'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _create(context, ref, send: true),
                  icon: const Icon(Icons.call_made_rounded, size: 18),
                  label: const Text('Send funds'),
                ),
              ),
            ],
          ),
          if (balances.isNotEmpty) ...[
            const SizedBox(height: 18),
            _Section('Tag balances', c),
            for (final b in balances)
              _Card(
                c: c,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${_name(b.username)} · ${b.tag}',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: c.ink)),
                          Text(
                            'Received ${fmtRp(b.received, currency)} · spent '
                            '${fmtRp(b.spent, currency)}'
                            '${b.waived > 0 ? ' · waived ${fmtRp(b.waived, currency)}' : ''}',
                            style: TextStyle(fontSize: 12, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                    Text(fmtRp(b.balance, currency),
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: b.balance > 0 ? c.pos : c.muted)),
                  ],
                ),
              ),
          ],
          if (forMe.isNotEmpty) ...[
            const SizedBox(height: 18),
            _Section('Waiting for you (${forMe.length})', c),
            for (final r in forMe)
              _FundTile(
                r: r,
                title: '${_name(r.requester)} asks you',
                currency: currency,
                c: c,
                onTap: () => _details(context, r),
                actions: [
                  TextButton(
                    onPressed: () => _act(context, ref,
                        () => GroupService.instance.rejectFundRequest(r),
                        done: 'Request rejected.'),
                    child: const Text('Reject'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _fulfil(context, ref, r),
                    child: const Text('Send'),
                  ),
                ],
              ),
          ],
          if (mine.isNotEmpty) ...[
            const SizedBox(height: 18),
            _Section('Your requests (${mine.length})', c),
            for (final r in mine)
              _FundTile(
                r: r,
                title: 'You asked ${_name(r.payer)}',
                currency: currency,
                c: c,
                onTap: () => _details(context, r),
                actions: [
                  TextButton(
                    onPressed: () => _act(context, ref,
                        () => GroupService.instance.cancelFundRequest(r),
                        done: 'Request withdrawn.'),
                    child: const Text('Withdraw'),
                  ),
                ],
              ),
          ],
          if (waitingOthers.isNotEmpty) ...[
            const SizedBox(height: 18),
            _Section('Waiting between members', c),
            for (final r in waitingOthers)
              _FundTile(
                r: r,
                title: '${_name(r.requester)} asks ${_name(r.payer)}',
                currency: currency,
                c: c,
                onTap: () => _details(context, r),
                actions: const [],
              ),
          ],
          const SizedBox(height: 18),
          _Section('History', c),
          if (others.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: c.surface2, borderRadius: BorderRadius.circular(12)),
              child: Text('No funds sent in this group yet.',
                  style: TextStyle(fontSize: 13, color: c.muted)),
            )
          else
            for (final r in others)
              _FundTile(
                r: r,
                title: '${_name(r.payer)} → ${_name(r.requester)}',
                currency: currency,
                c: c,
                onTap: () => _details(context, r),
                actions: [
                  if (isLeader && r.isSent && r.tracked)
                    TextButton(
                      onPressed: () => _waive(context, ref, r),
                      child: const Text('Waive'),
                    ),
                ],
              ),
        ],
      ),
    );
  }

  Future<void> _act(
      BuildContext context, WidgetRef ref, Future<void> Function() action,
      {required String done, bool movedMoney = false}) async {
    try {
      await action();
    } on ApiException catch (e) {
      if (context.mounted) _snack(context, e.message);
      return;
    }
    ref.invalidate(fundRequestsProvider);
    if (movedMoney) {
      await ref.read(appDataProvider.notifier).refreshFromServer();
    }
    if (context.mounted) _snack(context, done);
  }

  /// Tags offered: the user's own spending categories plus the group's.
  List<String> _tags() {
    final names = <String>{};
    final out = <String>[];
    for (final name in [
      for (final cat in data.categories.where((x) => x.kind == 'spending'))
        cat.name,
      for (final cat in data.groupCategoriesOf(group.id, kind: 'spending'))
        cat.name,
    ]) {
      final key = name.trim().toLowerCase();
      if (key.isEmpty || !names.add(key)) continue;
      out.add(name.trim());
    }
    out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

  Future<void> _create(BuildContext context, WidgetRef ref,
      {required bool send}) async {
    final members = data
        .membersOf(group.id)
        .where((m) => !_same(m.username, me))
        .map((m) => m.username)
        .toList();
    if (members.isEmpty) {
      _snack(context, 'Add another member to the group first.');
      return;
    }
    final draft = await showDialog<_FundDraft>(
      context: context,
      builder: (_) => _FundDialog(
        send: send,
        members: members,
        nameOf: data.displayName,
        tags: _tags(),
        sources: data.sources,
      ),
    );
    if (draft == null || !context.mounted) return;
    await _act(
      context,
      ref,
      () => send
          ? GroupService.instance.sendFunds(
              groupId: group.id,
              username: draft.username,
              amount: draft.amount,
              tag: draft.tag,
              note: draft.note,
              tracked: draft.tracked,
              fromSourceId: draft.fromSourceId!,
              toSourceId: draft.toSourceId!,
            )
          : GroupService.instance.requestFunds(
              groupId: group.id,
              username: draft.username,
              amount: draft.amount,
              tag: draft.tag,
              note: draft.note,
              tracked: draft.tracked,
              toSourceId: draft.toSourceId,
            ),
      done: send
          ? 'Sent to ${data.displayName(draft.username)}.'
          : 'Request sent to ${data.displayName(draft.username)}.',
      movedMoney: send,
    );
  }

  Future<void> _fulfil(
      BuildContext context, WidgetRef ref, GroupFundRequest r) async {
    final result = await showDialog<(String, String?)>(
      context: context,
      builder: (_) => _FulfilDialog(
        request: r,
        requesterName: data.displayName(r.requester),
        sources: data.sources,
        currency: currency,
      ),
    );
    if (result == null || !context.mounted) return;
    await _act(
      context,
      ref,
      () => GroupService.instance.fulfillFundRequest(r,
          fromSourceId: result.$1, toSourceId: result.$2),
      done: 'Sent ${fmtRp(r.amount, currency)} to '
          '${data.displayName(r.requester)}.',
      movedMoney: true,
    );
  }

  Future<void> _waive(
      BuildContext context, WidgetRef ref, GroupFundRequest r) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Waive ${r.tag} funds?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${fmtRp(r.remaining, currency)} still unspent will be dropped '
              'from ${data.displayName(r.requester)}\'s ${r.tag} balance. '
              'The transfer and their spendings stay recorded, and the '
              'request is marked waived.',
            ),
            TextField(
              controller: note,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Back')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Waive')),
        ],
      ),
    );
    final text = note.text.trim();
    note.dispose();
    if (ok != true || !context.mounted) return;
    await _act(context, ref,
        () => GroupService.instance.waiveFundRequest(r, note: text),
        done: 'Waived.');
  }

  void _details(BuildContext context, GroupFundRequest r) {
    showModalBottomSheet(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${r.tag} · ${fmtRp(r.amount, currency)}',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700, color: c.ink)),
              const SizedBox(height: 6),
              Text(
                [
                  '${_name(r.payer)} → ${_name(r.requester)}',
                  _statusLabel(r.status),
                  if (r.tracked) 'tracked',
                  if (r.fromSource != null) 'from ${r.fromSource}',
                  if (r.toSource != null) 'into ${r.toSource}',
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
              if (r.note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(r.note, style: TextStyle(color: c.ink2)),
                ),
              if (r.isWaived)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'Waived by ${_name(r.waivedBy ?? '')}'
                      '${r.waivedAt == null ? '' : ' on ${fmtDate(r.waivedAt!, 'long')}'}'
                      ' · ${fmtRp(r.waivedAmount, currency)} dropped'
                      '${(r.waiveNote ?? '').isEmpty ? '' : ' · ${r.waiveNote}'}',
                      style: TextStyle(fontSize: 12, color: c.muted)),
                ),
              if (r.hasBalance) ...[
                const SizedBox(height: 12),
                Text(
                    'Spent ${fmtRp(r.spent, currency)} · left '
                    '${fmtRp(r.remaining, currency)}',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, color: c.ink)),
                const SizedBox(height: 6),
                if (r.usage.isEmpty)
                  Text('No ${r.tag} spendings yet.',
                      style: TextStyle(fontSize: 12, color: c.muted))
                else
                  for (final u in r.usage)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${u.description.isEmpty ? r.tag : u.description} · '
                              '${fmtDate(u.date, 'long')}',
                              style: TextStyle(fontSize: 13, color: c.ink2),
                            ),
                          ),
                          Text(fmtRp(u.amount, currency),
                              style: TextStyle(fontSize: 13, color: c.neg)),
                        ],
                      ),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _statusLabel(String status) => switch (status) {
      'requested' => 'waiting',
      'sent' => 'sent',
      'waived' => 'waived',
      'rejected' => 'rejected',
      _ => 'withdrawn',
    };

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));

class _FundTile extends StatelessWidget {
  final GroupFundRequest r;
  final String title;
  final String currency;
  final AppColors c;
  final VoidCallback onTap;
  final List<Widget> actions;

  const _FundTile({
    required this.r,
    required this.title,
    required this.currency,
    required this.c,
    required this.onTap,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (r.status) {
      'requested' => ('Waiting', c.transfer),
      'sent' => ('Sent', c.pos),
      'waived' => ('Waived', c.ink2),
      'rejected' => ('Rejected', c.neg),
      _ => ('Withdrawn', c.muted),
    };
    return GestureDetector(
      onTap: onTap,
      child: _Card(
        c: c,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.ink)),
                ),
                Text(fmtRp(r.amount, currency),
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: c.ink)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _Chip(label: r.tag, color: c.accent),
                const SizedBox(width: 6),
                _Chip(label: label, color: color),
                if (r.tracked) ...[
                  const SizedBox(width: 6),
                  _Chip(label: 'Tracked', color: c.transfer),
                ],
              ],
            ),
            if (r.hasBalance || r.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                [
                  if (r.hasBalance)
                    r.isWaived
                        ? 'spent ${fmtRp(r.spent, currency)} · '
                            '${fmtRp(r.waivedAmount, currency)} waived'
                        : 'spent ${fmtRp(r.spent, currency)} · left '
                            '${fmtRp(r.remaining, currency)}',
                  if (r.note.isNotEmpty) r.note,
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ],
            if (actions.isNotEmpty)
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                for (final a in actions) ...[const SizedBox(width: 6), a],
              ]),
          ],
        ),
      ),
    );
  }
}

class _FundDraft {
  final String username;
  final double amount;
  final String tag;
  final String note;
  final bool tracked;
  final String? fromSourceId;
  final String? toSourceId;

  const _FundDraft({
    required this.username,
    required this.amount,
    required this.tag,
    required this.note,
    required this.tracked,
    this.fromSourceId,
    this.toSourceId,
  });
}

/// Request funds from a member (money lands in one of your sources) or send
/// funds to one (from your source into one of theirs).
class _FundDialog extends StatefulWidget {
  final bool send;
  final List<String> members;
  final String Function(String) nameOf;
  final List<String> tags;
  final List<Source> sources;

  const _FundDialog({
    required this.send,
    required this.members,
    required this.nameOf,
    required this.tags,
    required this.sources,
  });

  @override
  State<_FundDialog> createState() => _FundDialogState();
}

class _FundDialogState extends State<_FundDialog> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _customTag = TextEditingController();
  String? _member;
  String? _tag;
  bool _tracked = true;
  String? _mySource;
  String? _theirSource;
  List<MemberSource>? _theirSources;
  String? _loadError;

  static const _otherTag = '__other';

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _customTag.dispose();
    super.dispose();
  }

  Future<void> _pickMember(String? username) async {
    setState(() {
      _member = username;
      _theirSource = null;
      _theirSources = null;
      _loadError = null;
    });
    if (username == null || !widget.send) return;
    try {
      final list = await GroupService.instance.memberSources(username);
      if (mounted && _member == username) setState(() => _theirSources = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  String get _tagValue =>
      _tag == _otherTag ? _customTag.text.trim() : (_tag ?? '');

  @override
  Widget build(BuildContext context) {
    final amount = parseMoney(_amount.text);
    final valid = _member != null &&
        amount != null &&
        amount > 0 &&
        _tagValue.isNotEmpty &&
        (!widget.send || (_mySource != null && _theirSource != null));
    return AlertDialog(
      title: Text(widget.send ? 'Send funds' : 'Request funds'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _member,
              isExpanded: true,
              decoration:
                  InputDecoration(labelText: widget.send ? 'Send to' : 'Ask'),
              items: [
                for (final m in widget.members)
                  DropdownMenuItem(value: m, child: Text(widget.nameOf(m))),
              ],
              onChanged: _pickMember,
            ),
            TextField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: moneyInputFormatters,
              decoration: const InputDecoration(labelText: 'Amount'),
              onChanged: (_) => setState(() {}),
            ),
            DropdownButtonFormField<String>(
              initialValue: _tag,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Tag (what it is for)',
                  helperText: 'A spending category, e.g. Transportation'),
              items: [
                for (final t in widget.tags)
                  DropdownMenuItem(value: t, child: Text(t)),
                const DropdownMenuItem(value: _otherTag, child: Text('Other…')),
              ],
              onChanged: (v) => setState(() => _tag = v),
            ),
            if (_tag == _otherTag)
              TextField(
                controller: _customTag,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Tag name'),
                onChanged: (_) => setState(() {}),
              ),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            if (widget.send) ...[
              DropdownButtonFormField<String>(
                initialValue: _mySource,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'From (yours)'),
                items: [
                  for (final s in widget.sources)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _mySource = v),
              ),
              if (_member != null)
                _loadError != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_loadError!,
                            style: const TextStyle(color: Colors.red)))
                    : _theirSources == null
                        ? const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: LinearProgressIndicator(),
                          )
                        : DropdownButtonFormField<String>(
                            initialValue: _theirSource,
                            isExpanded: true,
                            decoration: InputDecoration(
                                labelText:
                                    'Into ${widget.nameOf(_member!)}\'s source'),
                            items: [
                              for (final s in _theirSources!)
                                DropdownMenuItem(
                                    value: s.id, child: Text(s.name)),
                            ],
                            onChanged: (v) => setState(() => _theirSource = v),
                          ),
            ] else
              DropdownButtonFormField<String>(
                initialValue: _mySource,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Receive into (optional)',
                    helperText: 'Left empty, the sender picks your source'),
                items: [
                  for (final s in widget.sources)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _mySource = v),
              ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _tracked,
              onChanged: (v) => setState(() => _tracked = v),
              title: const Text('Track spending'),
              subtitle: Text(
                  'The receiver\'s ${_tagValue.isEmpty ? 'tag' : _tagValue} '
                  'spendings use it up; not counted as spending itself.',
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: valid
              ? () => Navigator.pop(
                    context,
                    _FundDraft(
                      username: _member!,
                      amount: amount,
                      tag: _tagValue,
                      note: _note.text.trim(),
                      tracked: _tracked,
                      fromSourceId: widget.send ? _mySource : null,
                      toSourceId: widget.send ? _theirSource : _mySource,
                    ),
                  )
              : null,
          child: Text(widget.send ? 'Send' : 'Request'),
        ),
      ],
    );
  }
}

/// The payer picks their source - and, when the requester left it open,
/// which of the requester's sources receives it.
class _FulfilDialog extends StatefulWidget {
  final GroupFundRequest request;
  final String requesterName;
  final List<Source> sources;
  final String currency;

  const _FulfilDialog({
    required this.request,
    required this.requesterName,
    required this.sources,
    required this.currency,
  });

  @override
  State<_FulfilDialog> createState() => _FulfilDialogState();
}

class _FulfilDialogState extends State<_FulfilDialog> {
  String? _from;
  String? _to;
  List<MemberSource>? _theirs;
  String? _error;

  bool get _needsDestination => widget.request.toSourceId == null;

  @override
  void initState() {
    super.initState();
    if (_needsDestination) {
      GroupService.instance.memberSources(widget.request.requester).then(
          (list) {
        if (mounted) setState(() => _theirs = list);
      }, onError: (e) {
        if (mounted) {
          setState(() => _error = e is ApiException ? e.message : '$e');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final valid = _from != null && (!_needsDestination || _to != null);
    return AlertDialog(
      title: Text('Send ${fmtRp(r.amount, widget.currency)}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'To ${widget.requesterName} for ${r.tag}'
            '${r.note.isEmpty ? '' : ' - ${r.note}'}'
            '${r.tracked ? '. Tracked: their ${r.tag} spendings use it up.' : '.'}',
            style: const TextStyle(fontSize: 13),
          ),
          DropdownButtonFormField<String>(
            initialValue: _from,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'From (yours)'),
            items: [
              for (final s in widget.sources)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (v) => setState(() => _from = v),
          ),
          if (!_needsDestination)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Into their ${r.toSource ?? 'source'}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            )
          else if (_theirs == null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: _to,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: 'Into ${widget.requesterName}\'s source'),
              items: [
                for (final s in _theirs!)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _to = v),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: valid ? () => Navigator.pop(context, (_from!, _to)) : null,
          child: const Text('Send'),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final AppColors c;
  final Widget child;
  const _Card({required this.c, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: child,
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  final AppColors c;
  const _Section(this.text, this.c);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: c.ink)),
      );
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
