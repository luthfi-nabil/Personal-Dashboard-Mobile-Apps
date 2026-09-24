import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/routine_schedule.dart';
import '../theme/app_theme.dart';

/// "Paid" / "Not paid" for a routine's current period (month, year, custom
/// cycle...). Shared by personal and group routines.
class PaidStatusChip extends StatelessWidget {
  final bool paid;
  final AppColors c;
  const PaidStatusChip({super.key, required this.paid, required this.c});

  @override
  Widget build(BuildContext context) {
    final color = paid ? c.pos : c.neg;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(paid ? 'Paid' : 'Not Paid',
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

/// The fixed repeat choices, plus "Custom" which reveals an
/// "every [n] [day|month|year]" row.
const fixedReminders = ['weekly', 'monthly', 'bi-monthly', 'quarterly', 'yearly'];

/// Picks how often a routine repeats. Reports the stored `reminder` string
/// through [onChanged]: a fixed value, or `custom:<n>:<unit>`.
class RepeatPicker extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;

  /// Builds the field decoration for a label, so the picker matches the
  /// form it sits in. Defaults to a plain [InputDecoration].
  final InputDecoration Function(String label)? decoration;
  final String label;
  final Color? dropdownColor;
  final TextStyle? style;

  const RepeatPicker({
    super.key,
    required this.initial,
    required this.onChanged,
    this.decoration,
    this.label = 'Repeats',
    this.dropdownColor,
    this.style,
  });

  @override
  State<RepeatPicker> createState() => _RepeatPickerState();
}

class _RepeatPickerState extends State<RepeatPicker> {
  late String _choice;
  late final TextEditingController _every;
  late String _unit;

  @override
  void initState() {
    super.initState();
    final custom = isCustomReminder(widget.initial);
    final parsed = RoutineRepeat.parse(widget.initial);
    _choice = custom
        ? 'custom'
        : (fixedReminders.contains(widget.initial) ? widget.initial : 'monthly');
    _every = TextEditingController(text: custom ? '${parsed.every}' : '1');
    _unit = custom ? parsed.unit : 'month';
  }

  @override
  void dispose() {
    _every.dispose();
    super.dispose();
  }

  InputDecoration _decor(String label) =>
      widget.decoration?.call(label) ?? InputDecoration(labelText: label);

  void _emit() {
    if (_choice != 'custom') {
      widget.onChanged(_choice);
      return;
    }
    final n = int.tryParse(_every.text.trim()) ?? 0;
    // An empty or zero count is not a timeline yet; keep the last valid one
    // by reporting nothing new.
    if (n < 1) return;
    widget.onChanged(customReminder(n, _unit));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _choice,
          decoration: _decor(widget.label),
          dropdownColor: widget.dropdownColor,
          style: widget.style,
          items: [
            for (final r in fixedReminders)
              DropdownMenuItem(value: r, child: Text(r)),
            const DropdownMenuItem(value: 'custom', child: Text('Custom')),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _choice = v);
            _emit();
          },
        ),
        if (_choice == 'custom') ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _every,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: widget.style,
                  decoration: _decor('Every'),
                  onChanged: (_) => _emit(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _unit,
                  decoration: _decor('Unit'),
                  dropdownColor: widget.dropdownColor,
                  style: widget.style,
                  items: const [
                    DropdownMenuItem(value: 'day', child: Text('day(s)')),
                    DropdownMenuItem(value: 'month', child: Text('month(s)')),
                    DropdownMenuItem(value: 'year', child: Text('year(s)')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _unit = v);
                    _emit();
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
