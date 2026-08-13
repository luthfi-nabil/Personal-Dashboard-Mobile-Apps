import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/export_report.dart';
import '../core/export_service.dart';
import '../core/models.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

/// Pick any set of months (across years) and export them as Excel or Word.
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  final Set<String> _selected = {};
  ExportFormat _format = ExportFormat.xlsx;
  bool _busy = false;
  bool _initialized = false;

  String get _thisMonth {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  void _selectRecent(List<String> available, int count) {
    setState(() {
      _selected
        ..clear()
        ..addAll(available.take(count));
    });
  }

  void _selectYear(List<String> available, String year) {
    final inYear = available.where((m) => m.startsWith('$year-')).toList();
    final allSelected = inYear.every(_selected.contains);
    setState(() {
      if (allSelected) {
        _selected.removeAll(inYear);
      } else {
        _selected.addAll(inYear);
      }
    });
  }

  Future<void> _export(AppData data) async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await ExportService.instance.exportFinance(
        data: data,
        months: _selected,
        format: _format,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final cfg = ref.watch(configProvider);
    final dataAsync = ref.watch(appDataProvider);

    return dataAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: c.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (data) {
        final available = ExportReport.availableMonths(data);
        if (!_initialized) {
          _initialized = true;
          _selected.add(available.contains(_thisMonth) ? _thisMonth : available.first);
        }

        final years = <String, List<String>>{};
        for (final m in available) {
          (years[m.substring(0, 4)] ??= []).add(m);
        }
        final yearKeys = years.keys.toList()..sort((a, b) => b.compareTo(a));

        final preview = _selected.isEmpty
            ? null
            : ExportReport.build(data, _selected);

        return Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
              children: [
                const SizedBox(height: 14),
                Text('Export',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: c.ink,
                        letterSpacing: -0.02)),
                const SizedBox(height: 4),
                Text('Pick the months to recap, then choose a file format.',
                    style: TextStyle(fontSize: 13, color: c.muted)),
                const SizedBox(height: 18),

                // ── Format ────────────────────────────────────────────────
                _SectionTitle('Format', c),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _FormatCard(
                        c: c,
                        icon: Icons.grid_on_rounded,
                        title: 'Excel',
                        subtitle: '.xlsx · 4 sheets',
                        selected: _format == ExportFormat.xlsx,
                        onTap: () =>
                            setState(() => _format = ExportFormat.xlsx),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _FormatCard(
                        c: c,
                        icon: Icons.description_outlined,
                        title: 'Word',
                        subtitle: '.docx · report',
                        selected: _format == ExportFormat.docx,
                        onTap: () =>
                            setState(() => _format = ExportFormat.docx),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ── Quick ranges ──────────────────────────────────────────
                _SectionTitle('Quick select', c),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Chip(
                        label: 'This month',
                        c: c,
                        onTap: () => setState(() {
                              _selected
                                ..clear()
                                ..add(available.contains(_thisMonth)
                                    ? _thisMonth
                                    : available.first);
                            })),
                    _Chip(
                        label: 'Last 3',
                        c: c,
                        onTap: () => _selectRecent(available, 3)),
                    _Chip(
                        label: 'Last 6',
                        c: c,
                        onTap: () => _selectRecent(available, 6)),
                    _Chip(
                        label: 'Last 12',
                        c: c,
                        onTap: () => _selectRecent(available, 12)),
                    _Chip(
                        label: 'All',
                        c: c,
                        onTap: () => setState(() {
                              _selected
                                ..clear()
                                ..addAll(available);
                            })),
                    _Chip(
                        label: 'Clear',
                        c: c,
                        onTap: () => setState(_selected.clear)),
                  ],
                ),
                const SizedBox(height: 20),

                // ── Months by year ────────────────────────────────────────
                _SectionTitle('Months (${_selected.length} selected)', c),
                const SizedBox(height: 10),
                ...yearKeys.map((year) {
                  final months = years[year]!;
                  final allSelected = months.every(_selected.contains);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: c.line2, width: 0.5),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(year,
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: c.ink)),
                            const Spacer(),
                            TextButton(
                              onPressed: () => _selectYear(available, year),
                              style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap),
                              child: Text(
                                  allSelected ? 'Clear year' : 'Select year',
                                  style: TextStyle(
                                      color: c.accent, fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: months.map((m) {
                            final on = _selected.contains(m);
                            return GestureDetector(
                              onTap: () => setState(() {
                                if (on) {
                                  _selected.remove(m);
                                } else {
                                  _selected.add(m);
                                }
                              }),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 120),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 9),
                                decoration: BoxDecoration(
                                  color: on ? c.accent : c.surface2,
                                  borderRadius: BorderRadius.circular(9),
                                  border: Border.all(
                                      color: on ? c.accent : c.line,
                                      width: 0.5),
                                ),
                                child: Text(
                                  monthLabel(m),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight:
                                        on ? FontWeight.w700 : FontWeight.w500,
                                    color: on ? Colors.white : c.ink2,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  );
                }),

                // ── Preview ───────────────────────────────────────────────
                if (preview != null) ...[
                  const SizedBox(height: 10),
                  _SectionTitle('Preview', c),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: c.line2, width: 0.5),
                    ),
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        _PreviewRow(
                            label: 'Range',
                            value: preview.rangeLabel,
                            c: c),
                        _PreviewRow(
                            label: 'Transactions',
                            value: '${preview.transactions.length}',
                            c: c),
                        _PreviewRow(
                            label: 'Earned',
                            value: fmtRp(preview.totalEarn, cfg.currency),
                            valueColor: c.pos,
                            c: c),
                        _PreviewRow(
                            label: 'Spent',
                            value: fmtRp(preview.totalSpend, cfg.currency),
                            valueColor: c.neg,
                            c: c),
                        _PreviewRow(
                            label: 'Net',
                            value: fmtRp(preview.totalNet, cfg.currency),
                            valueColor:
                                preview.totalNet >= 0 ? c.pos : c.neg,
                            c: c),
                      ],
                    ),
                  ),
                ],
              ],
            ),

            // ── Export button ─────────────────────────────────────────────
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed:
                      _selected.isEmpty || _busy ? null : () => _export(data),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.ink,
                    disabledBackgroundColor: c.muted.withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(
                          _selected.isEmpty
                              ? 'Select at least one month'
                              : 'Export ${_selected.length} month${_selected.length == 1 ? '' : 's'} · ${_format.extension.toUpperCase()}',
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors c;
  const _SectionTitle(this.text, this.c);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: c.muted,
            letterSpacing: 0.06),
      );
}

class _FormatCard extends StatelessWidget {
  final AppColors c;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _FormatCard({
    required this.c,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? c.accent.withValues(alpha: 0.08) : c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? c.accent : c.line2,
              width: selected ? 1.2 : 0.5),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: selected ? c.accent : c.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: c.ink)),
                  Text(subtitle,
                      style: TextStyle(fontSize: 11, color: c.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final AppColors c;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.line, width: 0.5),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: c.ink2)),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final AppColors c;

  const _PreviewRow(
      {required this.label,
      required this.value,
      required this.c,
      this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 13, color: c.muted))),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: valueColor ?? c.ink)),
        ],
      ),
    );
  }
}
