// lib/screens/yearly_overview_screen.dart
//
// Year at a glance: total spent, cash / credit split, a month-by-month bar
// chart, and spending per category (with yearly budget status where set).

import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:newproject/models/expense_helpers.dart';
import 'package:newproject/screens/export_screen.dart';

class YearlyOverviewScreen extends StatefulWidget {
  const YearlyOverviewScreen({super.key});

  @override
  State<YearlyOverviewScreen> createState() => _YearlyOverviewScreenState();
}

class _YearlyOverviewScreenState extends State<YearlyOverviewScreen> {
  late int _year;
  String? _uid;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _expensesStream;
  Stream<Map<String, Budget>>? _budgetsStream;

  @override
  void initState() {
    super.initState();
    _year = DateTime.now().year;
    _uid = currentUid;
    final uid = _uid;
    if (uid != null) {
      _budgetsStream = budgetsStream(uid);
      _expensesStream = _buildStream();
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? _buildStream() {
    final uid = _uid;
    if (uid == null) return null;
    return expensesBetween(uid, DateTime(_year), DateTime(_year + 1)).snapshots();
  }

  bool get _canGoNext => _year < DateTime.now().year;

  void _changeYear(int delta) {
    setState(() {
      _year += delta;
      _expensesStream = _buildStream();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Yearly Overview'),
        actions: [
          IconButton(
            tooltip: 'Export this year',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ExportScreen(
                  initialStart: DateTime(_year, 1),
                  initialEnd: DateTime(_year, 12),
                ),
              ),
            ),
          ),
        ],
      ),
      body: _uid == null
          ? const Center(child: Text('Please log in to see your overview.'))
          : Column(
        children: [
          _buildYearSelector(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildYearSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Previous year',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _changeYear(-1),
          ),
          SizedBox(
            width: 120,
            child: Text(
              '$_year',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Next year',
            icon: const Icon(Icons.chevron_right),
            onPressed: _canGoNext ? () => _changeYear(1) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return StreamBuilder<Map<String, Budget>>(
      stream: _budgetsStream,
      builder: (context, budgetSnap) {
        final budgets = budgetSnap.data ?? const <String, Budget>{};
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _expensesStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(
                child: Text('Could not load expenses. Please try again.'),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return _buildOverview(snap.data!.docs, budgets);
          },
        );
      },
    );
  }

  Widget _buildOverview(
      List<ExpenseDoc> docs,
      Map<String, Budget> budgets,
      ) {
    final theme = Theme.of(context);

    // --- Aggregate -----------------------------------------------------------
    final monthTotals = List<double>.filled(12, 0);
    final catTotals = <String, double>{};
    final catCounts = <String, int>{};
    double total = 0, cash = 0, credit = 0;

    for (final d in docs) {
      final data = d.data();
      final amount = (data['amount'] as num?)?.toDouble() ?? 0;
      final date = (data['date'] as Timestamp?)?.toDate();
      final category = (data['category'] as String?) ?? 'Uncategorized';

      total += amount;
      if (data['paymentType'] == 'credit') {
        credit += amount;
      } else {
        cash += amount;
      }
      if (date != null && date.year == _year) {
        monthTotals[date.month - 1] += amount;
      }
      catTotals[category] = (catTotals[category] ?? 0) + amount;
      catCounts[category] = (catCounts[category] ?? 0) + 1;
    }

    if (docs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bar_chart, size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('No expenses recorded in $_year'),
            ],
          ),
        ),
      );
    }

    final now = DateTime.now();
    final monthsCounted = _year == now.year ? now.month : 12;
    final average = total / monthsCounted;

    var highestIndex = 0;
    for (var i = 1; i < 12; i++) {
      if (monthTotals[i] > monthTotals[highestIndex]) highestIndex = i;
    }

    final rows = catTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // --- Yearly budget alerts ------------------------------------------------
    final alerts = computeBudgetAlerts(catTotals, budgets, BudgetPeriod.yearly);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        if (alerts.isNotEmpty) _buildAlertsCard(alerts),
        _buildSummaryCard(
          total: total,
          cash: cash,
          credit: credit,
          count: docs.length,
          average: average,
          monthsCounted: monthsCounted,
          highestMonth: DateFormat('MMMM').format(DateTime(_year, highestIndex + 1)),
          highestAmount: monthTotals[highestIndex],
        ),
        const SizedBox(height: 16),
        Text('Month by month', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _buildChart(monthTotals, highestIndex),
        const SizedBox(height: 16),
        Text('Spending by category', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final row in rows)
          _buildCategoryRow(
            category: row.key,
            amount: row.value,
            count: catCounts[row.key] ?? 0,
            yearTotal: total,
            yearlyBudget: budgets[row.key]?.yearly,
          ),
      ],
    );
  }

  Widget _buildAlertsCard(List<BudgetAlert> alerts) {
    final theme = Theme.of(context);
    final isOver = alerts.any((a) => a.state == BudgetState.over);
    final bg =
    isOver ? theme.colorScheme.errorContainer : Colors.orange.shade100;
    final fg =
    isOver ? theme.colorScheme.onErrorContainer : Colors.orange.shade900;

    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isOver
                        ? 'Yearly budget exceeded'
                        : 'Approaching yearly budget limit',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: fg, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final a in alerts.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  a.state == BudgetState.over
                      ? '${a.category}: over by ${formatAmount(a.spent - a.budget)}'
                      : '${a.category}: ${(a.ratio * 100).round()}% of budget used',
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard({
    required double total,
    required double cash,
    required double credit,
    required int count,
    required double average,
    required int monthsCounted,
    required String highestMonth,
    required double highestAmount,
  }) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onPrimaryContainer;

    Widget item(String title, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: theme.textTheme.labelMedium?.copyWith(color: color)),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.titleSmall
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );

    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total spent in $_year',
                style: theme.textTheme.labelLarge?.copyWith(color: color)),
            const SizedBox(height: 4),
            Text(
              formatAmount(total),
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold, color: color),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: item('Cash', formatAmount(cash))),
                Expanded(child: item('Credit', formatAmount(credit))),
                Expanded(child: item('Entries', '$count')),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: item(
                    'Monthly average',
                    formatAmount(average),
                  ),
                ),
                Expanded(
                  child: item(
                    'Highest month',
                    '$highestMonth (${formatAmount(highestAmount)})',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Simple bar chart: one bar per month, tallest = highest month.
  Widget _buildChart(List<double> months, int highestIndex) {
    final theme = Theme.of(context);
    const chartHeight = 140.0;
    final maxValue = months.fold<double>(0, math.max);
    final compact = NumberFormat.compact();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: SizedBox(
          height: 190,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 12; i++)
                Expanded(
                  child: Tooltip(
                    message:
                    '${DateFormat('MMMM').format(DateTime(_year, i + 1))}: ${formatAmount(months[i])}',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          months[i] > 0 ? compact.format(months[i]) : '',
                          style: const TextStyle(fontSize: 9),
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                        ),
                        const SizedBox(height: 2),
                        Container(
                          height: maxValue > 0
                              ? math.max(2.0, months[i] / maxValue * chartHeight)
                              : 2.0,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: i == highestIndex && months[i] > 0
                                ? theme.colorScheme.primary
                                : theme.colorScheme.primary.withOpacity(0.45),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          DateFormat('MMM').format(DateTime(_year, i + 1)),
                          style: const TextStyle(fontSize: 10),
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryRow({
    required String category,
    required double amount,
    required int count,
    required double yearTotal,
    required double? yearlyBudget,
  }) {
    final theme = Theme.of(context);
    // Non-null copy of the budget (0 = none), so the maths below is null-safe.
    final double budget =
    (yearlyBudget != null && yearlyBudget > 0) ? yearlyBudget : 0;
    final hasBudget = budget > 0;

    final state =
    hasBudget ? budgetStateFor(amount, budget) : BudgetState.ok;
    final barColor = hasBudget
        ? budgetColor(context, state)
        : theme.colorScheme.primary;
    final fraction = hasBudget
        ? (amount / budget).clamp(0.0, 1.0)
        : (yearTotal > 0 ? amount / yearTotal : 0.0);
    final percentText = hasBudget
        ? '${(amount / budget * 100).round()}% of budget'
        : '${(yearTotal > 0 ? amount / yearTotal * 100 : 0).round()}% of total';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  foregroundColor: theme.colorScheme.onSecondaryContainer,
                  child: Icon(iconForCategory(category), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(category, style: theme.textTheme.titleSmall),
                      Text(
                        hasBudget
                            ? '$count ${count == 1 ? 'entry' : 'entries'} • '
                            'Yearly budget ${formatAmount(budget)}'
                            : '$count ${count == 1 ? 'entry' : 'entries'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatAmount(amount),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      state == BudgetState.over
                          ? 'Over by ${formatAmount(amount - budget)}'
                          : percentText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: state == BudgetState.ok ? null : barColor,
                        fontWeight:
                        state == BudgetState.ok ? null : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              color: barColor,
              backgroundColor: barColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(3),
            ),
          ],
        ),
      ),
    );
  }
}