// lib/services/export_service.dart
//
// Builds an .xlsx workbook from a user's expenses and shares / downloads it.
//
// Dependencies (pubspec.yaml): excel, share_plus, cross_file, intl, cloud_firestore
//
// The workbook has four sheets:
//   Summary      - period, totals, cash / credit split
//   Expenses     - every expense, oldest first
//   By Category  - totals per category
//   By Month     - totals per month in the chosen period

import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart'
    show GetOptions, QuerySnapshot, Source, Timestamp;
import 'package:cross_file/cross_file.dart';
import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:newproject/models/expense_helpers.dart'
    show currentUid, expensesBetween;
import 'package:share_plus/share_plus.dart';

class ExportService {
  static const String _xlsxMime =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  /// Fetches all expenses from [startMonth] to [endMonth], both inclusive
  /// (any day in the month works; only year and month are used).
  ///
  /// If the server cannot be reached within a few seconds (for example the
  /// phone is offline), the on-device copy of the data is used instead.
  static Future<List<Map<String, dynamic>>> fetchExpenses(
      DateTime startMonth,
      DateTime endMonth,
      ) async {
    final uid = currentUid;
    if (uid == null) throw StateError('Not logged in');

    final start = DateTime(startMonth.year, startMonth.month);
    final end = DateTime(endMonth.year, endMonth.month + 1);
    final query = expensesBetween(uid, start, end);

    QuerySnapshot<Map<String, dynamic>> snap;
    try {
      snap = await query.get().timeout(const Duration(seconds: 8));
    } on TimeoutException {
      snap = await query.get(const GetOptions(source: Source.cache));
    }
    return snap.docs.map((d) => d.data()).toList();
  }

  /// Human-readable period, e.g. "March 2026", "Year 2026" or "Jan 2026 - Mar 2026".
  static String periodLabel(DateTime startMonth, DateTime endMonth) {
    final sameMonth = startMonth.year == endMonth.year &&
        startMonth.month == endMonth.month;
    if (sameMonth) return DateFormat('MMMM yyyy').format(startMonth);

    final wholeYear = startMonth.year == endMonth.year &&
        startMonth.month == 1 &&
        endMonth.month == 12;
    if (wholeYear) return 'Year ${startMonth.year}';

    final f = DateFormat('MMM yyyy');
    return '${f.format(startMonth)} - ${f.format(endMonth)}';
  }

  static String fileNameFor(DateTime startMonth, DateTime endMonth) {
    final sameMonth = startMonth.year == endMonth.year &&
        startMonth.month == endMonth.month;
    final f = DateFormat('yyyy-MM');
    if (sameMonth) return 'expenses_${f.format(startMonth)}.xlsx';

    final wholeYear = startMonth.year == endMonth.year &&
        startMonth.month == 1 &&
        endMonth.month == 12;
    if (wholeYear) return 'expenses_${startMonth.year}.xlsx';

    return 'expenses_${f.format(startMonth)}_to_${f.format(endMonth)}.xlsx';
  }

  /// Builds the workbook and returns the bytes of the .xlsx file.
  static List<int> buildWorkbook(
      List<Map<String, dynamic>> expenses,
      DateTime startMonth,
      DateTime endMonth,
      ) {
    final rows = expenses.map(_ExpenseRow.fromMap).toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    double total = 0, cash = 0, credit = 0;
    final catTotal = <String, double>{};
    final catCash = <String, double>{};
    final catCredit = <String, double>{};
    final catCount = <String, int>{};
    for (final r in rows) {
      total += r.amount;
      if (r.isCredit) {
        credit += r.amount;
        catCredit[r.category] = (catCredit[r.category] ?? 0) + r.amount;
      } else {
        cash += r.amount;
        catCash[r.category] = (catCash[r.category] ?? 0) + r.amount;
      }
      catTotal[r.category] = (catTotal[r.category] ?? 0) + r.amount;
      catCount[r.category] = (catCount[r.category] ?? 0) + 1;
    }

    final excel = Excel.createExcel();

    // --- Summary ---------------------------------------------------------
    excel.rename('Sheet1', 'Summary');
    final summary = excel['Summary'];
    _boldRow(summary, ['Expense Report']);
    summary.appendRow([
      TextCellValue('Period'),
      TextCellValue(periodLabel(startMonth, endMonth)),
    ]);
    summary.appendRow([
      TextCellValue('Generated'),
      TextCellValue(DateFormat('dd MMM yyyy, HH:mm').format(DateTime.now())),
    ]);
    summary.appendRow([TextCellValue('')]);
    summary.appendRow([TextCellValue('Total spent'), DoubleCellValue(total)]);
    summary.appendRow([TextCellValue('Cash'), DoubleCellValue(cash)]);
    summary.appendRow([TextCellValue('Credit'), DoubleCellValue(credit)]);
    summary.appendRow([
      TextCellValue('Number of expenses'),
      IntCellValue(rows.length),
    ]);
    summary.setColumnWidth(0, 22);
    summary.setColumnWidth(1, 24);

    // --- Expenses --------------------------------------------------------
    final sheet = excel['Expenses'];
    _boldRow(sheet, ['Date', 'Category', 'Amount', 'Payment', 'Description']);
    final dateFmt = DateFormat('yyyy-MM-dd');
    for (final r in rows) {
      sheet.appendRow([
        TextCellValue(dateFmt.format(r.date)),
        TextCellValue(r.category),
        DoubleCellValue(r.amount),
        TextCellValue(r.isCredit ? 'Credit' : 'Cash'),
        TextCellValue(r.description),
      ]);
    }
    sheet.setColumnWidth(0, 14);
    sheet.setColumnWidth(1, 22);
    sheet.setColumnWidth(2, 14);
    sheet.setColumnWidth(3, 10);
    sheet.setColumnWidth(4, 40);

    // --- By Category -----------------------------------------------------
    final byCat = excel['By Category'];
    _boldRow(byCat, ['Category', 'Entries', 'Total', 'Cash', 'Credit', '% of total']);
    final cats = catTotal.keys.toList()
      ..sort((a, b) => catTotal[b]!.compareTo(catTotal[a]!));
    for (final c in cats) {
      final share = total > 0 ? catTotal[c]! / total * 100 : 0.0;
      byCat.appendRow([
        TextCellValue(c),
        IntCellValue(catCount[c] ?? 0),
        DoubleCellValue(catTotal[c] ?? 0),
        DoubleCellValue(catCash[c] ?? 0),
        DoubleCellValue(catCredit[c] ?? 0),
        DoubleCellValue(double.parse(share.toStringAsFixed(1))),
      ]);
    }
    _boldCells(byCat, [
      TextCellValue('Total'),
      IntCellValue(rows.length),
      DoubleCellValue(total),
      DoubleCellValue(cash),
      DoubleCellValue(credit),
      DoubleCellValue(total > 0 ? 100.0 : 0.0),
    ]);
    byCat.setColumnWidth(0, 24);
    for (var i = 1; i <= 5; i++) {
      byCat.setColumnWidth(i, 14);
    }

    // --- By Month --------------------------------------------------------
    final byMonth = excel['By Month'];
    _boldRow(byMonth, ['Month', 'Entries', 'Total', 'Cash', 'Credit']);
    final monthTotal = <int, double>{};
    final monthCash = <int, double>{};
    final monthCredit = <int, double>{};
    final monthCount = <int, int>{};
    for (final r in rows) {
      final key = r.date.year * 12 + r.date.month;
      monthTotal[key] = (monthTotal[key] ?? 0) + r.amount;
      monthCount[key] = (monthCount[key] ?? 0) + 1;
      if (r.isCredit) {
        monthCredit[key] = (monthCredit[key] ?? 0) + r.amount;
      } else {
        monthCash[key] = (monthCash[key] ?? 0) + r.amount;
      }
    }
    final monthFmt = DateFormat('MMM yyyy');
    var cursor = DateTime(startMonth.year, startMonth.month);
    final last = DateTime(endMonth.year, endMonth.month);
    while (!cursor.isAfter(last)) {
      final key = cursor.year * 12 + cursor.month;
      byMonth.appendRow([
        TextCellValue(monthFmt.format(cursor)),
        IntCellValue(monthCount[key] ?? 0),
        DoubleCellValue(monthTotal[key] ?? 0),
        DoubleCellValue(monthCash[key] ?? 0),
        DoubleCellValue(monthCredit[key] ?? 0),
      ]);
      cursor = DateTime(cursor.year, cursor.month + 1);
    }
    byMonth.setColumnWidth(0, 16);
    for (var i = 1; i <= 4; i++) {
      byMonth.setColumnWidth(i, 14);
    }

    // encode() returns the file bytes without triggering a browser download
    // (excel.save() would also download the file when running on the web).
    final bytes = excel.encode();
    if (bytes == null) throw StateError('Could not create the spreadsheet');
    return bytes;
  }

  /// Opens the share sheet on a phone (save to Drive, send by WhatsApp or
  /// email, ...). On the web it downloads the file instead.
  static Future<void> shareWorkbook(List<int> bytes, String fileName) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            Uint8List.fromList(bytes),
            mimeType: _xlsxMime,
            name: fileName,
          ),
        ],
        fileNameOverrides: [fileName],
        subject: fileName,
      ),
    );
  }

  static void _boldRow(Sheet sheet, List<String> values) =>
      _boldCells(sheet, values.map((v) => TextCellValue(v)).toList());

  static void _boldCells(Sheet sheet, List<CellValue> values) {
    sheet.appendRow(values);
    final rowIndex = sheet.maxRows - 1;
    for (var i = 0; i < values.length; i++) {
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: rowIndex))
          .cellStyle = CellStyle(bold: true);
    }
  }
}

class _ExpenseRow {
  _ExpenseRow({
    required this.date,
    required this.category,
    required this.amount,
    required this.isCredit,
    required this.description,
  });

  final DateTime date;
  final String category;
  final double amount;
  final bool isCredit;
  final String description;

  factory _ExpenseRow.fromMap(Map<String, dynamic> m) => _ExpenseRow(
    date: (m['date'] as Timestamp?)?.toDate() ?? DateTime(1970),
    category: (m['category'] as String?) ?? 'Uncategorized',
    amount: (m['amount'] as num?)?.toDouble() ?? 0,
    isCredit: m['paymentType'] == 'credit',
    description: (m['description'] as String?) ?? '',
  );
}