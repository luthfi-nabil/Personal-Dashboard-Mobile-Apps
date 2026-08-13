import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/metal_price.dart';
import '../core/models.dart';
import '../core/repo.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

/// Finance > Investment: what is held rather than what is spendable.
///
/// Three kinds live here, split by how their value is kept current:
///
///  * **Reksa Dana** — no public NAB API exists in Indonesia (OJK publishes
///    monthly, brokers publish nothing), so the current NAB is typed in from
///    whatever the broker app shows.
///  * **Gold** and **Silver** — refreshed from public price APIs by
///    [MetalPriceService], one tap for every holding at once.
///
/// Cost basis is never rewritten by a refresh, so the gain figures stay
/// truthful no matter how often prices are pulled.
class InvestmentScreen extends ConsumerStatefulWidget {
  const InvestmentScreen({super.key});

  @override
  ConsumerState<InvestmentScreen> createState() => _InvestmentScreenState();
}

class _InvestmentScreenState extends ConsumerState<InvestmentScreen> {
  bool _refreshing = false;

  /// Quotes from the last refresh, shown as the live price strip. Seeded from
  /// the service cache so returning to the page does not look empty.
  Map<InvestmentKind, MetalQuote> _quotes = MetalPriceService.instance.cached;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) {
        final holdings = data.investments;
        final invested =
            holdings.fold<double>(0, (sum, item) => sum + item.investedValue);
        final current =
            holdings.fold<double>(0, (sum, item) => sum + item.currentValue);

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text('Investment',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: c.ink)),
                ),
                TextButton.icon(
                  onPressed: () => _openEditor(),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Reksa dana, gold and silver. Kept apart from your sources, '
              'which hold liquid money.',
              style: TextStyle(color: c.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            _PortfolioPanel(
              invested: invested,
              current: current,
              holdingCount: holdings.length,
              currency: cfg.currency,
              c: c,
            ),
            const SizedBox(height: 12),
            _LivePriceStrip(
              quotes: _quotes,
              refreshing: _refreshing,
              onRefresh: _refreshPrices,
              c: c,
            ),
            const SizedBox(height: 20),
            for (final kind in InvestmentKind.values) ...[
              _KindSection(
                kind: kind,
                holdings:
                    holdings.where((item) => item.kind == kind).toList(),
                currency: cfg.currency,
                c: c,
                onEdit: (item) => _openEditor(existing: item),
                onUpdatePrice: (item) => _promptUnitPrice(item),
                onRemove: (item) => _remove(item),
              ),
              const SizedBox(height: 18),
            ],
          ],
        );
      },
    );
  }

  Future<void> _openEditor({Investment? existing}) async {
    final draft = await showModalBottomSheet<_InvestmentDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _InvestmentEditorSheet(existing: existing),
    );
    if (draft == null) return;

    await Repo.instance.saveInvestment(
      id: existing?.id,
      kind: draft.kind,
      name: draft.name,
      provider: draft.provider,
      units: draft.units,
      buyUnitPrice: draft.buyUnitPrice,
      // Editing keeps the valuation that is already there; only the holding
      // itself changed. A brand-new one starts valued at what it cost.
      lastUnitPrice: existing?.lastUnitPrice,
      priceSource: existing?.priceSource ?? '',
      priceUpdatedAt: existing?.priceUpdatedAt ?? '',
      notes: draft.notes,
      acquiredDate: draft.acquiredDate,
    );
    await ref.read(appDataProvider.notifier).refresh();
  }

  /// Pulls gold and silver prices and writes them onto every metal holding.
  ///
  /// A source that fails is simply skipped — the holdings it would have
  /// updated keep their stored price rather than being zeroed.
  Future<void> _refreshPrices() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);

    Map<InvestmentKind, MetalQuote> quotes = const {};
    // Pre-set so the `finally` always has something to report, whichever way
    // the block below exits.
    var message = 'Price refresh failed.';
    try {
      quotes = await MetalPriceService.instance.fetchAll(force: true);
      final data = ref.read(appDataProvider).value;
      var updated = 0;
      var failed = 0;
      for (final item in data?.investments ?? const <Investment>[]) {
        final quote = quotes[item.kind];
        if (quote == null) continue;
        try {
          await Repo.instance.updateInvestmentPrice(
            item,
            lastUnitPrice: quote.pricePerGram,
            priceSource: quote.source,
            priceUpdatedAt: quote.quotedAt.toIso8601String(),
          );
          updated++;
        } catch (_) {
          // One holding the API rejected must not abandon the rest.
          failed++;
        }
      }
      if (updated > 0) {
        await ref.read(appDataProvider.notifier).refreshCached();
      }
      message = quotes.isEmpty
          ? 'Could not reach any price source. Stored prices kept.'
          : updated == 0 && failed == 0
              ? 'Prices fetched. No gold or silver holdings to update yet.'
              : 'Updated $updated holding${updated == 1 ? '' : 's'}'
                  '${failed == 0 ? '.' : ', $failed failed.'}';
    } catch (e) {
      message = 'Price refresh failed: $e';
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          if (quotes.isNotEmpty) _quotes = {..._quotes, ...quotes};
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  /// Hand-entered valuation. This is the only way a reksa dana or "Others"
  /// holding gets revalued, and the manual override for a metal one.
  Future<void> _promptUnitPrice(Investment item) async {
    final controller = TextEditingController(
      text: item.lastUnitPrice > 0 ? _plainNumber(item.lastUnitPrice) : '',
    );
    final c = AppTheme.colorsOf(context);
    final priceLabel = switch (item.kind) {
      InvestmentKind.mutualFund => 'NAB per unit',
      InvestmentKind.gold || InvestmentKind.silver => 'Price per gram',
      InvestmentKind.others => 'Price per unit',
    };
    final blurb = switch (item.kind) {
      InvestmentKind.mutualFund =>
        'Type the NAB/unit shown in your broker app for ${item.name}.',
      InvestmentKind.gold || InvestmentKind.silver =>
        'Overrides the fetched price for ${item.name}.',
      InvestmentKind.others =>
        'Type what one unit of ${item.name} is worth now.',
    };
    final entered = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item.kind == InvestmentKind.mutualFund
            ? 'Update NAB per unit'
            : 'Update price per ${item.kind.isMetal ? 'gram' : 'unit'}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              blurb,
              style: TextStyle(color: c.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              decoration: _fieldDecoration(c, priceLabel),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(
                dialogContext, _parseNumber(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null || entered <= 0) return;

    await Repo.instance.updateInvestmentPrice(
      item,
      lastUnitPrice: entered,
      // Empty source marks it as hand-entered, so the card can say so and a
      // later automatic refresh is free to replace it.
      priceSource: '',
    );
    await ref.read(appDataProvider.notifier).refreshCached();
  }

  Future<void> _remove(Investment item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this holding?'),
        content: Text('${item.name} will be removed from your investments.'),
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
    if (confirmed != true) return;
    await Repo.instance.removeInvestment(item);
    await ref.read(appDataProvider.notifier).refreshCached();
  }
}

// ── Panels ─────────────────────────────────────────────────────────────────

class _PortfolioPanel extends StatelessWidget {
  final double invested;
  final double current;
  final int holdingCount;
  final String currency;
  final AppColors c;

  const _PortfolioPanel({
    required this.invested,
    required this.current,
    required this.holdingCount,
    required this.currency,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final gain = current - invested;
    final ratio = invested == 0 ? null : gain / invested;
    final up = gain >= 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.trending_up_rounded, color: c.accent),
              const SizedBox(width: 8),
              Text('Invested value',
                  style: TextStyle(
                      color: c.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            fmtRp(current, currency),
            style: TextStyle(
              color: c.ink,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 15,
                color: up ? c.pos : c.neg,
              ),
              const SizedBox(width: 4),
              Text(
                '${fmtRp(gain.abs(), currency)}'
                '${ratio == null ? '' : ' · ${_fmtPercent(ratio)}'}',
                style: TextStyle(
                  color: up ? c.pos : c.neg,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$holdingCount holding${holdingCount == 1 ? '' : 's'} · '
            '${fmtRp(invested, currency)} put in',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Live gold and silver prices per gram, with the refresh that writes them
/// onto every metal holding.
class _LivePriceStrip extends StatelessWidget {
  final Map<InvestmentKind, MetalQuote> quotes;
  final bool refreshing;
  final VoidCallback onRefresh;
  final AppColors c;

  const _LivePriceStrip({
    required this.quotes,
    required this.refreshing,
    required this.onRefresh,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final gold = quotes[InvestmentKind.gold];
    final silver = quotes[InvestmentKind.silver];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Live metal prices',
                    style: TextStyle(
                        color: c.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
              if (refreshing)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.accent),
                )
              else
                InkWell(
                  onTap: onRefresh,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded, size: 15, color: c.accent),
                        const SizedBox(width: 4),
                        Text('Refresh',
                            style:
                                TextStyle(color: c.accent, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _QuoteTile(label: 'Gold', quote: gold, c: c)),
              const SizedBox(width: 10),
              Expanded(child: _QuoteTile(label: 'Silver', quote: silver, c: c)),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuoteTile extends StatelessWidget {
  final String label;
  final MetalQuote? quote;
  final AppColors c;

  const _QuoteTile({required this.label, required this.quote, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label / gram',
              style: TextStyle(color: c.muted, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            quote == null ? '—' : 'Rp ${_thousands(quote!.pricePerGram)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c.ink,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            quote == null ? 'Tap refresh' : quote!.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.muted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _KindSection extends StatelessWidget {
  final InvestmentKind kind;
  final List<Investment> holdings;
  final String currency;
  final AppColors c;
  final void Function(Investment) onEdit;
  final void Function(Investment) onUpdatePrice;
  final void Function(Investment) onRemove;

  const _KindSection({
    required this.kind,
    required this.holdings,
    required this.currency,
    required this.c,
    required this.onEdit,
    required this.onUpdatePrice,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final value =
        holdings.fold<double>(0, (sum, item) => sum + item.currentValue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(_kindIcon(kind), size: 18, color: c.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${kind.label} (${holdings.length})',
                  style: TextStyle(
                      color: c.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
            if (holdings.isNotEmpty)
              Text(
                fmtRp(value, currency),
                style: TextStyle(
                  color: c.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (holdings.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.line2, width: 0.5),
            ),
            child: Text(
              switch (kind) {
                InvestmentKind.mutualFund =>
                  'No funds yet. Add one with the units and NAB from your '
                      'broker app.',
                InvestmentKind.gold =>
                  'No gold yet. Add it in grams and prices refresh from '
                      'Indonesian dealers.',
                InvestmentKind.silver =>
                  'No silver yet. Add it in grams and prices refresh from '
                      'the global spot rate.',
                InvestmentKind.others =>
                  'Nothing else yet. Crypto, bonds, stocks — anything you '
                      'price by hand goes here.',
              },
              style: TextStyle(color: c.muted, fontSize: 13, height: 1.4),
            ),
          )
        else
          ...holdings.map((item) => _HoldingCard(
                item: item,
                currency: currency,
                c: c,
                onEdit: () => onEdit(item),
                onUpdatePrice: () => onUpdatePrice(item),
                onRemove: () => onRemove(item),
              )),
      ],
    );
  }
}

class _HoldingCard extends StatelessWidget {
  final Investment item;
  final String currency;
  final AppColors c;
  final VoidCallback onEdit;
  final VoidCallback onUpdatePrice;
  final VoidCallback onRemove;

  const _HoldingCard({
    required this.item,
    required this.currency,
    required this.c,
    required this.onEdit,
    required this.onUpdatePrice,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = item.gainRatio;
    final up = item.gain >= 0;
    final priceNote = item.priceUpdatedAt.isEmpty
        ? 'no price recorded yet'
        : '${item.priceSource.isEmpty ? 'entered by hand' : item.priceSource}'
            ' · ${fmtDate(item.priceUpdatedAt, 'long')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.ink,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      '${fmtUnits(item.units)} ${item.kind.unitLabel}'
                      '${item.provider.isEmpty ? '' : ' · ${item.provider}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    fmtRp(item.currentValue, currency),
                    style: TextStyle(
                      color: c.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${up ? '+' : '−'}${fmtRp(item.gain.abs(), currency)}'
                    '${ratio == null ? '' : ' (${_fmtPercent(ratio)})'}',
                    style: TextStyle(
                      color: up ? c.pos : c.neg,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, size: 18, color: c.muted),
                onSelected: (choice) {
                  switch (choice) {
                    case 'price':
                      onUpdatePrice();
                    case 'edit':
                      onEdit();
                    default:
                      onRemove();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'price',
                    child: Text(item.kind == InvestmentKind.mutualFund
                        ? 'Update NAB'
                        : 'Set price by hand'),
                  ),
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(value: 'remove', child: Text('Remove')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Bought at',
                    value: 'Rp ${_thousands(item.buyUnitPrice)}',
                    c: c,
                  ),
                ),
                Expanded(
                  child: _MiniStat(
                    label: 'Now',
                    value: item.lastUnitPrice > 0
                        ? 'Rp ${_thousands(item.lastUnitPrice)}'
                        : '—',
                    c: c,
                  ),
                ),
                Expanded(
                  child: _MiniStat(label: 'Price', value: priceNote, c: c),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final AppColors c;

  const _MiniStat({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: c.muted, fontSize: 10)),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: c.ink2, fontSize: 11.5),
        ),
      ],
    );
  }
}

// ── Editor ─────────────────────────────────────────────────────────────────

class _InvestmentDraft {
  final InvestmentKind kind;
  final String name;
  final String provider;
  final double units;
  final double buyUnitPrice;
  final String notes;
  final String acquiredDate;

  const _InvestmentDraft({
    required this.kind,
    required this.name,
    required this.provider,
    required this.units,
    required this.buyUnitPrice,
    required this.notes,
    required this.acquiredDate,
  });
}

class _InvestmentEditorSheet extends StatefulWidget {
  final Investment? existing;

  const _InvestmentEditorSheet({this.existing});

  @override
  State<_InvestmentEditorSheet> createState() => _InvestmentEditorSheetState();
}

class _InvestmentEditorSheetState extends State<_InvestmentEditorSheet> {
  late InvestmentKind _kind;
  late final TextEditingController _nameCtl;
  late final TextEditingController _providerCtl;
  late final TextEditingController _unitsCtl;
  late final TextEditingController _priceCtl;
  late final TextEditingController _notesCtl;
  late DateTime _acquired;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _kind = existing?.kind ?? InvestmentKind.mutualFund;
    _nameCtl = TextEditingController(text: existing?.name ?? '');
    _providerCtl = TextEditingController(text: existing?.provider ?? '');
    _unitsCtl = TextEditingController(
        text: existing == null ? '' : _plainNumber(existing.units));
    _priceCtl = TextEditingController(
        text: existing == null ? '' : _plainNumber(existing.buyUnitPrice));
    _notesCtl = TextEditingController(text: existing?.notes ?? '');
    _acquired = DateTime.tryParse(existing?.acquiredDate ?? '') ??
        DateTime.now();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _providerCtl.dispose();
    _unitsCtl.dispose();
    _priceCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give the holding a name.')),
      );
      return;
    }
    final units = _parseNumber(_unitsCtl.text) ?? 0;
    if (units <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_kind.isMetal
              ? 'How many grams do you hold?'
              : 'How many units do you hold?'),
        ),
      );
      return;
    }

    Navigator.pop(
      context,
      _InvestmentDraft(
        kind: _kind,
        name: name,
        provider: _providerCtl.text.trim(),
        units: units,
        buyUnitPrice: _parseNumber(_priceCtl.text) ?? 0,
        notes: _notesCtl.text.trim(),
        acquiredDate: _acquired.toIso8601String(),
      ),
    );
  }

  Future<void> _pickAcquired() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _acquired.isAfter(now) ? now : _acquired,
      firstDate: DateTime(now.year - 30),
      lastDate: now,
      helpText: 'When did you buy it?',
    );
    if (picked != null) setState(() => _acquired = picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final editing = widget.existing != null;
    final isFund = _kind == InvestmentKind.mutualFund;
    final isMetal = _kind.isMetal;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(editing ? 'Edit holding' : 'Add investment',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: c.ink)),
              const SizedBox(height: 14),
              // Chips rather than a SegmentedButton: four labels no longer fit
              // on one row on a phone, and these wrap instead of clipping.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final kind in InvestmentKind.values)
                    ChoiceChip(
                      selected: _kind == kind,
                      onSelected: (_) => setState(() => _kind = kind),
                      showCheckmark: false,
                      avatar: Icon(_kindIcon(kind),
                          size: 16, color: _kind == kind ? c.bg : c.muted),
                      label: Text(kind.label,
                          style: TextStyle(
                              fontSize: 12,
                              color: _kind == kind ? c.bg : c.ink)),
                      backgroundColor: c.surface,
                      selectedColor: c.ink,
                      side: BorderSide(color: c.line2, width: 0.5),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameCtl,
                autofocus: !editing,
                style: TextStyle(fontSize: 15, color: c.ink),
                decoration: _fieldDecoration(
                    c,
                    isFund
                        ? 'Fund name'
                        : isMetal
                            ? 'Label (e.g. Antam 1gr bar)'
                            : 'Label (e.g. Bitcoin, ORI023)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _providerCtl,
                style: TextStyle(fontSize: 15, color: c.ink),
                decoration: _fieldDecoration(
                    c,
                    isFund
                        ? 'Platform (Bibit, Bareksa…)'
                        : isMetal
                            ? 'Where it is kept (optional)'
                            : 'Where it is held (optional)'),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _unitsCtl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
                      ],
                      style: TextStyle(fontSize: 15, color: c.ink),
                      decoration: _fieldDecoration(
                          c, isMetal ? 'Grams owned' : 'Units owned'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _priceCtl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
                      ],
                      style: TextStyle(fontSize: 15, color: c.ink),
                      decoration: _fieldDecoration(
                          c,
                          isFund
                              ? 'Buy NAB / unit'
                              : isMetal
                                  ? 'Buy price / gram'
                                  : 'Buy price / unit'),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 2),
                child: Text(
                  isFund
                      ? 'The buy NAB is your cost basis and never changes. '
                          'Update the current NAB from the card menu.'
                      : isMetal
                          ? 'The buy price is your cost basis. Current prices '
                              'come from Refresh on the page.'
                          : 'The buy price is your cost basis and never '
                              'changes. Set what it is worth now from the '
                              'card menu.',
                  style: TextStyle(color: c.muted, fontSize: 11, height: 1.4),
                ),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: _pickAcquired,
                borderRadius: BorderRadius.circular(12),
                child: InputDecorator(
                  decoration: _fieldDecoration(c, 'Bought on'),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          fmtDate(_acquired.toIso8601String(), 'long'),
                          style: TextStyle(fontSize: 15, color: c.ink),
                        ),
                      ),
                      Icon(Icons.calendar_today_rounded,
                          size: 16, color: c.muted),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _notesCtl,
                style: TextStyle(fontSize: 15, color: c.ink),
                decoration: _fieldDecoration(c, 'Notes (optional)'),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.ink,
                    foregroundColor: c.bg,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(editing ? 'Save changes' : 'Add holding',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────

IconData _kindIcon(InvestmentKind kind) => switch (kind) {
      InvestmentKind.mutualFund => Icons.pie_chart_outline_rounded,
      InvestmentKind.gold => Icons.workspace_premium_outlined,
      InvestmentKind.silver => Icons.circle_outlined,
      InvestmentKind.others => Icons.category_outlined,
    };

/// Accepts both `1.234,56` and `1234.56`, since the app is used in a locale
/// that writes thousands with dots.
double? _parseNumber(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (text.contains(',')) {
    // Comma present means it is the decimal separator; dots are grouping.
    text = text.replaceAll('.', '').replaceAll(',', '.');
  }
  return double.tryParse(text);
}

/// Round-trips a stored number back into a field without locale decoration.
String _plainNumber(double value) {
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toString();
}

/// Rupiah amount with dot grouping, keeping two decimals for the small
/// per-unit prices reksa dana quotes.
///
/// Above 10.000 the decimals are noise (gold runs to millions per gram); below
/// it they are the whole point, since a NAB of 1.234,5678 moves in cents.
String _thousands(double value) {
  if (value <= 0) return '0';
  final rounded = value >= 10000 ? value.roundToDouble() : value;
  final whole = rounded.truncate();
  final digits = whole.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  final fraction = rounded - whole;
  if (fraction > 0) {
    buf.write(',');
    buf.write((fraction * 100).round().toString().padLeft(2, '0'));
  }
  return buf.toString();
}

String _fmtPercent(double ratio) {
  final pct = ratio * 100;
  final sign = pct >= 0 ? '+' : '−';
  return '$sign${pct.abs().toStringAsFixed(pct.abs() >= 10 ? 1 : 2)}%';
}

InputDecoration _fieldDecoration(AppColors c, String label) => InputDecoration(
      labelText: label,
      filled: true,
      fillColor: c.surface,
      labelStyle: TextStyle(color: c.muted, fontSize: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.line, width: 0.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.line, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.accent, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    );
