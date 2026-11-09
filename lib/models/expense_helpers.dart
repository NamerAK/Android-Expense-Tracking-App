// lib/models/expense_helpers.dart
//
// Shared helpers used by the home, budgets, yearly overview and export screens:
// currency formatting, category icons, Firestore paths, and budget logic.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Shown before every amount in the app. Set it to your currency,
/// e.g. 'Rs ' or '\$'. Leave empty to show plain numbers.
const String kCurrencySymbol = 'Rs. ';

final NumberFormat _amountFormat = NumberFormat('#,##0.00');

String formatAmount(double v) => '$kCurrencySymbol${_amountFormat.format(v)}';

typedef ExpenseDoc = QueryDocumentSnapshot<Map<String, dynamic>>;

IconData iconForCategory(String category) {
  switch (category) {
    case 'Fuel':
      return Icons.local_gas_station_outlined;
    case 'Utility Bills':
      return Icons.receipt_long_outlined;
    case 'Food and grocery':
      return Icons.shopping_cart_outlined;
    case 'Donation':
      return Icons.volunteer_activism_outlined;
    case 'Loan':
      return Icons.account_balance_outlined;
    case 'Family support':
      return Icons.groups_outlined;
    default:
      return Icons.label_outline; // custom categories
  }
}

// -----------------------------------------------------------------------------
// Firestore paths (everything lives under the logged-in user)
// -----------------------------------------------------------------------------
String? get currentUid => FirebaseAuth.instance.currentUser?.uid;

CollectionReference<Map<String, dynamic>> userCollection(
    String uid,
    String name,
    ) =>
    FirebaseFirestore.instance.collection('users').doc(uid).collection(name);

/// Expenses dated from [start] (inclusive) up to [end] (exclusive).
/// A range filter plus orderBy on the same field needs no custom index.
Query<Map<String, dynamic>> expensesBetween(
    String uid,
    DateTime start,
    DateTime end, {
      bool descending = false,
    }) =>
    userCollection(uid, 'expenses')
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThan: Timestamp.fromDate(end))
        .orderBy('date', descending: descending);

// -----------------------------------------------------------------------------
// Budgets: users/{uid}/budgets/{cat_<name>} -> { category, monthly?, yearly? }
// -----------------------------------------------------------------------------
enum BudgetPeriod { monthly, yearly }

enum BudgetState { ok, warning, over }

/// A category counts as "approaching its limit" from this share of the budget.
const double kBudgetWarningThreshold = 0.8;

class Budget {
  const Budget({required this.category, this.monthly, this.yearly});

  final String category;
  final double? monthly;
  final double? yearly;

  double? forPeriod(BudgetPeriod p) =>
      p == BudgetPeriod.monthly ? monthly : yearly;
}

/// Document ID for a category's budget. Prefixed and URL-encoded so category
/// names containing "/" or "." can never produce an invalid Firestore ID.
String budgetDocId(String category) => 'cat_${Uri.encodeComponent(category)}';

/// All budgets of a user, keyed by category name.
Stream<Map<String, Budget>> budgetsStream(String uid) {
  return userCollection(uid, 'budgets').snapshots().map((snap) {
    final result = <String, Budget>{};
    for (final doc in snap.docs) {
      final data = doc.data();
      final category = data['category'] as String?;
      final monthly = (data['monthly'] as num?)?.toDouble();
      final yearly = (data['yearly'] as num?)?.toDouble();
      if (category == null || (monthly == null && yearly == null)) continue;
      result[category] =
          Budget(category: category, monthly: monthly, yearly: yearly);
    }
    return result;
  });
}

BudgetState budgetStateFor(double spent, double budget) {
  if (spent > budget) return BudgetState.over;
  if (spent >= budget * kBudgetWarningThreshold) return BudgetState.warning;
  return BudgetState.ok;
}

Color budgetColor(BuildContext context, BudgetState state) {
  switch (state) {
    case BudgetState.over:
      return Theme.of(context).colorScheme.error;
    case BudgetState.warning:
      return Colors.orange.shade800;
    case BudgetState.ok:
      return Theme.of(context).colorScheme.primary;
  }
}

class BudgetAlert {
  const BudgetAlert({
    required this.category,
    required this.spent,
    required this.budget,
    required this.state,
  });

  final String category;
  final double spent;
  final double budget;
  final BudgetState state;

  double get ratio => budget > 0 ? spent / budget : 0;
}

/// Categories that are over, or close to, their budget for [period].
/// Over-budget categories come first.
List<BudgetAlert> computeBudgetAlerts(
    Map<String, double> spentByCategory,
    Map<String, Budget> budgets,
    BudgetPeriod period,
    ) {
  final alerts = <BudgetAlert>[];
  budgets.forEach((category, budget) {
    final limit = budget.forPeriod(period);
    if (limit == null || limit <= 0) return;
    final spent = spentByCategory[category] ?? 0;
    final state = budgetStateFor(spent, limit);
    if (state != BudgetState.ok) {
      alerts.add(BudgetAlert(
        category: category,
        spent: spent,
        budget: limit,
        state: state,
      ));
    }
  });
  alerts.sort((a, b) {
    if (a.state != b.state) return a.state == BudgetState.over ? -1 : 1;
    return b.ratio.compareTo(a.ratio);
  });
  return alerts;
}