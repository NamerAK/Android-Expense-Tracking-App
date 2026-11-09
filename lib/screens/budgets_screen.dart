// lib/screens/budgets_screen.dart
//
// Set a monthly and/or yearly budget for each expense category and see how
// much has been spent. Categories turn orange at 80% of the budget and red
// once the budget is exceeded.
//
// Stored at: users/{uid}/budgets/{cat_<category>} -> { category, monthly?, yearly? }

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:newproject/models/expense_helpers.dart';
import 'package:newproject/screens/record_expense_screen.dart'
    show kDefaultCategories;

class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({super.key});

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  BudgetPeriod _period = BudgetPeriod.monthly;
  late DateTime _month; // first day of the month being viewed
  late int _year;

  String? _uid;
  Stream<Map<String, Budget>>? _budgetsStream;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _categoriesStream;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _expensesStream;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _year = now.year;

    _uid = currentUid;
    final uid = _uid;
    if (uid != null) {
      _budgetsStream = budgetsStream(uid);
      _categoriesStream = userCollection(uid, 'categories').snapshots();
      _expensesStream = _buildExpensesStream();
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? _buildExpensesStream() {
    final uid = _uid;
    if (uid == null) return null;
    final start = _period == BudgetPeriod.monthly
        ? _month
        : DateTime(_year);
    final end = _period == BudgetPeriod.monthly
        ? DateTime(_month.year, _month.month + 1)
        : DateTime(_year + 1);
    return expensesBetween(uid, start, end).snapshots();
  }

  bool get _canGoNext {
    final now = DateTime.now();
    return _period == BudgetPeriod.monthly
        ? _month.isBefore(DateTime(now.year, now.month))
        : _year < now.year;
  }

  void _step(int delta) {
    setState(() {
      if (_period == BudgetPeriod.monthly) {
        _month = DateTime(_month.year, _month.month + delta);
      } else {
        _year += delta;
      }
      _expensesStream = _buildExpensesStream();
    });
  }

  String get _periodWord => _period == BudgetPeriod.monthly ? 'monthly' : 'yearly';

  // ---------------------------------------------------------------------------
  // Editing a budget (offline-first: not awaited)
  // ---------------------------------------------------------------------------
  Future<void> _editBudget(String category, double? current) async {
    final result = await showDialog<_BudgetDialogResult>(
      context: context,
      builder: (_) => _BudgetDialog(
        title: '${_period == BudgetPeriod.monthly ? 'Monthly' : 'Yearly'} budget',
        category: category,
        initial: current,
      ),
    );
    if (result == null) return;
    _saveBudget(category, result.remove ? null : result.amount);
  }

  void _saveBudget(String category, double? amount) {
    final uid = _uid;
    if (uid == null) return;
    final field = _period == BudgetPeriod.monthly ? 'monthly' : 'yearly';

    userCollection(uid, 'budgets').doc(budgetDocId(category)).set({
      'category': category,
      field: amount ?? FieldValue.delete(),
    }, SetOptions(merge: true)).catchError((Object e) {
      debugPrint('Budget sync failed: $e');
    });
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Budgets')),
      body: _uid == null
          ? const Center(child: Text('Please log in to manage budgets.'))
          : Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<BudgetPeriod>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: BudgetPeriod.monthly,
                    label: Text('Monthly'),
                    icon: Icon(Icons.calendar_view_month),
                  ),
                  ButtonSegment(
                    value: BudgetPeriod.yearly,
                    label: Text('Yearly'),
                    icon: Icon(Icons.calendar_today),
                  ),
                ],
                selected: {_period},
                onSelectionChanged: (s) => setState(() {
                  _period = s.first;
                  _expensesStream = _buildExpensesStream();
                }),
              ),
            ),
          ),
          _buildPeriodSelector(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildPeriodSelector() {
    final label = _period == BudgetPeriod.monthly
        ? DateFormat('MMMM yyyy').format(_month)
        : '$_year';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Previous',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _step(-1),
          ),
          SizedBox(
            width: 160,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Next',
            icon: const Icon(Icons.chevron_right),
            onPressed: _canGoNext ? () => _step(1) : null,
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
          stream: _categoriesStream,
          builder: (context, catSnap) {
            final customNames = <String>[
              for (final d in catSnap.data?.docs ?? const [])
                if ((d.data()['name'] as String?)?.isNotEmpty ?? false)
                  d.data()['name'] as String,
            ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _expensesStream,
              builder: (context, expSnap) {
                if (expSnap.hasError) {
                  return const Center(
                    child: Text('Could not load expenses. Please try again.'),
                  );
                }
                if (!expSnap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final spent = <String, double>{};
                for (final d in expSnap.data!.docs) {
                  final c = (d.data()['category'] as String?) ?? 'Uncategorized';
                  spent[c] = (spent[c] ?? 0) +
                      ((d.data()['amount'] as num?)?.toDouble() ?? 0);
                }

                // Defaults, then custom categories, then any other category
                // that has spending or a budget (e.g. a removed custom one).
                final categories = <String>[
                  ...kDefaultCategories,
                  ...customNames,
                ];
                final extras = <String>{...spent.keys, ...budgets.keys}
                    .where((c) => !categories.contains(c))
                    .toList()
                  ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                categories.addAll(extras);

                return _buildList(categories, budgets, spent);
              },
            );
          },
        );
      },
    );
  }

  Widget _buildList(
      List<String> categories,
      Map<String, Budget> budgets,
      Map<String, double> spent,
      ) {
    // Totals across categories that have a budget for this period.
    double totalBudget = 0, spentOnBudgeted = 0;
    int overCount = 0, warnCount = 0;
    for (final c in categories) {
      final limit = budgets[c]?.forPeriod(_period);
      if (limit == null || limit <= 0) continue;
      final s = spent[c] ?? 0;
      totalBudget += limit;
      spentOnBudgeted += s;
      final state = budgetStateFor(s, limit);
      if (state == BudgetState.over) overCount++;
      if (state == BudgetState.warning) warnCount++;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _buildSummaryCard(
          totalBudget: totalBudget,
          spentOnBudgeted: spentOnBudgeted,
          overCount: overCount,
          warnCount: warnCount,
        ),
        const SizedBox(height: 8),
        for (final c in categories)
          _buildCategoryRow(
            category: c,
            limit: budgets[c]?.forPeriod(_period),
            spent: spent[c] ?? 0,
          ),
      ],
    );
  }

  Widget _buildSummaryCard({
    required double totalBudget,
    required double spentOnBudgeted,
    required int overCount,
    required int warnCount,
  }) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onPrimaryContainer;

    if (totalBudget <= 0) {
      return Card(
        color: theme.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No $_periodWord budgets set yet. Tap a category below to set one.',
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      );
    }

    final left = totalBudget - spentOnBudgeted;
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Total $_periodWord budget',
              style: theme.textTheme.labelLarge?.copyWith(color: color),
            ),
            const SizedBox(height: 4),
            Text(
              formatAmount(totalBudget),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Spent on budgeted categories: ${formatAmount(spentOnBudgeted)}'
                  ' • ${left >= 0 ? '${formatAmount(left)} left' : 'over by ${formatAmount(-left)}'}',
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
            if (overCount > 0 || warnCount > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18,
                      color: overCount > 0
                          ? theme.colorScheme.error
                          : Colors.orange.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      [
                        if (overCount > 0)
                          '$overCount over budget',
                        if (warnCount > 0)
                          '$warnCount close to the limit',
                      ].join(' • '),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: overCount > 0
                            ? theme.colorScheme.error
                            : Colors.orange.shade900,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryRow({
    required String category,
    required double? limit,
    required double spent,
  }) {
    final theme = Theme.of(context);
    // Non-null copy of the budget (0 = none), so the maths below is null-safe.
    final double lim = (limit != null && limit > 0) ? limit : 0;
    final hasBudget = lim > 0;

    late final BudgetState state;
    late final Color stateColor;
    String subtitle;
    String trailing = '';

    if (hasBudget) {
      state = budgetStateFor(spent, lim);
      stateColor = budgetColor(context, state);
      subtitle = 'Spent ${formatAmount(spent)} of ${formatAmount(lim)}';
      if (state == BudgetState.over) {
        trailing = 'Over by ${formatAmount(spent - lim)}';
      } else {
        trailing = '${formatAmount(lim - spent)} left';
      }
    } else {
      state = BudgetState.ok;
      stateColor = theme.colorScheme.outline;
      subtitle = spent > 0
          ? 'No budget set • Spent ${formatAmount(spent)}'
          : 'No budget set';
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _editBudget(category, hasBudget ? limit : null),
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
                        Text(subtitle, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  if (hasBudget)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (state != BudgetState.ok)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(Icons.warning_amber_rounded,
                                    size: 16, color: stateColor),
                              ),
                            Text(
                              trailing,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: stateColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${(spent / lim * 100).round()}% used',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    )
                  else
                    Icon(Icons.add_circle_outline,
                        color: theme.colorScheme.primary),
                ],
              ),
              if (hasBudget) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: (spent / lim).clamp(0.0, 1.0),
                  minHeight: 6,
                  color: stateColor,
                  backgroundColor: stateColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Dialog to set, change or remove one budget
// =============================================================================
class _BudgetDialogResult {
  const _BudgetDialogResult.save(this.amount) : remove = false;
  const _BudgetDialogResult.remove()
      : amount = null,
        remove = true;

  final double? amount;
  final bool remove;
}

class _BudgetDialog extends StatefulWidget {
  const _BudgetDialog({
    required this.title,
    required this.category,
    required this.initial,
  });

  final String title;
  final String category;
  final double? initial;

  @override
  State<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<_BudgetDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initial == null
          ? ''
          : (widget.initial! % 1 == 0
          ? widget.initial!.toStringAsFixed(0)
          : widget.initial!.toStringAsFixed(2)),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = double.tryParse(_controller.text.trim());
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter an amount greater than 0');
      return;
    }
    Navigator.pop(context, _BudgetDialogResult.save(value));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.title}: ${widget.category}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
        ],
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Budget amount',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, const _BudgetDialogResult.remove()),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}