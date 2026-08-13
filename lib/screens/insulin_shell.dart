import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/utils.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_menu_drawer.dart';
import 'main_shell.dart' show refreshNow;

enum InsulinPageView { home, activity, reports }

enum InsulinAddKind { type, assign, usage, bloodSugar }

class InsulinPage extends ConsumerWidget {
  final InsulinPageView view;

  const InsulinPage({super.key, required this.view});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.colorsOf(context);
    final location = GoRouterState.of(context).uri.path;
    final dataAsync = ref.watch(appDataProvider);

    return Scaffold(
      backgroundColor: c.bg,
      drawer: AppMenuDrawer(currentPath: location),
      body: Column(
        children: [
          _InsulinTopBar(c: c, onRefresh: () => refreshNow(context, ref)),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => refreshNow(context, ref),
              child: dataAsync.when(
                loading: () => _StatusList(
                  c: c,
                  title: _title(view),
                  message: 'Loading diabetic data...',
                  loading: true,
                ),
                error: (error, _) => _StatusList(
                  c: c,
                  title: _title(view),
                  message:
                      'Diabetic data could not be loaded. Check health-api or pull to refresh.',
                ),
                data: (data) => _InsulinBody(view: view, data: data, c: c),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openAddMenu(context, c),
        backgroundColor: c.ink,
        foregroundColor: c.bg,
        elevation: 8,
        child: const Icon(Icons.add_rounded, size: 26),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: _InsulinBottomBar(currentPath: location, c: c),
    );
  }

  void _openAddMenu(BuildContext context, AppColors c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AddMenuTile(
                c: c,
                icon: Icons.water_drop_outlined,
                title: 'Add insulin usage',
                route: '/insulin/add-usage',
              ),
              _AddMenuTile(
                c: c,
                icon: Icons.vaccines_outlined,
                title: 'Add insulin type',
                route: '/insulin/add-type',
              ),
              _AddMenuTile(
                c: c,
                icon: Icons.inventory_2_outlined,
                title: 'Add insulin batch',
                route: '/insulin/add-batch',
              ),
              _AddMenuTile(
                c: c,
                icon: Icons.monitor_heart_outlined,
                title: 'Add blood sugar level',
                route: '/insulin/add-blood-sugar',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddMenuTile extends StatelessWidget {
  final AppColors c;
  final IconData icon;
  final String title;
  final String route;

  const _AddMenuTile({
    required this.c,
    required this.icon,
    required this.title,
    required this.route,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: c.ink),
      title: Text(
        title,
        style: TextStyle(color: c.ink, fontWeight: FontWeight.w700),
      ),
      onTap: () {
        Navigator.pop(context);
        context.go(route);
      },
    );
  }
}

class _InsulinTopBar extends StatelessWidget {
  final AppColors c;

  /// Same manual refresh as the main shell, so the control is where the user
  /// expects it here too rather than only as a pull-down.
  final VoidCallback onRefresh;

  const _InsulinTopBar({required this.c, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 16,
        top: MediaQuery.of(context).padding.top + 8,
        bottom: 10,
      ),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(bottom: BorderSide(color: c.line2, width: 0.5)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Menu',
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: Icon(Icons.menu_rounded, color: c.ink),
          ),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.ink,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Icons.vaccines_rounded, color: c.bg, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Diabetic Dashboard',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: c.ink,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Refresh data',
            onPressed: onRefresh,
            icon: Icon(Icons.refresh_rounded, color: c.ink),
          ),
        ],
      ),
    );
  }
}

class InsulinAddPage extends ConsumerStatefulWidget {
  final InsulinAddKind kind;
  final String? returnPath;

  const InsulinAddPage({super.key, required this.kind, this.returnPath});

  @override
  ConsumerState<InsulinAddPage> createState() => _InsulinAddPageState();
}

class _InsulinAddPageState extends ConsumerState<InsulinAddPage> {
  final _nameCtl = TextEditingController();
  final _unitsCtl = TextEditingController();
  final _uomCtl = TextEditingController(text: 'unit');
  final _batchCtl = TextEditingController();
  final _notesCtl = TextEditingController();
  String? _itemId;
  String? _assignId;
  String _mealContext = 'fasting';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.kind == InsulinAddKind.bloodSugar) {
      _uomCtl.text = 'mg/dL';
    }
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _unitsCtl.dispose();
    _uomCtl.dispose();
    _batchCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.colorsOf(context);
    final location = GoRouterState.of(context).uri.path;
    final dataAsync = ref.watch(appDataProvider);

    return Scaffold(
      backgroundColor: c.bg,
      drawer: AppMenuDrawer(currentPath: location),
      body: Column(
        children: [
          _InsulinTopBar(c: c, onRefresh: () => refreshNow(context, ref)),
          Expanded(
            child: dataAsync.when(
              loading: () => _StatusList(
                c: c,
                title: _addTitle(widget.kind),
                message: 'Loading diabetic data...',
                loading: true,
              ),
              error: (error, _) => _StatusList(
                c: c,
                title: _addTitle(widget.kind),
                message: 'Could not load diabetic data.',
              ),
              data: (data) => _form(c, data),
            ),
          ),
        ],
      ),
    );
  }

  Widget _form(AppColors c, AppData data) {
    _ensureSelection(data);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Back',
              onPressed: () => context.go('/insulin'),
              icon: Icon(Icons.arrow_back_rounded, color: c.ink),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _addTitle(widget.kind),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: c.ink,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (widget.kind == InsulinAddKind.type) ..._typeFields(c),
        if (widget.kind == InsulinAddKind.assign) ..._assignFields(c, data),
        if (widget.kind == InsulinAddKind.usage) ..._usageFields(c, data),
        if (widget.kind == InsulinAddKind.bloodSugar) ..._bloodSugarFields(c),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _saving ? null : () => _save(data),
          style: FilledButton.styleFrom(
            backgroundColor: c.ink,
            foregroundColor: c.bg,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: _saving
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.bg,
                  ),
                )
              : Text(_saveLabel(widget.kind)),
        ),
      ],
    );
  }

  List<Widget> _typeFields(AppColors c) => [
        TextField(
          controller: _nameCtl,
          style: TextStyle(color: c.ink),
          decoration: const InputDecoration(
            labelText: 'Insulin name',
            hintText: 'e.g. Lantus',
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _numberField(
                c,
                controller: _unitsCtl,
                label: 'Units',
                hint: 'e.g. 100',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _uomCtl,
                style: TextStyle(color: c.ink),
                decoration: const InputDecoration(
                  labelText: 'Unit',
                  hintText: 'unit, ml, IU',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _notesField(c),
      ];

  List<Widget> _assignFields(AppColors c, AppData data) => [
        if (data.insulinItems.isEmpty)
          _EmptyPanel(c: c, text: 'Add an insulin type before adding a batch.')
        else ...[
          DropdownButtonFormField<String>(
            initialValue: _itemId,
            decoration: const InputDecoration(labelText: 'Insulin type'),
            items: data.insulinItems
                .map((item) => DropdownMenuItem(
                      value: item.id,
                      child: Text(item.name),
                    ))
                .toList(),
            onChanged: (value) => setState(() => _itemId = value),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _batchCtl,
            style: TextStyle(color: c.ink),
            decoration: const InputDecoration(
              labelText: 'Batch number',
              hintText: 'e.g. B-2026-001',
            ),
          ),
          const SizedBox(height: 14),
          _notesField(c),
        ],
      ];

  List<Widget> _usageFields(AppColors c, AppData data) {
    final assigns = _itemId == null
        ? data.insulinAssigns
        : data.insulinAssigns
            .where((assign) => assign.itemId == _itemId)
            .toList();

    return [
      if (data.insulinItems.isEmpty || data.insulinAssigns.isEmpty)
        _EmptyPanel(
          c: c,
          text: 'Add an insulin type and batch before logging usage.',
        )
      else ...[
        DropdownButtonFormField<String>(
          initialValue: _itemId,
          decoration: const InputDecoration(labelText: 'Insulin type'),
          items: data.insulinItems
              .map((item) => DropdownMenuItem(
                    value: item.id,
                    child: Text(item.name),
                  ))
              .toList(),
          onChanged: (value) {
            setState(() {
              _itemId = value;
              final nextAssigns = data.insulinAssigns
                  .where((assign) => assign.itemId == value)
                  .toList();
              _assignId = nextAssigns.isEmpty ? null : nextAssigns.first.id;
            });
          },
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: assigns.any((assign) => assign.id == _assignId)
              ? _assignId
              : null,
          decoration: const InputDecoration(labelText: 'Batch'),
          items: assigns
              .map((assign) => DropdownMenuItem(
                    value: assign.id,
                    child: Text(
                        '${assign.batchNo} - ${_fmtNum(assign.totalUnits)} left'),
                  ))
              .toList(),
          onChanged: assigns.isEmpty
              ? null
              : (value) => setState(() => _assignId = value),
        ),
        const SizedBox(height: 14),
        _numberField(
          c,
          controller: _unitsCtl,
          label: 'Dose used',
          hint: 'e.g. 10',
        ),
        const SizedBox(height: 14),
        _notesField(c),
      ],
    ];
  }

  List<Widget> _bloodSugarFields(AppColors c) => [
        Row(
          children: [
            Expanded(
              child: _numberField(
                c,
                controller: _unitsCtl,
                label: 'Blood sugar level',
                hint: 'e.g. 110',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _uomCtl,
                style: TextStyle(color: c.ink),
                decoration: const InputDecoration(
                  labelText: 'Unit',
                  hintText: 'mg/dL',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: _mealContext,
          decoration: const InputDecoration(labelText: 'Context'),
          items: const [
            DropdownMenuItem(value: 'fasting', child: Text('Fasting')),
            DropdownMenuItem(value: 'before meal', child: Text('Before meal')),
            DropdownMenuItem(value: 'after meal', child: Text('After meal')),
            DropdownMenuItem(value: 'bedtime', child: Text('Bedtime')),
            DropdownMenuItem(value: 'random', child: Text('Random')),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() => _mealContext = value);
          },
        ),
        const SizedBox(height: 14),
        _notesField(c),
      ];

  Widget _numberField(
    AppColors c, {
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      style: TextStyle(color: c.ink),
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }

  Widget _notesField(AppColors c) {
    return TextField(
      controller: _notesCtl,
      style: TextStyle(color: c.ink),
      decoration: const InputDecoration(labelText: 'Notes (optional)'),
    );
  }

  void _ensureSelection(AppData data) {
    if (_itemId == null && data.insulinItems.isNotEmpty) {
      _itemId = data.insulinItems.first.id;
    }
    if (_assignId == null && data.insulinAssigns.isNotEmpty) {
      final assigns = _itemId == null
          ? data.insulinAssigns
          : data.insulinAssigns.where((assign) => assign.itemId == _itemId);
      if (assigns.isNotEmpty) _assignId = assigns.first.id;
    }
  }

  Future<void> _save(AppData data) async {
    final notes = _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim();
    setState(() => _saving = true);
    try {
      if (widget.kind == InsulinAddKind.type) {
        final units = double.tryParse(_unitsCtl.text.replaceAll(',', '.'));
        if (_nameCtl.text.trim().isEmpty || units == null || units <= 0) return;
        await Repo.instance.createInsulinItem(
          name: _nameCtl.text.trim(),
          units: units,
          uom: _uomCtl.text.trim().isEmpty ? 'unit' : _uomCtl.text.trim(),
          notes: notes,
        );
      } else if (widget.kind == InsulinAddKind.assign) {
        if (_itemId == null || _batchCtl.text.trim().isEmpty) return;
        await Repo.instance.createInsulinAssign(
          itemId: _itemId!,
          batchNo: _batchCtl.text.trim(),
          notes: notes,
        );
      } else if (widget.kind == InsulinAddKind.usage) {
        final units = double.tryParse(_unitsCtl.text.replaceAll(',', '.'));
        if (_assignId == null || units == null || units <= 0) return;
        await Repo.instance.logInsulinUsage(
          assignId: _assignId!,
          units: units,
          notes: notes,
        );
      } else {
        final level = double.tryParse(_unitsCtl.text.replaceAll(',', '.'));
        if (level == null || level <= 0) return;
        await Repo.instance.logBloodSugar(
          level: level,
          unit: _uomCtl.text.trim().isEmpty ? 'mg/dL' : _uomCtl.text.trim(),
          mealContext: _mealContext,
          notes: notes,
        );
      }
      await ref.read(appDataProvider.notifier).refresh();
      if (mounted) context.go(widget.returnPath ?? '/insulin');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _InsulinBody extends StatelessWidget {
  final InsulinPageView view;
  final AppData data;
  final AppColors c;

  const _InsulinBody({
    required this.view,
    required this.data,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final rows = _usageRows(data);
    final monthKey = DateTime.now().toIso8601String().substring(0, 7);
    final monthRows =
        rows.where((row) => row.usage.date.startsWith(monthKey)).toList();
    final monthTotal =
        monthRows.fold<double>(0, (sum, row) => sum + row.usage.units);
    final latestRow = rows.isEmpty ? null : rows.first;
    final bloodSugarLogs = [...data.bloodSugarLogs]
      ..sort((a, b) => b.measuredAt.compareTo(a.measuredAt));
    final latestBloodSugar =
        bloodSugarLogs.isEmpty ? null : bloodSugarLogs.first;
    final monthSugarLogs =
        bloodSugarLogs.where((log) => log.measuredAt.startsWith(monthKey));
    final monthAverageSugar = _averageSugar(monthSugarLogs);

    return ListView(
      key: ValueKey('insulin-${view.name}'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        if (view == InsulinPageView.home) ...[
          _SummaryGrid(
            monthTotal: monthTotal,
            activeBatches: data.insulinAssigns.length,
            latestRow: latestRow,
            usageCount: rows.length,
            latestBloodSugar: latestBloodSugar,
            monthAverageSugar: monthAverageSugar,
            monthSugarUnit: latestBloodSugar?.unit ?? 'mg/dL',
            c: c,
          ),
          const SizedBox(height: 18),
          _SectionTitle('Blood sugar', c),
          const SizedBox(height: 10),
          if (latestBloodSugar == null)
            _EmptyPanel(c: c, text: 'No blood sugar logs yet.')
          else
            _BloodSugarTile(log: latestBloodSugar, c: c),
          const SizedBox(height: 18),
          _SectionTitle('Active batches', c),
          const SizedBox(height: 10),
          if (data.insulinAssigns.isEmpty)
            _EmptyPanel(c: c, text: 'No insulin batches from health-api yet.')
          else
            ...data.insulinAssigns
                .map((assign) => _BatchTile(assign: assign, c: c)),
        ] else if (view == InsulinPageView.activity) ...[
          _SectionTitle('Usage history', c),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            _EmptyPanel(c: c, text: 'No insulin usage has been logged yet.')
          else
            ...rows.map((row) => _UsageTile(row: row, c: c)),
          const SizedBox(height: 18),
          _SectionTitle('Blood sugar history', c),
          const SizedBox(height: 10),
          if (bloodSugarLogs.isEmpty)
            _EmptyPanel(c: c, text: 'No blood sugar logs yet.')
          else
            ...bloodSugarLogs.map((log) => _BloodSugarTile(log: log, c: c)),
        ] else ...[
          _SectionTitle('Sugar and insulin trend', c),
          const SizedBox(height: 10),
          _HealthTrendChart(rows: rows, bloodSugarLogs: bloodSugarLogs, c: c),
          const SizedBox(height: 18),
          _SectionTitle('Average batch dose per month', c),
          const SizedBox(height: 10),
          _InsulinReportsSection(rows: rows, c: c),
        ],
      ],
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  final double monthTotal;
  final int activeBatches;
  final _UsageRow? latestRow;
  final BloodSugarLog? latestBloodSugar;
  final double? monthAverageSugar;
  final String monthSugarUnit;
  final int usageCount;
  final AppColors c;

  const _SummaryGrid({
    required this.monthTotal,
    required this.activeBatches,
    required this.latestRow,
    required this.latestBloodSugar,
    required this.monthAverageSugar,
    required this.monthSugarUnit,
    required this.usageCount,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final latest = latestRow;
    final latestSugar = latestBloodSugar;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.05,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      children: [
        _Metric(
            label: 'This month', value: '${_fmtNum(monthTotal)} doses', c: c),
        _Metric(label: 'Active batches', value: activeBatches.toString(), c: c),
        _Metric(
          label: latest == null
              ? 'Latest administered'
              : 'Dose - ${_fmtDateTime(latest.usage.date)}',
          value: latest == null
              ? 'No doses'
              : '${_fmtNum(latest.usage.units)} doses',
          c: c,
        ),
        _Metric(
          label: latestSugar == null
              ? 'Latest blood sugar'
              : 'Sugar - ${_fmtDateTime(latestSugar.measuredAt)}',
          value: latestSugar == null
              ? 'No reading'
              : '${_fmtNum(latestSugar.level)} ${latestSugar.unit}',
          c: c,
        ),
        _Metric(
            label: 'Insulin usage logs', value: usageCount.toString(), c: c),
        _Metric(
          label:
              'Avg sugar - ${monthLabel(DateTime.now().toIso8601String().substring(0, 7))}',
          value: monthAverageSugar == null
              ? 'No readings'
              : '${_fmtNum(monthAverageSugar!)} $monthSugarUnit',
          c: c,
        ),
      ],
    );
  }
}

class _HealthTrendChart extends StatefulWidget {
  final List<_UsageRow> rows;
  final List<BloodSugarLog> bloodSugarLogs;
  final AppColors c;

  const _HealthTrendChart({
    required this.rows,
    required this.bloodSugarLogs,
    required this.c,
  });

  @override
  State<_HealthTrendChart> createState() => _HealthTrendChartState();
}

class _HealthTrendChartState extends State<_HealthTrendChart> {
  int _days = 30;
  DateTimeRange? _customRange;
  String _selectedType = _allInsulinTypesFilter;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final range = _effectiveRange();
    final types = widget.rows.map((row) => row.itemName).toSet().toList()
      ..sort();
    final effectiveType =
        types.contains(_selectedType) ? _selectedType : _allInsulinTypesFilter;
    final points = _trendPoints(
      widget.rows,
      widget.bloodSugarLogs,
      range,
      insulinType:
          effectiveType == _allInsulinTypesFilter ? null : effectiveType,
    );
    final sugarSeries = points
        .where((point) => point.sugar != null)
        .map((point) => _ChartPoint(
              day: point.day,
              value: point.sugar!,
              label: '${_fmtNum(point.sugar!)} ${point.sugarUnit}',
            ))
        .toList();
    final insulinSeries = points
        .where((point) => point.insulin > 0)
        .map((point) => _ChartPoint(
              day: point.day,
              value: point.insulin,
              label: '${_fmtNum(point.insulin)} doses',
            ))
        .toList();

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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _RangeChip(
                label: '7D',
                selected: _customRange == null && _days == 7,
                onTap: () => setState(() {
                  _days = 7;
                  _customRange = null;
                }),
                c: c,
              ),
              _RangeChip(
                label: '30D',
                selected: _customRange == null && _days == 30,
                onTap: () => setState(() {
                  _days = 30;
                  _customRange = null;
                }),
                c: c,
              ),
              _RangeChip(
                label: '90D',
                selected: _customRange == null && _days == 90,
                onTap: () => setState(() {
                  _days = 90;
                  _customRange = null;
                }),
                c: c,
              ),
              _RangeChip(
                label: _customRange == null
                    ? 'Dates'
                    : '${fmtDate(_customRange!.start.toIso8601String(), 'short')} - ${fmtDate(_customRange!.end.toIso8601String(), 'short')}',
                selected: _customRange != null,
                onTap: _pickRange,
                c: c,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _TrendSeriesPanel(
            title: 'Sugar trend',
            subtitle: 'Daily average blood sugar',
            emptyText: 'No sugar data in this range.',
            points: sugarSeries,
            color: c.accent,
            c: c,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Insulin usage trend',
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (types.isNotEmpty)
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: effectiveType,
                    borderRadius: BorderRadius.circular(8),
                    items: [
                      const DropdownMenuItem(
                        value: _allInsulinTypesFilter,
                        child: Text('All types'),
                      ),
                      ...types.map(
                        (type) =>
                            DropdownMenuItem(value: type, child: Text(type)),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _selectedType = value);
                    },
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _TrendSeriesPanel(
            title: null,
            subtitle: effectiveType == _allInsulinTypesFilter
                ? 'Daily total insulin usage'
                : 'Daily usage for $effectiveType',
            emptyText: 'No insulin usage in this range.',
            points: insulinSeries,
            color: c.neg,
            c: c,
          ),
          const SizedBox(height: 8),
          Text(
            '${fmtDate(points.first.day, 'short')} - ${fmtDate(points.last.day, 'short')}',
            style: TextStyle(fontSize: 11, color: c.muted),
          ),
        ],
      ),
    );
  }

  DateTimeRange _effectiveRange() {
    if (_customRange != null) return _customRange!;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTimeRange(
      start: today.subtract(Duration(days: _days - 1)),
      end: today,
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final initial = _customRange ??
        DateTimeRange(
          start: DateTime(now.year, now.month, now.day)
              .subtract(Duration(days: _days - 1)),
          end: DateTime(now.year, now.month, now.day),
        );
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: initial,
    );
    if (selected == null) return;
    setState(() => _customRange = selected);
  }
}

class _TrendSeriesPanel extends StatelessWidget {
  final String? title;
  final String subtitle;
  final String emptyText;
  final List<_ChartPoint> points;
  final Color color;
  final AppColors c;

  const _TrendSeriesPanel({
    required this.title,
    required this.subtitle,
    required this.emptyText,
    required this.points,
    required this.color,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(
            title!,
            style: TextStyle(
              color: c.ink,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
        ],
        Text(subtitle, style: TextStyle(fontSize: 11, color: c.muted)),
        const SizedBox(height: 8),
        if (points.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child:
                Text(emptyText, style: TextStyle(fontSize: 12, color: c.muted)),
          )
        else
          _TrendLineChart(points: points, color: color, c: c),
      ],
    );
  }
}

class _TrendLineChart extends StatelessWidget {
  final List<_ChartPoint> points;
  final Color color;
  final AppColors c;

  const _TrendLineChart({
    required this.points,
    required this.color,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final values = points.map((point) => point.value).toList();
    final minValue = values.reduce((a, b) => a < b ? a : b);
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final range = maxValue - minValue;
    final padding = range == 0 ? (maxValue.abs() * 0.1) + 1 : range * 0.18;
    final minY = (minValue - padding).clamp(0.0, double.infinity);
    final maxY = maxValue + padding;
    final spots = [
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].value),
    ];

    return SizedBox(
      height: 130,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: points.length <= 1 ? 1 : (points.length - 1).toDouble(),
          minY: minY,
          maxY: maxY <= minY ? minY + 1 : maxY,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: c.line2, strokeWidth: 0.5),
          ),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              tooltipRoundedRadius: 8,
              getTooltipItems: (spots) => spots.map((spot) {
                final index =
                    spot.x.round().clamp(0, points.length - 1).toInt();
                final point = points[index];
                return LineTooltipItem(
                  '${fmtDate(point.day, 'short')}\n${point.label}',
                  TextStyle(color: c.bg, fontWeight: FontWeight.w700),
                );
              }).toList(),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: color,
              barWidth: 2.5,
              dotData: FlDotData(show: spots.length <= 14),
              belowBarData: BarAreaData(show: false),
            ),
          ],
        ),
      ),
    );
  }
}

class _RangeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final AppColors c;

  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? c.ink : c.surface2,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? c.ink : c.line2, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? c.bg : c.ink,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final AppColors c;

  const _Metric({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: c.muted)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: c.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _BatchTile extends StatelessWidget {
  final InsulinAssign assign;
  final AppColors c;

  const _BatchTile({required this.assign, required this.c});

  @override
  Widget build(BuildContext context) {
    return _ListPanel(
      c: c,
      icon: Icons.inventory_2_outlined,
      title: assign.itemName.isEmpty ? 'Unknown insulin' : assign.itemName,
      subtitle:
          'Batch ${assign.batchNo}${assign.lastUsedAt == null ? '' : ' - last ${fmtDate(assign.lastUsedAt!, 'short')}'}',
      trailing: '${_fmtNum(assign.totalUnits)} left',
    );
  }
}

class _UsageTile extends StatelessWidget {
  final _UsageRow row;
  final AppColors c;

  const _UsageTile({required this.row, required this.c});

  @override
  Widget build(BuildContext context) {
    return _ListPanel(
      c: c,
      icon: Icons.water_drop_outlined,
      title: row.itemName,
      subtitle:
          'Batch ${row.batchNo} - ${_fmtDateTime(row.usage.date)}${(row.usage.notes?.isNotEmpty ?? false) ? ' - ${row.usage.notes}' : ''}',
      trailing: '${_fmtNum(row.usage.units)} doses',
    );
  }
}

class _BloodSugarTile extends StatelessWidget {
  final BloodSugarLog log;
  final AppColors c;

  const _BloodSugarTile({required this.log, required this.c});

  @override
  Widget build(BuildContext context) {
    final contextText =
        log.mealContext?.isNotEmpty == true ? ' - ${log.mealContext}' : '';
    final notesText = log.notes?.isNotEmpty == true ? ' - ${log.notes}' : '';
    return _ListPanel(
      c: c,
      icon: Icons.monitor_heart_outlined,
      title: '${_fmtNum(log.level)} ${log.unit}',
      subtitle: '${fmtDate(log.measuredAt, 'short')}$contextText$notesText',
      trailing: fmtDate(log.measuredAt, 'time'),
    );
  }
}

class _ListPanel extends StatelessWidget {
  final AppColors c;
  final IconData icon;
  final String title;
  final String subtitle;
  final String trailing;

  const _ListPanel({
    required this.c,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 19, color: c.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            trailing,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: c.ink,
            ),
          ),
        ],
      ),
    );
  }
}

const _allInsulinTypesFilter = '__all';

class _InsulinReportsSection extends StatefulWidget {
  final List<_UsageRow> rows;
  final AppColors c;

  const _InsulinReportsSection({
    required this.rows,
    required this.c,
  });

  @override
  State<_InsulinReportsSection> createState() => _InsulinReportsSectionState();
}

class _InsulinReportsSectionState extends State<_InsulinReportsSection> {
  String _selectedType = _allInsulinTypesFilter;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final types = widget.rows.map((row) => row.itemName).toSet().toList()
      ..sort();
    final effectiveType =
        types.contains(_selectedType) ? _selectedType : _allInsulinTypesFilter;
    final filteredRows = effectiveType == _allInsulinTypesFilter
        ? widget.rows
        : widget.rows.where((row) => row.itemName == effectiveType).toList();
    final averages = _averageBatchUsageByMonth(filteredRows);
    final maxAverage = averages.fold<double>(
      0,
      (max, entry) => entry.averageUnits > max ? entry.averageUnits : max,
    );

    if (widget.rows.isEmpty) {
      return _EmptyPanel(c: c, text: 'No insulin usage has been logged yet.');
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line2, width: 0.5),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: effectiveType,
              isExpanded: true,
              items: [
                const DropdownMenuItem(
                  value: _allInsulinTypesFilter,
                  child: Text('All insulin types'),
                ),
                ...types.map(
                  (type) => DropdownMenuItem(value: type, child: Text(type)),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _selectedType = value);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (averages.isEmpty)
          _EmptyPanel(c: c, text: 'No usage for this insulin type yet.')
        else
          ...averages.map(
            (entry) => _AverageBatchUsageTile(
              entry: entry,
              maxAverage: maxAverage,
              c: c,
            ),
          ),
      ],
    );
  }
}

class _AverageBatchUsageTile extends StatelessWidget {
  final _BatchUsageAverage entry;
  final double maxAverage;
  final AppColors c;

  const _AverageBatchUsageTile({
    required this.entry,
    required this.maxAverage,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final progress = maxAverage <= 0 ? 0.0 : entry.averageUnits / maxAverage;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
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
                child: Text(
                  entry.itemName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: c.ink,
                  ),
                ),
              ),
              Text(
                '${_fmtNum(entry.averageUnits)} avg/batch',
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${monthLabel(entry.monthKey)} ${entry.monthKey.substring(0, 4)} - '
            '${entry.batchCount} batches - ${_fmtNum(entry.totalUnits)} doses total',
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation<Color>(c.accent),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  final AppColors c;
  final String text;

  const _EmptyPanel({required this.c, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.line2, width: 0.5),
      ),
      child: Text(text, style: TextStyle(fontSize: 13, color: c.muted)),
    );
  }
}

class _StatusList extends StatelessWidget {
  final AppColors c;
  final String title;
  final String message;
  final bool loading;

  const _StatusList({
    required this.c,
    required this.title,
    required this.message,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: c.ink,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line2, width: 0.5),
          ),
          child: Row(
            children: [
              if (loading)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: c.accent,
                  ),
                )
              else
                Icon(Icons.info_outline_rounded, color: c.muted, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(fontSize: 13, color: c.muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final AppColors c;

  const _SectionTitle(this.text, this.c);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: c.muted,
      ),
    );
  }
}

class _InsulinBottomBar extends StatelessWidget {
  final String currentPath;
  final AppColors c;

  const _InsulinBottomBar({required this.currentPath, required this.c});

  @override
  Widget build(BuildContext context) {
    final tabs = [
      (Icons.home_outlined, Icons.home_rounded, 'Home', '/insulin'),
      (
        Icons.list_outlined,
        Icons.list_rounded,
        'Activity',
        '/insulin/activity'
      ),
      (
        Icons.bar_chart_outlined,
        Icons.bar_chart_rounded,
        'Reports',
        '/insulin/reports'
      ),
    ];

    return BottomAppBar(
      color: c.surface.withValues(alpha: 0.95),
      elevation: 0,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            for (final tab in tabs)
              Expanded(
                child: _InsulinTabItem(
                  icon: _isActive(tab.$4, currentPath) ? tab.$2 : tab.$1,
                  label: tab.$3,
                  active: _isActive(tab.$4, currentPath),
                  c: c,
                  onTap: () => context.go(tab.$4),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _isActive(String route, String currentPath) {
    if (route == '/insulin') return currentPath == '/insulin';
    return currentPath == route || currentPath.startsWith('$route/');
  }
}

class _InsulinTabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final AppColors c;
  final VoidCallback onTap;

  const _InsulinTabItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? c.ink : c.muted;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageRow {
  final InsulinUsage usage;
  final InsulinAssign? assign;
  final InsulinItem? item;

  const _UsageRow({
    required this.usage,
    required this.assign,
    required this.item,
  });

  String get itemName =>
      item?.name ??
      assign?.itemName ??
      (assign == null ? 'Unknown insulin' : 'Unknown type');
  String get batchNo => assign?.batchNo ?? 'Unknown batch';
  String get batchKey => assign?.id ?? batchNo;
}

class _BatchUsageAverage {
  final String monthKey;
  final String itemName;
  final double totalUnits;
  final double averageUnits;
  final int batchCount;

  const _BatchUsageAverage({
    required this.monthKey,
    required this.itemName,
    required this.totalUnits,
    required this.averageUnits,
    required this.batchCount,
  });
}

class _BatchUsageAccumulator {
  final String monthKey;
  final String itemName;
  final Map<String, double> batchTotals = {};

  _BatchUsageAccumulator({
    required this.monthKey,
    required this.itemName,
  });

  void add(_UsageRow row) {
    batchTotals[row.batchKey] =
        (batchTotals[row.batchKey] ?? 0) + row.usage.units;
  }

  _BatchUsageAverage toAverage() {
    final total =
        batchTotals.values.fold<double>(0, (sum, units) => sum + units);
    final batchCount = batchTotals.length;
    return _BatchUsageAverage(
      monthKey: monthKey,
      itemName: itemName,
      totalUnits: total,
      averageUnits: batchCount == 0 ? 0 : total / batchCount,
      batchCount: batchCount,
    );
  }
}

List<_UsageRow> _usageRows(AppData data) {
  final assignById = {
    for (final assign in data.insulinAssigns) assign.id: assign
  };
  final itemById = {for (final item in data.insulinItems) item.id: item};
  final rows = data.insulinUsages.map((usage) {
    final assign = assignById[usage.assignId];
    return _UsageRow(
      usage: usage,
      assign: assign,
      item: assign == null ? null : itemById[assign.itemId],
    );
  }).toList();
  rows.sort((a, b) => b.usage.date.compareTo(a.usage.date));
  return rows;
}

List<_BatchUsageAverage> _averageBatchUsageByMonth(List<_UsageRow> rows) {
  final grouped = <String, _BatchUsageAccumulator>{};
  for (final row in rows) {
    final monthKey = isoMonth(row.usage.date);
    final key = '$monthKey\t${row.itemName}';
    final accumulator = grouped.putIfAbsent(
      key,
      () => _BatchUsageAccumulator(
        monthKey: monthKey,
        itemName: row.itemName,
      ),
    );
    accumulator.add(row);
  }
  final averages =
      grouped.values.map((accumulator) => accumulator.toAverage()).toList();
  averages.sort((a, b) {
    final monthCompare = b.monthKey.compareTo(a.monthKey);
    if (monthCompare != 0) return monthCompare;
    return a.itemName.compareTo(b.itemName);
  });
  return averages;
}

class _TrendPoint {
  final String day;
  final double? sugar;
  final String sugarUnit;
  final double insulin;

  const _TrendPoint({
    required this.day,
    required this.sugar,
    required this.sugarUnit,
    required this.insulin,
  });
}

class _ChartPoint {
  final String day;
  final double value;
  final String label;

  const _ChartPoint({
    required this.day,
    required this.value,
    required this.label,
  });
}

List<_TrendPoint> _trendPoints(
    List<_UsageRow> rows, List<BloodSugarLog> logs, DateTimeRange range,
    {String? insulinType}) {
  final sugarByDay = <String, List<BloodSugarLog>>{};
  for (final log in logs) {
    final day = _parseDay(log.measuredAt);
    if (day == null || !_inRange(day, range)) continue;
    (sugarByDay[_dayKey(day)] ??= []).add(log);
  }

  final insulinByDay = <String, double>{};
  for (final row in rows) {
    if (insulinType != null && row.itemName != insulinType) continue;
    final day = _parseDay(row.usage.date);
    if (day == null || !_inRange(day, range)) continue;
    final key = _dayKey(day);
    insulinByDay[key] = (insulinByDay[key] ?? 0) + row.usage.units;
  }

  final points = <_TrendPoint>[];
  var cursor = DateTime(range.start.year, range.start.month, range.start.day);
  final end = DateTime(range.end.year, range.end.month, range.end.day);
  while (!cursor.isAfter(end)) {
    final key = _dayKey(cursor);
    final dayLogs = sugarByDay[key] ?? const <BloodSugarLog>[];
    final average = _averageSugar(dayLogs);
    final unit = dayLogs.isEmpty ? 'mg/dL' : dayLogs.last.unit;
    points.add(_TrendPoint(
      day: key,
      sugar: average,
      sugarUnit: unit,
      insulin: insulinByDay[key] ?? 0,
    ));
    cursor = cursor.add(const Duration(days: 1));
  }
  return points;
}

double? _averageSugar(Iterable<BloodSugarLog> logs) {
  var count = 0;
  var total = 0.0;
  for (final log in logs) {
    count++;
    total += log.level;
  }
  return count == 0 ? null : total / count;
}

DateTime? _parseDay(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

bool _inRange(DateTime day, DateTimeRange range) {
  final start = DateTime(range.start.year, range.start.month, range.start.day);
  final end = DateTime(range.end.year, range.end.month, range.end.day);
  return !day.isBefore(start) && !day.isAfter(end);
}

String _dayKey(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

String _fmtDateTime(String value) {
  final date = fmtDate(value, 'short');
  final time = fmtDate(value, 'time');
  if (date.isEmpty) return time;
  if (time.isEmpty) return date;
  return '$date $time';
}

String _title(InsulinPageView view) => switch (view) {
      InsulinPageView.home => 'Diabetic',
      InsulinPageView.activity => 'Diabetic Activity',
      InsulinPageView.reports => 'Diabetic Reports',
    };

String _addTitle(InsulinAddKind kind) => switch (kind) {
      InsulinAddKind.type => 'Add insulin type',
      InsulinAddKind.assign => 'Add insulin batch',
      InsulinAddKind.usage => 'Add insulin usage',
      InsulinAddKind.bloodSugar => 'Add blood sugar level',
    };

String _saveLabel(InsulinAddKind kind) => switch (kind) {
      InsulinAddKind.type => 'Save type',
      InsulinAddKind.assign => 'Save batch',
      InsulinAddKind.usage => 'Save usage',
      InsulinAddKind.bloodSugar => 'Save blood sugar level',
    };

String _fmtNum(double n) =>
    n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(1);
