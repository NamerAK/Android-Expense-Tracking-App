// lib/screens/record_expense_screen.dart
//
// Required dependencies (pubspec.yaml):
//   cloud_firestore: any
//   firebase_auth: any
//   intl: any
//
// Firestore structure (per user, so nothing is shared globally):
//   users/{uid}/categories/{categoryId} -> { name, createdAt }          (custom categories only)
//   users/{uid}/expenses/{expenseId}    -> { category, amount, paymentType, date, description, createdAt }
//
// Default categories are constants in code, never stored in Firestore,
// so they can never be deleted by the user.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Built-in categories. These cannot be removed.
const List<String> kDefaultCategories = [
  'Fuel',
  'Utility Bills',
  'Food and grocery',
  'Donation',
  'Loan',
  'Family support',
];

/// Sentinel dropdown value that opens the add/remove category sheet.
const String _kManageCategories = '__manage_categories__';

enum PaymentType { cash, credit }

class RecordExpenseScreen extends StatefulWidget {
  const RecordExpenseScreen({super.key, this.expense});

  /// When provided, the screen edits this expense instead of creating a new one.
  final DocumentSnapshot<Map<String, dynamic>>? expense;

  @override
  State<RecordExpenseScreen> createState() => _RecordExpenseScreenState();
}

class _RecordExpenseScreenState extends State<RecordExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _dateController = TextEditingController();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? _selectedCategory;
  String? _originalCategory; // category the expense had when editing began
  PaymentType _paymentType = PaymentType.cash;
  DateTime _selectedDate = DateTime.now();

  bool get _isEditing => widget.expense != null;

  String get _uid => _auth.currentUser!.uid;

  CollectionReference<Map<String, dynamic>> get _categoriesRef =>
      _db.collection('users').doc(_uid).collection('categories');

  CollectionReference<Map<String, dynamic>> get _expensesRef =>
      _db.collection('users').doc(_uid).collection('expenses');

  @override
  void initState() {
    super.initState();

    final existing = widget.expense?.data();
    if (existing != null) {
      _selectedCategory = existing['category'] as String?;
      _originalCategory = _selectedCategory;
      final amount = (existing['amount'] as num?)?.toDouble();
      if (amount != null) _amountController.text = amount.toStringAsFixed(2);
      _paymentType =
      existing['paymentType'] == 'credit' ? PaymentType.credit : PaymentType.cash;
      final date = (existing['date'] as Timestamp?)?.toDate();
      if (date != null) _selectedDate = date;
      _descriptionController.text = (existing['description'] as String?) ?? '';
    }

    _dateController.text = _formatDate(_selectedDate);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime d) => DateFormat('dd MMM yyyy').format(d);

  // ---------------------------------------------------------------------------
  // Date picker
  // ---------------------------------------------------------------------------
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        _dateController.text = _formatDate(picked);
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Save expense
  // ---------------------------------------------------------------------------
  /// Offline-first save (creates a new expense, or updates the one being edited).
  ///
  /// The write is committed to Firestore's on-device cache immediately and is
  /// synced to the server whenever a connection is available. We deliberately
  /// do NOT await the returned Future: it only completes after the server
  /// acknowledges the write, which would hang the UI while offline (and invite
  /// duplicate saves).
  void _saveExpense() {
    if (!_formKey.currentState!.validate()) return;

    final fields = <String, dynamic>{
      'category': _selectedCategory,
      'amount': double.parse(_amountController.text.trim()),
      'paymentType': _paymentType.name, // 'cash' or 'credit'
      'date': Timestamp.fromDate(
        DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day),
      ),
      'description': _descriptionController.text.trim(),
    };

    if (_isEditing) {
      // Keep the original createdAt; just record when it was last changed.
      _expensesRef.doc(widget.expense!.id).update({
        ...fields,
        'updatedAt': FieldValue.serverTimestamp(),
      }).catchError((Object e) {
        // Only reached if the server later rejects the write.
        debugPrint('Expense update sync failed: $e');
      });
    } else {
      // Document ID is generated locally, so no network is needed.
      _expensesRef.doc().set({
        ...fields,
        'createdAt': FieldValue.serverTimestamp(),
      }).catchError((Object e) {
        // Only reached if the server later rejects the write (e.g. security rules).
        debugPrint('Expense sync failed: $e');
      });
    }

    _showSnack(_isEditing ? 'Expense updated' : 'Expense saved');

    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    } else {
      _resetForm();
    }
  }

  void _resetForm() {
    _formKey.currentState?.reset();
    _amountController.clear();
    _descriptionController.clear();
    setState(() {
      _selectedCategory = null;
      _paymentType = PaymentType.cash;
      _selectedDate = DateTime.now();
      _dateController.text = _formatDate(_selectedDate);
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Category management (bottom sheet)
  // ---------------------------------------------------------------------------
  Future<void> _openManageCategories() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _ManageCategoriesSheet(
        categoriesRef: _categoriesRef,
        onCategoryDeleted: (name) {
          // If the deleted category was selected, clear the selection.
          if (_selectedCategory == name && mounted) {
            setState(() => _selectedCategory = null);
          }
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    // Expenses are stored per user, so a logged-in user is required.
    // authStateChanges() also covers the short moment after app start (or a
    // page refresh on web) when Firebase is still restoring the saved login.
    return StreamBuilder<User?>(
      stream: _auth.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(_isEditing ? 'Edit Expense' : 'Add Expense')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (authSnap.data == null) {
          return Scaffold(
            appBar: AppBar(title: Text(_isEditing ? 'Edit Expense' : 'Add Expense')),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Please log in to record expenses.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        return _buildScreen(context);
      },
    );
  }

  Widget _buildScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit Expense' : 'Add Expense')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildCategoryField(),
              const SizedBox(height: 16),
              _buildAmountField(),
              const SizedBox(height: 16),
              _buildPaymentTypeField(),
              const SizedBox(height: 16),
              _buildDateField(),
              const SizedBox(height: 16),
              _buildDescriptionField(),
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: _saveExpense,
                  icon: const Icon(Icons.check),
                  label: Text(_isEditing ? 'Update Expense' : 'Save Expense'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryField() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _categoriesRef.snapshots(),
      builder: (context, snapshot) {
        final custom = <String>[
          for (final doc in snapshot.data?.docs ?? const [])
            if ((doc.data()['name'] as String?)?.isNotEmpty ?? false)
              doc.data()['name'] as String,
        ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

        final all = [...kDefaultCategories, ...custom];
        // Editing an expense whose custom category was later removed: keep that
        // category selectable so the expense is not forced into another one.
        if (_originalCategory != null && !all.contains(_originalCategory)) {
          all.add(_originalCategory!);
        }

        // Guard: selected value must exist among the items.
        final value = all.contains(_selectedCategory) ? _selectedCategory : null;

        return DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Expense Category',
            prefixIcon: Icon(Icons.category_outlined),
            border: OutlineInputBorder(),
          ),
          items: [
            ...all.map(
                  (c) => DropdownMenuItem<String>(value: c, child: Text(c)),
            ),
            const DropdownMenuItem<String>(
              value: _kManageCategories,
              child: Row(
                children: [
                  Icon(Icons.edit_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Add / Remove category'),
                ],
              ),
            ),
          ],
          onChanged: (selected) {
            if (selected == _kManageCategories) {
              _openManageCategories();
              return;
            }
            setState(() => _selectedCategory = selected);
          },
          validator: (v) =>
          (v == null || v.isEmpty) ? 'Please select a category' : null,
        );
      },
    );
  }

  Widget _buildAmountField() {
    return TextFormField(
      controller: _amountController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
      ],
      decoration: const InputDecoration(
        labelText: 'Amount',
        prefixIcon: Icon(Icons.payments_outlined),
        border: OutlineInputBorder(),
      ),
      validator: (v) {
        final text = v?.trim() ?? '';
        if (text.isEmpty) return 'Please enter an amount';
        final amount = double.tryParse(text);
        if (amount == null || amount <= 0) {
          return 'Enter a valid amount greater than 0';
        }
        return null;
      },
    );
  }

  Widget _buildPaymentTypeField() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Payment Type',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: Row(
        children: [
          Expanded(
            child: RadioListTile<PaymentType>(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cash'),
              value: PaymentType.cash,
              groupValue: _paymentType,
              onChanged: (v) => setState(() => _paymentType = v!),
            ),
          ),
          Expanded(
            child: RadioListTile<PaymentType>(
              contentPadding: EdgeInsets.zero,
              title: const Text('Credit'),
              value: PaymentType.credit,
              groupValue: _paymentType,
              onChanged: (v) => setState(() => _paymentType = v!),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateField() {
    return TextFormField(
      controller: _dateController,
      readOnly: true,
      onTap: _pickDate,
      decoration: const InputDecoration(
        labelText: 'Date',
        prefixIcon: Icon(Icons.calendar_today_outlined),
        suffixIcon: Icon(Icons.arrow_drop_down),
        border: OutlineInputBorder(),
      ),
      validator: (v) =>
      (v == null || v.isEmpty) ? 'Please select a date' : null,
    );
  }

  Widget _buildDescriptionField() {
    return TextFormField(
      controller: _descriptionController,
      maxLines: 3,
      maxLength: 200,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(
        labelText: 'Description (optional)',
        alignLabelWithHint: true,
        prefixIcon: Padding(
          padding: EdgeInsets.only(bottom: 48),
          child: Icon(Icons.notes_outlined),
        ),
        border: OutlineInputBorder(),
      ),
    );
  }
}

// =============================================================================
// Bottom sheet: add / remove custom categories
// =============================================================================
class _ManageCategoriesSheet extends StatefulWidget {
  const _ManageCategoriesSheet({
    required this.categoriesRef,
    required this.onCategoryDeleted,
  });

  final CollectionReference<Map<String, dynamic>> categoriesRef;
  final ValueChanged<String> onCategoryDeleted;

  @override
  State<_ManageCategoriesSheet> createState() => _ManageCategoriesSheetState();
}

class _ManageCategoriesSheetState extends State<_ManageCategoriesSheet> {
  final _nameController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Offline-first: written to the local cache immediately and synced later.
  /// The write Future is intentionally not awaited (it completes only after
  /// server acknowledgement). The snapshots() stream fires right away with the
  /// local change, so the new category appears in the UI even while offline.
  void _addCategory(List<String> existingNames) {
    final name = _nameController.text.trim().replaceAll(RegExp(r'\s+'), ' ');

    if (name.isEmpty) {
      setState(() => _error = 'Enter a category name');
      return;
    }
    final isDuplicate = [...kDefaultCategories, ...existingNames]
        .any((c) => c.toLowerCase() == name.toLowerCase());
    if (isDuplicate) {
      setState(() => _error = 'This category already exists');
      return;
    }

    widget.categoriesRef.doc().set({
      'name': name,
      'createdAt': FieldValue.serverTimestamp(),
    }).catchError((Object e) {
      // Only reached if the server later rejects the write.
      debugPrint('Category sync failed: $e');
    });

    _nameController.clear();
    setState(() => _error = null);
  }

  Future<void> _deleteCategory(
      QueryDocumentSnapshot<Map<String, dynamic>> doc,
      ) async {
    final name = doc.data()['name'] as String? ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove category?'),
        content: Text(
          '"$name" will be removed from your category list. '
              'Existing expenses in this category will not be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Not awaited: completes only after server acknowledgement, which would
    // never happen while offline. The local cache is updated immediately.
    doc.reference.delete().catchError((Object e) {
      debugPrint('Category delete sync failed: $e');
    });
    widget.onCategoryDeleted(name);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: widget.categoriesRef.snapshots(),
        builder: (context, snapshot) {
          final docs = [...(snapshot.data?.docs ?? const [])]..sort(
                (a, b) => ((a.data()['name'] as String?) ?? '')
                .toLowerCase()
                .compareTo(
              ((b.data()['name'] as String?) ?? '').toLowerCase(),
            ),
          );
          final customNames = docs
              .map((d) => (d.data()['name'] as String?) ?? '')
              .toList();

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Manage Categories',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),

              // Add new category
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 30,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addCategory(customNames),
                      decoration: InputDecoration(
                        labelText: 'New category name',
                        errorText: _error,
                        counterText: '',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: FilledButton(
                      onPressed: () => _addCategory(customNames),
                      child: const Text('Add'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // List of categories
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // Default categories: locked, no delete button.
                    for (final name in kDefaultCategories)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(name),
                        subtitle: const Text('Default'),
                        trailing: const Icon(Icons.lock_outline, size: 18),
                      ),
                    if (docs.isNotEmpty) const Divider(),
                    // Custom categories: deletable.
                    for (final doc in docs)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text((doc.data()['name'] as String?) ?? ''),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteCategory(doc),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}