// lib/screens/home_screen.dart
//
// Home screen: the logged-in user's expenses for one month at a time.
//  - Month navigation, monthly total with cash / credit split
//  - Search (category, description, amount, cash/credit) and category filter
//  - "By category" summary for the month (tap a category to filter the list)
//  - Tap an expense to edit it; swipe left to delete (with undo)
//  - Small cloud icon on entries that have not synced to the server yet
//
// Reads from: users/{uid}/expenses  (written by RecordExpenseScreen)

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:newproject/models/expense_helpers.dart';
import 'package:newproject/screens/budgets_screen.dart';
import 'package:newproject/screens/export_screen.dart';
import 'package:newproject/screens/record_expense_screen.dart';
import 'package:newproject/screens/yearly_overview_screen.dart';
import 'package:newproject/services/auth_service.dart';

typedef _ExpenseDoc = QueryDocumentSnapshot<Map<String, dynamic>>;

enum _HomeView { list, categories }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late DateTime _month; // always the 1st day of the month being viewed
  Stream<QuerySnapshot<Map<String, dynamic>>>? _stream;
  Stream<Map<String, Budget>>? _budgetStream;

  final _searchController = TextEditingController();
  String _query = '';
  String? _categoryFilter; // null = all categories
  _HomeView _view = _HomeView.list;

  final _money = NumberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _stream = _buildStream();
    final uid = currentUid;
    if (uid != null) _budgetStream = budgetsStream(uid);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? _buildStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;

    final start = _month;
    final end = DateTime(_month.year, _month.month + 1);

    // Range filter + orderBy on the same field needs no custom index.
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('expenses')
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThan: Timestamp.fromDate(end))
        .orderBy('date', descending: true)
    // Lets the list update when a pending (offline) write finishes syncing.
        .snapshots(includeMetadataChanges: true);
  }

  bool get _canGoNext {
    final now = DateTime.now();
    return _month.isBefore(DateTime(now.year, now.month));
  }

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _stream = _buildStream();
    });
  }

  String _amountText(double v) => '$kCurrencySymbol${_money.format(v)}';

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _categoryFilter = null;
    });
  }

  void _openEditor(_ExpenseDoc doc) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RecordExpenseScreen(expense: doc)),
    );
  }

  // ---------------------------------------------------------------------------
  // Delete (offline-first, with undo)
  // ---------------------------------------------------------------------------
  Future<bool> _confirmDelete() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete expense?'),
        content: const Text('This expense will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _deleteExpense(_ExpenseDoc doc) {
    final ref = doc.reference;
    final backup = Map<String, dynamic>.from(doc.data());

    // Not awaited: completes only after server acknowledgement.
    ref.delete().catchError((Object e) {
      debugPrint('Expense delete sync failed: $e');
    });

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Expense deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              ref.set(backup).catchError((Object e) {
                debugPrint('Undo sync failed: $e');
              });
            },
          ),
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------
  String _categoryOf(Map<String, dynamic> data) =>
      (data['category'] as String?) ?? 'Uncategorized';

  bool _matches(_ExpenseDoc doc, String? categoryFilter) {
    final data = doc.data();
    final category = _categoryOf(data);
    if (categoryFilter != null && category != categoryFilter) return false;

    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;

    final description = (data['description'] as String?) ?? '';
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;
    final haystack = [
      category,
      description,
      data['paymentType'] == 'credit' ? 'credit' : 'cash',
      amount.toStringAsFixed(2),
      _money.format(amount),
    ].join(' ').toLowerCase();
    return haystack.contains(q);
  }

  // ---------------------------------------------------------------------------
  // Menu
  // ---------------------------------------------------------------------------
  Future<void> _onMenuSelected(String value) async {
    switch (value) {
      case 'budgets':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BudgetsScreen()),
        );
        break;
      case 'yearly':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const YearlyOverviewScreen()),
        );
        break;
      case 'export':
      // Pre-selects the month currently shown on the home screen.
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                ExportScreen(initialStart: _month, initialEnd: _month),
          ),
        );
        break;
      case 'logout':
        await AuthService.logout();
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/login');
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Menu',
            onSelected: _onMenuSelected,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'budgets',
                child: ListTile(
                  leading: Icon(Icons.savings_outlined),
                  title: Text('Budgets'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'yearly',
                child: ListTile(
                  leading: Icon(Icons.bar_chart),
                  title: Text('Yearly overview'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  leading: Icon(Icons.file_download_outlined),
                  title: Text('Export to spreadsheet'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Log out'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add Expense'),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RecordExpenseScreen()),
          );
        },
      ),
      body: Column(
        children: [
          _buildMonthSelector(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildMonthSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _changeMonth(-1),
          ),
          SizedBox(
            width: 160,
            child: Text(
              DateFormat('MMMM yyyy').format(_month),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Next month',
            icon: const Icon(Icons.chevron_right),
            onPressed: _canGoNext ? () => _changeMonth(1) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final stream = _stream;
    if (stream == null) {
      return const Center(child: Text('Please log in to see your expenses.'));
    }

    return StreamBuilder<Map<String, Budget>>(
      stream: _budgetStream,
      builder: (context, budgetSnap) {
        final budgets = budgetSnap.data ?? const <String, Budget>{};
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: stream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Could not load expenses. Please try again later.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            // Newest date first; within a day, newest entry first. A null
            // createdAt means the entry is still pending, so it counts as newest.
            final allDocs = [...snapshot.data!.docs]..sort((a, b) {
              final da = (a.data()['date'] as Timestamp?)?.toDate();
              final db = (b.data()['date'] as Timestamp?)?.toDate();
              if (da != null && db != null) {
                final byDate = db.compareTo(da);
                if (byDate != 0) return byDate;
              }
              final ca = (a.data()['createdAt'] as Timestamp?)?.toDate() ??
                  DateTime.now();
              final cb = (b.data()['createdAt'] as Timestamp?)?.toDate() ??
                  DateTime.now();
              return cb.compareTo(ca);
            });

            final categories = {for (final d in allDocs) _categoryOf(d.data())}
                .toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

            // A filter for a category that has no entries this month is ignored.
            final activeFilter =
            categories.contains(_categoryFilter) ? _categoryFilter : null;

            final filtered =
            allDocs.where((d) => _matches(d, activeFilter)).toList();
            final isFiltering = activeFilter != null || _query.trim().isNotEmpty;

            // Budget warnings for this month (ignores search / category filter).
            final spentByCategory = <String, double>{};
            for (final d in allDocs) {
              final c = _categoryOf(d.data());
              spentByCategory[c] = (spentByCategory[c] ?? 0) +
                  ((d.data()['amount'] as num?)?.toDouble() ?? 0);
            }
            final alerts = computeBudgetAlerts(
              spentByCategory,
              budgets,
              BudgetPeriod.monthly,
            );

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<_HomeView>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: _HomeView.list,
                          icon: Icon(Icons.list),
                          label: Text('Expenses'),
                        ),
                        ButtonSegment(
                          value: _HomeView.categories,
                          icon: Icon(Icons.pie_chart_outline),
                          label: Text('By category'),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: (s) => setState(() => _view = s.first),
                    ),
                  ),
                ),
                if (_view == _HomeView.list) ...[
                  _buildSearchField(),
                  if (categories.isNotEmpty)
                    _buildCategoryChips(categories, activeFilter),
                  Expanded(child: _buildExpenseList(filtered, isFiltering, alerts)),
                ] else
                  Expanded(child: _buildCategorySummary(allDocs, alerts)),
              ],
            );
          },
        );
      },
    );
  }

  // --- Search & filter -------------------------------------------------------
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: 'Search description, category or amount',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
            tooltip: 'Clear search',
            icon: const Icon(Icons.close),
            onPressed: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
          isDense: true,
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(28)),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryChips(List<String> categories, String? active) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('All'),
              selected: active == null,
              onSelected: (_) => setState(() => _categoryFilter = null),
            ),
          ),
          for (final c in categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(c),
                selected: active == c,
                onSelected: (_) => setState(() => _categoryFilter = c),
              ),
            ),
        ],
      ),
    );
  }

  // --- Expenses list ---------------------------------------------------------
  Widget _buildExpenseList(
      List<_ExpenseDoc> docs,
      bool isFiltering,
      List<BudgetAlert> alerts,
      ) {
    final totals = _Totals.from(docs);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        if (alerts.isNotEmpty) _buildBudgetAlerts(alerts),
        _buildSummaryCard(
          label: isFiltering ? 'Total (filtered)' : 'Total spent',
          totals: totals,
        ),
        const SizedBox(height: 8),
        if (docs.isEmpty)
          isFiltering ? _buildNoMatches() : _buildEmptyMonth()
        else
          for (final doc in docs) _buildExpenseTile(doc),
      ],
    );
  }

  Widget _buildSummaryCard({required String label, required _Totals totals}) {
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
          style: theme.textTheme.titleSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
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
            Text(label,
                style: theme.textTheme.labelLarge?.copyWith(color: color)),
            const SizedBox(height: 4),
            Text(
              _amountText(totals.total),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: item('Cash', _amountText(totals.cash))),
                Expanded(child: item('Credit', _amountText(totals.credit))),
                Expanded(child: item('Entries', '${totals.count}')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMonth() => _emptyState(
    icon: Icons.receipt_long_outlined,
    title: 'No expenses this month',
    subtitle: 'Tap "Add Expense" to record one.',
  );

  Widget _buildNoMatches() => _emptyState(
    icon: Icons.search_off,
    title: 'No matching expenses',
    subtitle: 'Try a different search or category.',
    action: TextButton(
      onPressed: _clearFilters,
      child: const Text('Clear search and filter'),
    ),
  );

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(icon, size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(title),
          const SizedBox(height: 4),
          Text(subtitle),
          if (action != null) action,
        ],
      ),
    );
  }

  Widget _buildExpenseTile(_ExpenseDoc doc) {
    final theme = Theme.of(context);
    final data = doc.data();

    final category = _categoryOf(data);
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;
    final date = (data['date'] as Timestamp?)?.toDate();
    final description = (data['description'] as String?) ?? '';
    final isCredit = data['paymentType'] == 'credit';
    final isPending = doc.metadata.hasPendingWrites;

    final subtitleParts = <String>[
      if (date != null) DateFormat('EEE, dd MMM').format(date),
      if (description.isNotEmpty) description,
    ];

    return Dismissible(
      key: ValueKey(doc.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(),
      onDismissed: (_) => _deleteExpense(doc),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.delete_outline,
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: ListTile(
          onTap: () => _openEditor(doc),
          leading: CircleAvatar(
            backgroundColor: theme.colorScheme.secondaryContainer,
            foregroundColor: theme.colorScheme.onSecondaryContainer,
            child: Icon(iconForCategory(category)),
          ),
          title: Text(category),
          subtitle: subtitleParts.isEmpty
              ? null
              : Text(
            subtitleParts.join(' • '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _amountText(amount),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isPending) ...[
                    Tooltip(
                      message: 'Waiting to sync',
                      child: Icon(
                        Icons.cloud_off_outlined,
                        size: 14,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    isCredit ? 'Credit' : 'Cash',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isCredit
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.secondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Budget warnings -------------------------------------------------------
  Widget _buildBudgetAlerts(List<BudgetAlert> alerts) {
    final theme = Theme.of(context);
    final overCount = alerts.where((a) => a.state == BudgetState.over).length;
    final isOver = overCount > 0;
    final bg =
    isOver ? theme.colorScheme.errorContainer : Colors.orange.shade100;
    final fg =
    isOver ? theme.colorScheme.onErrorContainer : Colors.orange.shade900;

    final title = isOver
        ? (overCount == 1
        ? '1 category is over budget'
        : '$overCount categories are over budget')
        : 'Approaching budget limit';

    return Card(
      color: bg,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BudgetsScreen()),
        ),
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
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: fg),
                ],
              ),
              const SizedBox(height: 6),
              for (final a in alerts.take(4))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    a.state == BudgetState.over
                        ? '${a.category}: over by ${formatAmount(a.spent - a.budget)} '
                        '(${formatAmount(a.spent)} of ${formatAmount(a.budget)})'
                        : '${a.category}: ${(a.ratio * 100).round()}% of budget used',
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                  ),
                ),
              if (alerts.length > 4)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '+ ${alerts.length - 4} more',
                    style: theme.textTheme.bodySmall?.copyWith(color: fg),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Category-wise summary -------------------------------------------------
  Widget _buildCategorySummary(
      List<_ExpenseDoc> allDocs,
      List<BudgetAlert> alerts,
      ) {
    final theme = Theme.of(context);
    final monthTotals = _Totals.from(allDocs);

    // Sum and count per category for the whole month.
    final sums = <String, double>{};
    final counts = <String, int>{};
    for (final d in allDocs) {
      final c = _categoryOf(d.data());
      sums[c] = (sums[c] ?? 0) + ((d.data()['amount'] as num?)?.toDouble() ?? 0);
      counts[c] = (counts[c] ?? 0) + 1;
    }
    final rows = sums.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)); // biggest spend first

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        if (alerts.isNotEmpty) _buildBudgetAlerts(alerts),
        _buildSummaryCard(label: 'Total spent', totals: monthTotals),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          _buildEmptyMonth()
        else ...[
          Text('Spending by category', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Tap a category to see its expenses.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final row in rows)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() {
                  _categoryFilter = row.key;
                  _view = _HomeView.list;
                }),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: theme.colorScheme.secondaryContainer,
                            foregroundColor:
                            theme.colorScheme.onSecondaryContainer,
                            child: Icon(iconForCategory(row.key), size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(row.key,
                                    style: theme.textTheme.titleSmall),
                                Text(
                                  '${counts[row.key]} '
                                      '${counts[row.key] == 1 ? 'entry' : 'entries'}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _amountText(row.value),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                monthTotals.total > 0
                                    ? '${(row.value / monthTotals.total * 100).toStringAsFixed(0)}%'
                                    : '',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: monthTotals.total > 0
                            ? row.value / monthTotals.total
                            : 0,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// Total, cash / credit split and entry count for a set of expenses.
class _Totals {
  const _Totals(this.total, this.cash, this.credit, this.count);

  final double total;
  final double cash;
  final double credit;
  final int count;

  factory _Totals.from(List<_ExpenseDoc> docs) {
    double cash = 0, credit = 0;
    for (final d in docs) {
      final amount = (d.data()['amount'] as num?)?.toDouble() ?? 0;
      if (d.data()['paymentType'] == 'credit') {
        credit += amount;
      } else {
        cash += amount;
      }
    }
    return _Totals(cash + credit, cash, credit, docs.length);
  }
}