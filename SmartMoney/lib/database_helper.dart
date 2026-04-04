// ignore_for_file: avoid_print
// Database helper with per-user Firebase Firestore integration and SharedPreferences for robust offline storage
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  String? _currentUserId;

  // In-memory cache for current user's data
  static final List<Map<String, dynamic>> _transactions = [];
  static final List<Map<String, dynamic>> _categories = [];
  static final List<Map<String, dynamic>> _budgets = [];
  static final List<Map<String, dynamic>> _savingsGoals = [];
  static final List<Map<String, dynamic>> _recurringTransactions = [];
  static int _transactionIdCounter = 1;
  static int _categoryIdCounter = 19;
  static int _budgetIdCounter = 1;
  static int _savingsGoalIdCounter = 1;
  static int _recurringTransactionIdCounter = 1;

  bool _needsSync = false;

  // Stream to notify listeners when data changes (e.g., after a Firebase pull)
  final StreamController<void> _onDataChanged = StreamController<void>.broadcast();
  Stream<void> get onDataChanged => _onDataChanged.stream;

  DatabaseHelper._init() {

    _initializeDefaultCategories();
  }

  // Start - Data Persistance with SharedPreferences & Firebase Sync
  String _getLocalKey() => 'sm_data_${_currentUserId ?? 'offline'}';

  // Set current user ID (called when user logs in or offline mode)
  Future<void> setCurrentUser(String userId) async {
    // Save previous user's data
    if (_currentUserId != null && _currentUserId != userId) {
      await _saveUserDataToLocal(markAsNeedsSync: false);
    }

    _currentUserId = userId;

    // 1. Load local data first for immediate offline availability
    await _loadUserDataFromLocal();

    // 2. Attempt to pull from and push to Firebase in the background
    _syncWithFirebase();
  }

  Future<void> _loadUserDataFromLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonStr = prefs.getString(_getLocalKey());

      if (jsonStr != null) {
        final data = jsonDecode(jsonStr);
        _transactions.clear();
        _transactions.addAll(
          (data['transactions'] as List).cast<Map<String, dynamic>>(),
        );

        _categories.clear();
        _addDefaultCategories(); // Always add defaults first
        for (var cat
            in (data['categories'] as List).cast<Map<String, dynamic>>()) {
          if (!_categories.any((c) => c['id'] == cat['id'])) {
            _categories.add(cat);
          }
        }

        _budgets.clear();
        _budgets.addAll((data['budgets'] as List).cast<Map<String, dynamic>>());

        _savingsGoals.clear();
        if (data['savingsGoals'] != null) {
          _savingsGoals.addAll((data['savingsGoals'] as List).cast<Map<String, dynamic>>());
        }

        _transactionIdCounter = data['transactionIdCounter'] ?? 1;
        _categoryIdCounter = data['categoryIdCounter'] ?? 19;
        _budgetIdCounter = data['budgetIdCounter'] ?? 1;
        _savingsGoalIdCounter = data['savingsGoalIdCounter'] ?? 1;
        _recurringTransactionIdCounter = data['recurringTransactionIdCounter'] ?? 1;
        _recurringTransactions.clear();
        if (data['recurringTransactions'] != null) {
          _recurringTransactions.addAll(
            (data['recurringTransactions'] as List).cast<Map<String, dynamic>>(),
          );
        }
        _needsSync = data['needsSync'] ?? false;

        print('Loaded local data for $_currentUserId. Needs sync: $_needsSync');
      } else {
        _resetToDefaults();
      }
      _onDataChanged.add(null);
    } catch (e) {

      print('Error loading local data: $e');
      _resetToDefaults();
    }
  }

  Future<void> _saveUserDataToLocal({bool markAsNeedsSync = true}) async {
    // Determine if it's a firebase user or an offline user
    // Simple heuristic: Firebase UIDs usually don't contain '@', while our local offline mock accounts use email as ID.
    final isFirebaseUser =
        _currentUserId != null && !_currentUserId!.contains('@');

    if (markAsNeedsSync && isFirebaseUser) {
      _needsSync = true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'transactions': _transactions,
        'categories': _categories,
        'budgets': _budgets,
        'savingsGoals': _savingsGoals,
        'transactionIdCounter': _transactionIdCounter,
        'categoryIdCounter': _categoryIdCounter,
        'budgetIdCounter': _budgetIdCounter,
        'savingsGoalIdCounter': _savingsGoalIdCounter,
        'recurringTransactionIdCounter': _recurringTransactionIdCounter,
        'recurringTransactions': _recurringTransactions,
        'needsSync': _needsSync,
        'lastUpdated': DateTime.now().toIso8601String(),
      };

      await prefs.setString(_getLocalKey(), jsonEncode(data));

      // Attempt to push to Firebase in background if marked
      if (markAsNeedsSync && isFirebaseUser) {
        _pushToFirebase();
      }
    } catch (e) {
      print('Error saving local data: $e');
    }
  }

  // Pull remote data, merge if no unsynced changes, then push if needed
  Future<void> _syncWithFirebase() async {
    final isFirebaseUser =
        _currentUserId != null && !_currentUserId!.contains('@');
    if (!isFirebaseUser) return; // Skip for local/offline users

    print('Starting Firebase sync...');
    try {
      final userDoc = await _db
          .collection('users')
          .doc(_currentUserId)
          .get()
          .timeout(const Duration(seconds: 4), onTimeout: () {
        debugPrint('Firebase Sync: Pull timed out after 4 seconds');
        throw TimeoutException('Firebase pull timed out');
      });

      if (userDoc.exists) {
        if (!_needsSync) {
          // Local has NO unsynced changes, safe to overwrite local with remote
          final data = userDoc.data() ?? {};

          _transactions.clear();
          _transactions.addAll(
            (data['transactions'] as List? ?? []).cast<Map<String, dynamic>>(),
          );

          _categories.clear();
          _addDefaultCategories();
          for (var cat
              in (data['categories'] as List? ?? [])
                  .cast<Map<String, dynamic>>()) {
            if (!_categories.any((c) => c['id'] == cat['id'])) {
              _categories.add(cat);
            }
          }

          _budgets.clear();
          _budgets.addAll(
            (data['budgets'] as List? ?? []).cast<Map<String, dynamic>>(),
          );

          _savingsGoals.clear();
          _savingsGoals.addAll(
            (data['savingsGoals'] as List? ?? []).cast<Map<String, dynamic>>(),
          );

          _transactionIdCounter = data['transactionIdCounter'] ?? 1;
          _categoryIdCounter = data['categoryIdCounter'] ?? 18;
          _budgetIdCounter = data['budgetIdCounter'] ?? 1;
          _savingsGoalIdCounter = data['savingsGoalIdCounter'] ?? 1;
          _recurringTransactionIdCounter = data['recurringTransactionIdCounter'] ?? 1;
          
          _recurringTransactions.clear();
          _recurringTransactions.addAll(
            (data['recurringTransactions'] as List? ?? [])
                .cast<Map<String, dynamic>>(),
          );

          // Save to local (but don't mark as needs sync since it came from remote)
          await _saveUserDataToLocal(markAsNeedsSync: false);
          print('Synced (Pulled) data from Firebase.');
          _onDataChanged.add(null);
        } else {

          // Local HAS unsynced changes. Push local to remote (overwrite remote)
          print('Local has pending changes, pushing to Firebase...');
          await _pushToFirebase();
        }
      } else {
        // New user on Firebase. Push local to create the doc
        print('New Firebase user doc, pushing local data...');
        await _pushToFirebase();
      }
    } catch (e) {
      print('Firebase Sync Pull Error: $e');
      // If we can't pull, we might be offline. It's fine, we work with local data.
    }
  }

  Future<void> _pushToFirebase() async {
    final isFirebaseUser =
        _currentUserId != null && !_currentUserId!.contains('@');
    if (!isFirebaseUser || !_needsSync) return;

    try {
      // Create a deep copy of current data to avoid race conditions 
      // where lists are cleared while we are pushing them.
      final txBatch = List<Map<String, dynamic>>.from(_transactions);
      final catBatch = List<Map<String, dynamic>>.from(_categories);
      final budgetBatch = List<Map<String, dynamic>>.from(_budgets);
      final goalBatch = List<Map<String, dynamic>>.from(_savingsGoals);
      final recurringBatch = List<Map<String, dynamic>>.from(_recurringTransactions);

      await _db.collection('users').doc(_currentUserId).set({
        'transactions': txBatch,
        'categories': catBatch,
        'budgets': budgetBatch,
        'savingsGoals': goalBatch,
        'transactionIdCounter': _transactionIdCounter,
        'categoryIdCounter': _categoryIdCounter,
        'budgetIdCounter': _budgetIdCounter,
        'savingsGoalIdCounter': _savingsGoalIdCounter,
        'recurringTransactionIdCounter': _recurringTransactionIdCounter,
        'recurringTransactions': recurringBatch,
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 3), onTimeout: () {
        print('Firebase Sync: Push timed out after 3 seconds');
        // We don't throw here to allow _saveUserDataToLocal to continue
      });



      _needsSync = false;
      await _saveUserDataToLocal(
        markAsNeedsSync: false,
      ); // Save the NeedsSync=false flag
      debugPrint('Successfully pushed local changes to Firebase.');
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      debugPrint('Firebase Push Error: $e');
      
      // If the database doesn't exist, don't keep trying to sync it
      // This helps the logout proceed even if the Firebase project is misconfigured
      if (errorStr.contains('not_found') || errorStr.contains('database') || errorStr.contains('does not exist')) {
        debugPrint('FATAL Firestore Status: Database not found. Disabling sync until reconsidered.');
        _needsSync = false; // Stop trying to sync to a ghost database
      }
      // Data remains securely saved locally in SharedPreferences.
    }
  }

  void _resetToDefaults() {
    _transactions.clear();
    _categories.clear();
    _budgets.clear();
    _savingsGoals.clear();
    _transactionIdCounter = 1;
    _categoryIdCounter = 18;
    _budgetIdCounter = 1;
    _savingsGoalIdCounter = 1;
    _recurringTransactionIdCounter = 1;
    _needsSync = false;
    _addDefaultCategories();
  }

  // Clear user data (called on logout)
  Future<void> clearUserData() async {
    // IMPORTANT: Capture data before clearing, and explicitely await the push
    final isFirebaseUser = _currentUserId != null && !_currentUserId!.contains('@');
    if (isFirebaseUser && _needsSync) {
      print('Logging out: Awaiting final sync to Firebase...');
      await _pushToFirebase();
    }
    
    // Final local save
    await _saveUserDataToLocal(markAsNeedsSync: false); 
    
    _resetToDefaults();
    _currentUserId = null;
    _onDataChanged.add(null);
  }


  /// Migrate locally saved offline data (keyed by email or generic 'offline') to the new Firebase UID key.
  /// Called when an offline user successfully logs in or signs up with Firebase.
  Future<void> migrateOfflineData(String offlineEmail, String firebaseUid) async {
    // Skip if the offline key and new key are already the same
    if (offlineEmail == firebaseUid) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final firebaseKey = 'sm_data_$firebaseUid';

      // Check if Firebase user already has data locally
      final existingFirebaseData = prefs.getString(firebaseKey);
      if (existingFirebaseData != null) {
        // Firebase key already has data — do NOT overwrite.
        // The existing Firebase data (synced from Firestore) takes priority.
        debugPrint('migrateOfflineData: Firebase key already exists, skipping offline migration.');
        return;
      }

      // 1. Try migrating from email-specific key
      final offlineEmailKey = 'sm_data_$offlineEmail';
      final emailJsonStr = prefs.getString(offlineEmailKey);
      
      // 2. Try migrating from generic 'offline' key (where demo data and initial state usually go)
      const genericOfflineKey = 'sm_data_offline';
      final genericJsonStr = prefs.getString(genericOfflineKey);

      String? sourceJsonStr = emailJsonStr ?? genericJsonStr;
      String? sourceKey = emailJsonStr != null ? offlineEmailKey : (genericJsonStr != null ? genericOfflineKey : null);

      if (sourceJsonStr == null || sourceKey == null) {
        debugPrint('migrateOfflineData: No offline data found to migrate.');
        return;
      }

      // Copy offline data under the Firebase UID key and mark as needs sync
      final offlineData = jsonDecode(sourceJsonStr) as Map<String, dynamic>;
      offlineData['needsSync'] = true;
      offlineData['lastUpdated'] = DateTime.now().toIso8601String();

      await prefs.setString(firebaseKey, jsonEncode(offlineData));

      // Remove the migrated source key to keep things clean
      await prefs.remove(sourceKey);
      if (sourceKey != genericOfflineKey) {
        // Also clear any generic data if we migrated from an email key
        await prefs.remove(genericOfflineKey);
      }

      debugPrint('migrateOfflineData: Migrated offline data from $sourceKey to $firebaseUid');
    } catch (e) {
      debugPrint('migrateOfflineData error: $e');
    }
  }

  void _initializeDefaultCategories() {
    if (_categories.isNotEmpty) return;
    _addDefaultCategories();
  }

  void _addDefaultCategories() {
    // Unconditionally add default categories
    // But only if not already present (by checking IDs 1-18)
    if (_categories.any((c) => c['id'] as int >= 1 && c['id'] as int <= 18)) {
      return; // Defaults already added
    }

    // Default expense categories
    _categories.addAll([
      {'id': 1, 'name': 'General', 'type': 'expense', 'is_custom': 0},
      {'id': 2, 'name': 'Food', 'type': 'expense', 'is_custom': 0},
      {'id': 3, 'name': 'Transport', 'type': 'expense', 'is_custom': 0},
      {'id': 4, 'name': 'Entertainment', 'type': 'expense', 'is_custom': 0},
      {'id': 5, 'name': 'Shopping', 'type': 'expense', 'is_custom': 0},
      {'id': 6, 'name': 'Bills', 'type': 'expense', 'is_custom': 0},
      {'id': 7, 'name': 'Healthcare', 'type': 'expense', 'is_custom': 0},
      {'id': 8, 'name': 'Education', 'type': 'expense', 'is_custom': 0},
      {'id': 9, 'name': 'EMI', 'type': 'expense', 'is_custom': 0},
      {'id': 10, 'name': 'Savings', 'type': 'expense', 'is_custom': 0},
      {'id': 18, 'name': 'Other', 'type': 'expense', 'is_custom': 0},
      // Default income categories
      {'id': 11, 'name': 'Salary', 'type': 'income', 'is_custom': 0},
      {'id': 12, 'name': 'Bonus', 'type': 'income', 'is_custom': 0},
      {
        'id': 13,
        'name': 'Investment Returns',
        'type': 'income',
        'is_custom': 0,
      },
      {'id': 14, 'name': 'Freelance', 'type': 'income', 'is_custom': 0},
      {'id': 15, 'name': 'Rental Income', 'type': 'income', 'is_custom': 0},
      {'id': 16, 'name': 'Gift', 'type': 'income', 'is_custom': 0},
      {'id': 17, 'name': 'Other', 'type': 'income', 'is_custom': 0},
    ]);
  }

  // Category Management Methods
  Future<List<String>> getCategories(String type) async {
    final result = _categories
        .where((cat) => cat['type'] == type)
        .map((cat) => cat['name'].toString())
        .toList();
    return result;
  }

  Future<bool> addCategory(String name, String type) async {
    // Check if category already exists
    if (_categories.any((c) => c['name'] == name)) {
      throw Exception('Category already exists');
    }
    _categories.add({
      'id': _categoryIdCounter++,
      'name': name,
      'type': type,
      'is_custom': 1,
    });
    await _saveUserDataToLocal();
    return true;
  }

  Future<bool> deleteCategory(String name) async {
    final initialLength = _categories.length;
    _categories.removeWhere((c) => c['name'] == name && c['is_custom'] == 1);
    if (_categories.length < initialLength) {
      await _saveUserDataToLocal();
      return true;
    }
    return false;
  }

  Future<int> insertTransaction(Map<String, dynamic> row) async {
    // Fail-safe: Enforce negative amount for expenses and positive for income
    final Map<String, dynamic> processedRow = Map.from(row);
    if (processedRow.containsKey('is_expense')) {
      final isExp = (processedRow['is_expense'] == 1 || processedRow['is_expense'] == true);
      double rawAmount = double.tryParse(processedRow['amount'].toString()) ?? 0;
      
      if (isExp && rawAmount > 0) {
        processedRow['amount'] = -rawAmount;
      } else if (!isExp && rawAmount < 0) {
        processedRow['amount'] = rawAmount.abs();
      }
    }

    final transaction = {
      ...processedRow,
      'id': _transactionIdCounter++,
      'created_at': processedRow['created_at'] ?? DateTime.now().toIso8601String(),
    };
    _transactions.add(transaction);
    await _saveUserDataToLocal();
    return transaction['id'];
  }

  Future<List<Map<String, dynamic>>> getTransactions() async {
    return List.from(_transactions.reversed);
  }

  Future<int> updateTransaction(Map<String, dynamic> row) async {
    final index = _transactions.indexWhere((t) => t['id'] == row['id']);
    if (index != -1) {
      final Map<String, dynamic> processedRow = Map.from(row);
      
      // Fail-safe: Enforce sign consistency on update
      if (processedRow.containsKey('is_expense') || processedRow.containsKey('amount')) {
        final currentTx = _transactions[index];
        final isExp = processedRow.containsKey('is_expense')
            ? (processedRow['is_expense'] == 1 || processedRow['is_expense'] == true)
            : (currentTx['is_expense'] == 1 || currentTx['is_expense'] == true);
        
        final amtToProcess = processedRow['amount'] ?? currentTx['amount'];
        double rawAmount = double.tryParse(amtToProcess.toString()) ?? 0;
        
        if (isExp && rawAmount > 0) {
          processedRow['amount'] = -rawAmount;
        } else if (!isExp && rawAmount < 0) {
          processedRow['amount'] = rawAmount.abs();
        }
      }

      _transactions[index] = {..._transactions[index], ...processedRow};
      await _saveUserDataToLocal();
      return 1;
    }
    return 0;
  }

  Future<int> deleteTransaction(int id) async {
    final initialLength = _transactions.length;
    _transactions.removeWhere((t) => t['id'] == id);
    if (_transactions.length < initialLength) {
      await _saveUserDataToLocal();
      return 1;
    }
    return 0;
  }

  Future<void> setBudgetLimit(
    String category,
    double limitAmount,
    int month,
    int year,
  ) async {
    final index = _budgets.indexWhere(
      (b) =>
          b['category'] == category && b['month'] == month && b['year'] == year,
    );
    if (index != -1) {
      _budgets[index]['limit_amount'] = limitAmount;
    } else {
      _budgets.add({
        'id': _budgetIdCounter++,
        'category': category,
        'limit_amount': limitAmount,
        'month': month,
        'year': year,
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    await _saveUserDataToLocal();
  }

  Future<double?> getBudgetLimit(String category, int month, int year) async {
    final budget = _budgets.firstWhere(
      (b) =>
          b['category'] == category && b['month'] == month && b['year'] == year,
      orElse: () => {},
    );
    return budget.isEmpty ? null : budget['limit_amount'] as double?;
  }

  Future<List<Map<String, dynamic>>> getAllBudgets(int month, int year) async {
    return _budgets
        .where((b) => b['month'] == month && b['year'] == year)
        .toList();
  }

  Future<void> deleteBudgetLimit(String category, int month, int year) async {
    _budgets.removeWhere(
      (b) =>
          b['category'] == category && b['month'] == month && b['year'] == year,
    );
    await _saveUserDataToLocal();
  }

  Future<void> setOverallBudget(double limitAmount) async {
    final now = DateTime.now();
    final index = _budgets.indexWhere(
      (b) =>
          b['category'] == 'OVERALL' &&
          b['month'] == now.month &&
          b['year'] == now.year,
    );
    if (index != -1) {
      _budgets[index]['limit_amount'] = limitAmount;
    } else {
      _budgets.add({
        'id': _budgetIdCounter++,
        'category': 'OVERALL',
        'limit_amount': limitAmount,
        'month': now.month,
        'year': now.year,
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    await _saveUserDataToLocal();
  }

  Future<double?> getOverallBudget() async {
    final now = DateTime.now();
    final budget = _budgets.firstWhere(
      (b) =>
          b['category'] == 'OVERALL' &&
          b['month'] == now.month &&
          b['year'] == now.year,
      orElse: () => {},
    );
    return budget.isEmpty ? null : budget['limit_amount'] as double?;
  }

  Future<void> clearDatabase() async {
    _transactions.clear();
    _categories.clear();
    _budgets.clear();
    _savingsGoals.clear();
    _transactionIdCounter = 1;
    _categoryIdCounter = 18;
    _budgetIdCounter = 1;
    _savingsGoalIdCounter = 1;
    _addDefaultCategories();
    await _saveUserDataToLocal();
  }

  // --- Savings Goal Methods ---
  Future<List<Map<String, dynamic>>> getSavingsGoals() async {
    return List.from(_savingsGoals);
  }

  Future<int> addSavingsGoal(String title, double targetAmount, int colorIndex) async {
    final goal = {
      'id': _savingsGoalIdCounter++,
      'title': title,
      'target_amount': targetAmount,
      'current_amount': 0.0,
      'color_index': colorIndex,
      'created_at': DateTime.now().toIso8601String(),
    };
    _savingsGoals.add(goal);
    await _saveUserDataToLocal();
    return goal['id'] as int;
  }

  Future<void> addFundsToGoal(int goalId, double amount) async {
    final index = _savingsGoals.indexWhere((g) => g['id'] == goalId);
    if (index != -1) {
      final current = _savingsGoals[index]['current_amount'] as double;
      _savingsGoals[index]['current_amount'] = current + amount;
      await _saveUserDataToLocal();
    }
  }

  Future<void> subtractFundsFromGoal(int goalId, double amount) async {
    final index = _savingsGoals.indexWhere((g) => g['id'] == goalId);
    if (index != -1) {
      final current = _savingsGoals[index]['current_amount'] as double;
      // Prevent balance from dropping below 0
      final newAmount = current - amount;
      _savingsGoals[index]['current_amount'] = newAmount < 0 ? 0.0 : newAmount;
      await _saveUserDataToLocal();
    }
  }

  Future<void> deleteSavingsGoal(int goalId) async {
    _savingsGoals.removeWhere((g) => g['id'] == goalId);
    await _saveUserDataToLocal();
  }

  // --- Recurring Transaction Methods ---

  Future<List<Map<String, dynamic>>> getRecurringTransactions() async {
    return List.from(_recurringTransactions);
  }

  Future<int> addRecurringTransaction({
    required String title,
    required double amount,
    required String category,
    required String interval, // 'daily', 'weekly', 'monthly', 'yearly'
    required DateTime startDate,
    int? durationMonths, // Optional duration in months
    bool isExpense = true,
  }) async {
    DateTime? endDate;
    if (durationMonths != null && durationMonths > 0) {
      endDate = DateTime(startDate.year, startDate.month + durationMonths, startDate.day);
    }

    final recurring = {
      'id': _recurringTransactionIdCounter++,
      'title': title,
      'amount': amount,
      'category': category,
      'interval': interval,
      'start_date': startDate.toIso8601String(),
      'end_date': endDate?.toIso8601String(),
      'last_processed_date': null, // When the last real transaction was created
       'next_due_date': startDate.toIso8601String(),
      'is_expense': isExpense ? 1 : 0,
      'created_at': DateTime.now().toIso8601String(),
    };
    _recurringTransactions.add(recurring);
    await _saveUserDataToLocal();
    return recurring['id'] as int;
  }

  Future<void> deleteRecurringTransaction(int id) async {
    _recurringTransactions.removeWhere((rt) => rt['id'] == id);
    await _saveUserDataToLocal();
  }

  Future<void> updateRecurringTransaction(Map<String, dynamic> row) async {
    final index = _recurringTransactions.indexWhere((rt) => rt['id'] == row['id']);
    if (index != -1) {
      _recurringTransactions[index] = {..._recurringTransactions[index], ...row};
      await _saveUserDataToLocal();
    }
  }

  Future<int> processRecurringTransactions() async {
    int createdCount = 0;
    final now = DateTime.now();
    final List<Map<String, dynamic>> recurringToUpdate = [];

    for (final rt in _recurringTransactions) {
      DateTime nextDue = DateTime.parse(rt['next_due_date']);
      DateTime? endDate = rt['end_date'] != null ? DateTime.parse(rt['end_date']) : null;
      
      while (nextDue.isBefore(now)) {
        // Check if we passed the end date
        if (endDate != null && nextDue.isAfter(endDate)) {
          break;
        }

        // Create a real transaction
        await insertTransaction({
          'title': rt['title'],
          'amount': rt['amount'],
          'category': rt['category'],
           'date': nextDue.toIso8601String(),
          'is_expense': rt['is_expense'] ?? (rt['amount'] < 0 ? 1 : 0),
          'notes': 'Auto-generated from recurring: ${rt['title']}',
        });
        createdCount++;

        // Calculate next due date
        final interval = rt['interval'] as String;
        if (interval == 'daily') {
          nextDue = nextDue.add(const Duration(days: 1));
        } else if (interval == 'weekly') {
          nextDue = nextDue.add(const Duration(days: 7));
        } else if (interval == 'monthly') {
          nextDue = DateTime(nextDue.year, nextDue.month + 1, nextDue.day);
        } else if (interval == 'yearly') {
          nextDue = DateTime(nextDue.year + 1, nextDue.month, nextDue.day);
        }
        
        // Update the template in the list
        rt['next_due_date'] = nextDue.toIso8601String();
        rt['last_processed_date'] = DateTime.now().toIso8601String();
        recurringToUpdate.add(rt);
      }
    }

    if (recurringToUpdate.isNotEmpty) {
      await _saveUserDataToLocal();
    }
    return createdCount;
  }

  Future<void> closeDatabase() async {
    // No-op for SharedPreferences/Firestore
  }

  // --- User Profile Methods ---

  static Map<String, dynamic>? _cachedProfile;

  Future<void> saveUserProfile(Map<String, dynamic> profile) async {
    _cachedProfile = {...profile};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'sm_profile_${_currentUserId ?? 'offline'}',
        jsonEncode(profile),
      );
      // Sync to Firestore if Firebase user
      final isFirebaseUser =
          _currentUserId != null && !_currentUserId!.contains('@');
      if (isFirebaseUser) {
        _db
            .collection('users')
            .doc(_currentUserId)
            .set({'profile': profile}, SetOptions(merge: true))
            .catchError((e) => print('Profile Firestore sync error: $e'));
      }
    } catch (e) {
      print('Error saving user profile: $e');
    }
  }

  Future<Map<String, dynamic>?> getUserProfile() async {
    if (_cachedProfile != null) return _cachedProfile;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr =
          prefs.getString('sm_profile_${_currentUserId ?? 'offline'}');
      if (jsonStr != null) {
        _cachedProfile = jsonDecode(jsonStr) as Map<String, dynamic>;
        return _cachedProfile;
      }
    } catch (e) {
      print('Error loading user profile: $e');
    }
    return null;
  }

  void clearProfileCache() {
    _cachedProfile = null;
  }
}
