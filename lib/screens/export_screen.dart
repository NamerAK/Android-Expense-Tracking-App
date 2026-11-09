// lib/screens/export_screen.dart
//
// Lets the user pick a period (one month, several months, or a whole year)
// and exports the expenses of that period to an .xlsx spreadsheet.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:newproject/services/export_service.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, this.initialStart, this.initialEnd});

  /// Optional starting selection (only year and month are used).
  final DateTime? initialStart;
  final DateTime? initialEnd;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  late DateTime _start; // first day of the first month to export
  late DateTime _end; // first day of the last month to export (inclusive)
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final s = widget.initialStart ?? now;
    final e = widget.initialEnd ?? s;
    _start = DateTime(s.year, s.month);
    _end = DateTime(e.year, e.month);
  }

  bool get _isValid => !_start.isAfter(_end);

  void _setRange(DateTime start, DateTime end) {
    setState(() {
      _start = DateTime(start.year, start.month);
      _end = DateTime(end.year, end.month);
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final expenses = await ExportService.fetchExpenses(_start, _end);
      if (expenses.isEmpty) {
        _snack('No expenses found in this period.');
        return;
      }
      final bytes = ExportService.buildWorkbook(expenses, _start, _end);
      await ExportService.shareWorkbook(
        bytes,
        ExportService.fileNameFor(_start, _end),
      );
      _snack('Spreadsheet created with ${expenses.length} expenses.');
    } catch (e) {
      debugPrint('Export failed: $e');
      _snack('Could not create the spreadsheet. Please try again.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(title: const Text('Export to Spreadsheet')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Quick choices', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text('This month'),
                  onPressed: () => _setRange(now, now),
                ),
                ActionChip(
                  label: const Text('Last month'),
                  onPressed: () {
                    final last = DateTime(now.year, now.month - 1);
                    _setRange(last, last);
                  },
                ),
                ActionChip(
                  label: const Text('This year'),
                  onPressed: () =>
                      _setRange(DateTime(now.year, 1), DateTime(now.year, 12)),
                ),
                ActionChip(
                  label: const Text('Last year'),
                  onPressed: () => _setRange(
                    DateTime(now.year - 1, 1),
                    DateTime(now.year - 1, 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Or choose your own period', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            _MonthYearPicker(
              label: 'From',
              value: _start,
              onChanged: (d) => setState(() => _start = d),
            ),
            const SizedBox(height: 12),
            _MonthYearPicker(
              label: 'To',
              value: _end,
              onChanged: (d) => setState(() => _end = d),
            ),
            const SizedBox(height: 16),
            if (_isValid)
              Text(
                'Exporting: ${ExportService.periodLabel(_start, _end)}',
                style: theme.textTheme.bodyLarge,
              )
            else
              Text(
                'The "From" month must not be after the "To" month.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            const SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: (_isValid && !_exporting) ? _export : null,
                icon: _exporting
                    ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Icon(Icons.file_download_outlined),
                label: Text(_exporting ? 'Creating...' : 'Export to spreadsheet'),
              ),
            ),
            const SizedBox(height: 24),
            Text('The spreadsheet contains', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text(
              '• Summary: totals and the cash / credit split\n'
                  '• Expenses: every expense with date, category, amount, payment type and description\n'
                  '• By Category: totals per category with percentages\n'
                  '• By Month: totals for each month in the period',
            ),
            const SizedBox(height: 12),
            Text(
              'On a phone you can save the file to Drive, or send it by email or '
                  'WhatsApp. In a browser it downloads straight to your computer.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A month dropdown and a year dropdown side by side.
class _MonthYearPicker extends StatelessWidget {
  const _MonthYearPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime value; // first day of the month
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final nowYear = DateTime.now().year;
    final firstYear = value.year < nowYear - 10 ? value.year : nowYear - 10;
    final lastYear = value.year > nowYear ? value.year : nowYear;
    final years = [for (var y = lastYear; y >= firstYear; y--) y];
    final monthNames = [
      for (var m = 1; m <= 12; m++) DateFormat('MMMM').format(DateTime(2000, m)),
    ];

    InputDecoration deco(String text) => InputDecoration(
      labelText: text,
      border: const OutlineInputBorder(),
      contentPadding:
      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: InputDecorator(
            decoration: deco('$label - month'),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isDense: true,
                isExpanded: true,
                value: value.month,
                items: [
                  for (var m = 1; m <= 12; m++)
                    DropdownMenuItem(value: m, child: Text(monthNames[m - 1])),
                ],
                onChanged: (m) {
                  if (m != null) onChanged(DateTime(value.year, m));
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: InputDecorator(
            decoration: deco('Year'),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isDense: true,
                isExpanded: true,
                value: value.year,
                items: [
                  for (final y in years)
                    DropdownMenuItem(value: y, child: Text('$y')),
                ],
                onChanged: (y) {
                  if (y != null) onChanged(DateTime(y, value.month));
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}