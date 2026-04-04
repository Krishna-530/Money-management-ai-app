// AI Analyst Service
// Pure Dart logic — no external API calls required.
// Three engines: Spending Analyst, Anomaly Detection, Merchant Intelligence.

class SpendingInsight {
  final String emoji;
  final String title;
  final String description;
  final InsightType type;

  const SpendingInsight({
    required this.emoji,
    required this.title,
    required this.description,
    required this.type,
  });
}

enum InsightType { pattern, warning, tip, info }

class AnomalyFlag {
  final String emoji;
  final String title;
  final String description;
  final AnomalySeverity severity;
  final Map<String, dynamic>? transaction;

  const AnomalyFlag({
    required this.emoji,
    required this.title,
    required this.description,
    required this.severity,
    this.transaction,
  });
}

enum AnomalySeverity { warning, alert }

class MerchantSuggestion {
  final Map<String, dynamic> transaction;
  final String inferredCategory;
  final String matchedKeyword;

  const MerchantSuggestion({
    required this.transaction,
    required this.inferredCategory,
    required this.matchedKeyword,
  });
}

class AIAnalystService {
  static final AIAnalystService instance = AIAnalystService._();
  AIAnalystService._();

  // ────────────────────────────────────────────────
  // MERCHANT INTELLIGENCE — keyword → category map
  // ────────────────────────────────────────────────
  static const Map<String, String> _merchantMap = {
    // Food & Dining
    'swiggy': 'Food',
    'zomato': 'Food',
    'dunzo': 'Food',
    'bigbasket': 'Food',
    'grofers': 'Food',
    'blinkit': 'Food',
    'zepto': 'Food',
    'mcdonald': 'Food',
    'mcdonalds': 'Food',
    'kfc': 'Food',
    'dominos': 'Food',
    'pizza': 'Food',
    'starbucks': 'Food',
    'cafe': 'Food',
    'restaurant': 'Food',
    'dining': 'Food',
    'bakery': 'Food',
    'grocery': 'Food',
    'supermarket': 'Food',
    'reliance fresh': 'Food',
    'dmart': 'Food',
    'more retail': 'Food',
    'spencers': 'Food',
    'haldiram': 'Food',
    'subway': 'Food',
    'burger king': 'Food',
    'burger': 'Food',

    // Transport
    'uber': 'Transport',
    'ola': 'Transport',
    'rapido': 'Transport',
    'namma yatri': 'Transport',
    'irctc': 'Transport',
    'indian railways': 'Transport',
    'railway': 'Transport',
    'indigo': 'Transport',
    'spicejet': 'Transport',
    'air india': 'Transport',
    'vistara': 'Transport',
    'flight': 'Transport',
    'airline': 'Transport',
    'metro': 'Transport',
    'bus': 'Transport',
    'petrol': 'Transport',
    'fuel': 'Transport',
    'diesel': 'Transport',
    'parking': 'Transport',
    'toll': 'Transport',
    'fasttag': 'Transport',
    'redbus': 'Transport',
    'makemytrip': 'Transport',
    'goibibo': 'Transport',
    'yatra': 'Transport',

    // Entertainment
    'netflix': 'Entertainment',
    'amazon prime': 'Entertainment',
    'prime video': 'Entertainment',
    'hotstar': 'Entertainment',
    'disney': 'Entertainment',
    'youtube premium': 'Entertainment',
    'spotify': 'Entertainment',
    'gaana': 'Entertainment',
    'jiosaavn': 'Entertainment',
    'jio saavn': 'Entertainment',
    'apple music': 'Entertainment',
    'pvr': 'Entertainment',
    'inox': 'Entertainment',
    'bookmyshow': 'Entertainment',
    'cinema': 'Entertainment',
    'theatre': 'Entertainment',
    'playstation': 'Entertainment',
    'xbox': 'Entertainment',
    'steam': 'Entertainment',
    'gaming': 'Entertainment',

    // Shopping
    'amazon': 'Shopping',
    'flipkart': 'Shopping',
    'myntra': 'Shopping',
    'ajio': 'Shopping',
    'meesho': 'Shopping',
    'nykaa': 'Shopping',
    'snapdeal': 'Shopping',
    'tata cliq': 'Shopping',
    'shoppers stop': 'Shopping',
    'westside': 'Shopping',
    'h&m': 'Shopping',
    'zara': 'Shopping',
    'decathlon': 'Shopping',
    'ikea': 'Shopping',
    'croma': 'Shopping',
    'vijay sales': 'Shopping',
    'reliance digital': 'Shopping',

    // Healthcare
    'apollo': 'Healthcare',
    'medplus': 'Healthcare',
    'pharmeasy': 'Healthcare',
    'tata 1mg': 'Healthcare',
    '1mg': 'Healthcare',
    'netmeds': 'Healthcare',
    'practo': 'Healthcare',
    'hospital': 'Healthcare',
    'clinic': 'Healthcare',
    'pharmacy': 'Healthcare',
    'medical': 'Healthcare',
    'doctor': 'Healthcare',
    'diagnostic': 'Healthcare',
    'lab': 'Healthcare',
    'thyrocare': 'Healthcare',
    'lal pathlabs': 'Healthcare',
    'health': 'Healthcare',

    // Bills & Utilities
    'electricity': 'Bills',
    'bses': 'Bills',
    'bescom': 'Bills',
    'msedcl': 'Bills',
    'water bill': 'Bills',
    'gas': 'Bills',
    'igl': 'Bills',
    'mgl': 'Bills',
    'tata power': 'Bills',
    'adani electricity': 'Bills',
    'broadband': 'Bills',
    'airtel': 'Bills',
    'jio': 'Bills',
    'vi ': 'Bills',
    'vodafone': 'Bills',
    'bsnl': 'Bills',
    'recharge': 'Bills',
    'insurance': 'Bills',
    'lic': 'Bills',
    'hdfc life': 'Bills',
    'sbi life': 'Bills',
    'bajaj allianz': 'Bills',
    'maintenance': 'Bills',

    // Education
    'udemy': 'Education',
    'coursera': 'Education',
    'byju': 'Education',
    'vedantu': 'Education',
    'unacademy': 'Education',
    'school': 'Education',
    'college': 'Education',
    'university': 'Education',
    'tuition': 'Education',
    'coaching': 'Education',
    'books': 'Education',
    'stationery': 'Education',
    'exam': 'Education',
    'fees': 'Education',
  };

  /// Infer a category from a messy transaction title.
  /// Returns null if no match found.
  String? categorizeMerchant(String rawTitle) {
    final normalized = rawTitle.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    for (final entry in _merchantMap.entries) {
      if (normalized.contains(entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  /// Returns the matched keyword for a title (for display).
  String? matchedKeyword(String rawTitle) {
    final normalized = rawTitle.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    for (final key in _merchantMap.keys) {
      if (normalized.contains(key)) return key;
    }
    return null;
  }

  /// Analyze all transactions and return merchant suggestions where the inferred
  /// category differs from the stored one.
  List<MerchantSuggestion> getMerchantSuggestions(
    List<Map<String, dynamic>> transactions,
  ) {
    final suggestions = <MerchantSuggestion>[];
    for (final t in transactions) {
      final amount = double.tryParse((t['amount'] ?? '0').toString()) ?? 0;
      if (amount >= 0) continue; // expenses only
      final title = (t['title'] ?? '').toString();
      final storedCategory = (t['category'] ?? 'General').toString();
      final inferred = categorizeMerchant(title);
      final keyword = matchedKeyword(title);
      if (inferred != null && inferred != storedCategory && keyword != null) {
        suggestions.add(MerchantSuggestion(
          transaction: t,
          inferredCategory: inferred,
          matchedKeyword: keyword,
        ));
      }
    }
    return suggestions;
  }

  // ────────────────────────────────────────────────
  // AI SPENDING ANALYST
  // ────────────────────────────────────────────────

  double _safeAmount(dynamic value) =>
      double.tryParse((value ?? '0').toString()) ?? 0;

  List<SpendingInsight> analyzeSpending(
    List<Map<String, dynamic>> transactions,
  ) {
    if (transactions.isEmpty) return [];

    final insights = <SpendingInsight>[];
    final expenses = transactions
        .where((t) => _safeAmount(t['amount']) < 0)
        .toList();

    if (expenses.isEmpty) return [];

    // 1. Top Category Percentage
    _topCategoryPercentage(expenses, insights);

    // 2. Weekend vs Weekday spending
    _weekendVsWeekday(expenses, insights);

    // 2. Category spending spikes (bi-weekly cycle detection)
    _categorySpikes(expenses, insights);

    // 3. Most expensive day of week
    _mostExpensiveDayOfWeek(expenses, insights);

    // 4. Recurring amount detection
    _recurringAmounts(expenses, insights);

    // 5. Late night spending
    _lateMorningSpending(expenses, insights, transactions);

    return insights;
  }

  void _topCategoryPercentage(
    List<Map<String, dynamic>> expenses,
    List<SpendingInsight> insights,
  ) {
    if (expenses.isEmpty) return;

    double totalExpense = 0;
    final Map<String, double> catTotals = {};

    for (final t in expenses) {
      final amount = _safeAmount(t['amount']).abs();
      final cat = (t['category'] ?? 'General').toString();
      totalExpense += amount;
      catTotals[cat] = (catTotals[cat] ?? 0) + amount;
    }

    if (totalExpense > 0 && catTotals.isNotEmpty) {
      final topCat = catTotals.entries.reduce((a, b) => a.value > b.value ? a : b);
      final pct = (topCat.value / totalExpense * 100).round();

      if (pct >= 20) {
        insights.add(SpendingInsight(
          emoji: '📊',
          title: 'Top Spending Category: ${topCat.key}',
          description:
              'You have spent $pct% of your total recorded expenses (₹${topCat.value.toStringAsFixed(0)}) strictly on ${topCat.key}.',
          type: InsightType.info,
        ));
      }
    }
  }

  void _weekendVsWeekday(
    List<Map<String, dynamic>> expenses,
    List<SpendingInsight> insights,
  ) {
    double weekendTotal = 0;
    int weekendDays = 0;
    double weekdayTotal = 0;
    int weekdayDays = 0;
    final Set<String> weekendDatesSeen = {};
    final Set<String> weekdayDatesSeen = {};

    for (final t in expenses) {
      try {
        final date = DateTime.parse(t['date'] ?? '2000-01-01');
        final amount = _safeAmount(t['amount']).abs();
        final dateStr = t['date'].toString();
        if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
          weekendTotal += amount;
          weekendDatesSeen.add(dateStr);
        } else {
          weekdayTotal += amount;
          weekdayDatesSeen.add(dateStr);
        }
      } catch (_) {}
    }

    weekendDays = weekendDatesSeen.length;
    weekdayDays = weekdayDatesSeen.length;

    if (weekendDays > 0 && weekdayDays > 0) {
      final avgWeekend = weekendTotal / weekendDays;
      final avgWeekday = weekdayTotal / weekdayDays;

      if (avgWeekend > avgWeekday * 1.2) {
        final pct = ((avgWeekend - avgWeekday) / avgWeekday * 100).round();
        insights.add(SpendingInsight(
          emoji: '📅',
          title: 'Weekend Spending Pattern',
          description:
              'You spend $pct% more per day on weekends than weekdays. '
              'Weekend avg: ₹${avgWeekend.toStringAsFixed(0)}, '
              'Weekday avg: ₹${avgWeekday.toStringAsFixed(0)}.',
          type: InsightType.pattern,
        ));
      } else if (avgWeekday > avgWeekend * 1.2) {
        final pct = ((avgWeekday - avgWeekend) / avgWeekend * 100).round();
        insights.add(SpendingInsight(
          emoji: '💼',
          title: 'Weekday Spender',
          description:
              'You spend $pct% more on weekdays — likely commute and work expenses. '
              'You\'re good at keeping weekends frugal!',
          type: InsightType.tip,
        ));
      } else {
        insights.add(SpendingInsight(
          emoji: '⚖️',
          title: 'Balanced Spending',
          description: 'Your spending is consistent across weekdays and weekends. Great discipline!',
          type: InsightType.info,
        ));
      }
    }
  }

  void _categorySpikes(
    List<Map<String, dynamic>> expenses,
    List<SpendingInsight> insights,
  ) {
    // Group by category, then by ISO week number
    final Map<String, Map<int, double>> catWeekMap = {};

    for (final t in expenses) {
      try {
        final date = DateTime.parse(t['date'] ?? '2000-01-01');
        final amount = _safeAmount(t['amount']).abs();
        final cat = (t['category'] ?? 'General').toString();
        final weekNum = _isoWeekNumber(date);

        catWeekMap.putIfAbsent(cat, () => {});
        catWeekMap[cat]![weekNum] = (catWeekMap[cat]![weekNum] ?? 0) + amount;
      } catch (_) {}
    }

    for (final entry in catWeekMap.entries) {
      final cat = entry.key;
      final weeklyAmounts = entry.value.values.toList()..sort();
      if (weeklyAmounts.length < 3) continue;

      // Compute median of all-but-last week
      final baseline = weeklyAmounts.sublist(0, weeklyAmounts.length - 1);
      final median = baseline[baseline.length ~/ 2];
      final lastWeek = weeklyAmounts.last;

      if (median > 0 && lastWeek > median * 1.4) {
        final pct = ((lastWeek - median) / median * 100).round();
        insights.add(SpendingInsight(
          emoji: '📈',
          title: '$cat Spending Spike',
          description:
              'Your $cat spending this week (₹${lastWeek.toStringAsFixed(0)}) '
              'is $pct% higher than your usual weekly average (₹${median.toStringAsFixed(0)}).',
          type: InsightType.warning,
        ));
      }
    }
  }

  void _mostExpensiveDayOfWeek(
    List<Map<String, dynamic>> expenses,
    List<SpendingInsight> insights,
  ) {
    final Map<int, double> dayTotals = {};
    final Map<int, int> dayCounts = {};
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    for (final t in expenses) {
      try {
        final date = DateTime.parse(t['date'] ?? '2000-01-01');
        final amount = _safeAmount(t['amount']).abs();
        final wd = date.weekday - 1; // 0=Mon, 6=Sun
        dayTotals[wd] = (dayTotals[wd] ?? 0) + amount;
        dayCounts[wd] = (dayCounts[wd] ?? 0) + 1;
      } catch (_) {}
    }

    if (dayTotals.isEmpty) return;

    final topDay = dayTotals.entries
        .reduce((a, b) =>
            (a.value / dayCounts[a.key]!) > (b.value / dayCounts[b.key]!) ? a : b);

    insights.add(SpendingInsight(
      emoji: '🗓️',
      title: '${dayNames[topDay.key]} is Your Biggest Spending Day',
      description:
          'You tend to spend the most on ${dayNames[topDay.key]}s. '
          'Average ₹${(topDay.value / dayCounts[topDay.key]!).toStringAsFixed(0)} per ${dayNames[topDay.key]}.',
      type: InsightType.info,
    ));
  }

  void _recurringAmounts(
    List<Map<String, dynamic>> expenses,
    List<SpendingInsight> insights,
  ) {
    // Find amounts appearing 3+ times (likely subscriptions/EMIs)
    final Map<String, int> amountCount = {};
    for (final t in expenses) {
      final amount = _safeAmount(t['amount']).abs();
      final key = amount.toStringAsFixed(0);
      if (amount > 0) {
        amountCount[key] = (amountCount[key] ?? 0) + 1;
      }
    }

    final recurring = amountCount.entries
        .where((e) => int.parse(e.key) >= 50 && e.value >= 3)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (recurring.isNotEmpty) {
      final top = recurring.first;
      insights.add(SpendingInsight(
        emoji: '🔄',
        title: 'Recurring Payment Detected',
        description:
            '₹${top.key} appears ${top.value} times in your transaction history — '
            'possibly a subscription or recurring bill.',
        type: InsightType.pattern,
      ));
    }
  }

  void _lateMorningSpending(
    List<Map<String, dynamic>> expenses,
    List<SpendingInsight> insights,
    List<Map<String, dynamic>> allTransactions,
  ) {
    // Check if total expenses > 80% of income (overspending warning)
    double totalIncome = 0;
    double totalExpense = 0;
    for (final t in allTransactions) {
      final amount = _safeAmount(t['amount']);
      if (amount > 0) totalIncome += amount;
      if (amount < 0) totalExpense += amount.abs();
    }

    if (totalIncome > 0) {
      final ratio = totalExpense / totalIncome;
      if (ratio > 0.9) {
        insights.add(SpendingInsight(
          emoji: '⚠️',
          title: 'High Expense-to-Income Ratio',
          description:
              'You\'ve spent ${(ratio * 100).toStringAsFixed(0)}% of your total recorded income. '
              'Try to keep expenses below 80% to build savings.',
          type: InsightType.warning,
        ));
      } else if (ratio < 0.5) {
        insights.add(SpendingInsight(
          emoji: '🌟',
          title: 'Excellent Savings Rate!',
          description:
              'You only spend ${(ratio * 100).toStringAsFixed(0)}% of your income. '
              'You\'re saving ${((1 - ratio) * 100).toStringAsFixed(0)}% — keep it up!',
          type: InsightType.tip,
        ));
      }
    }
  }

  int _isoWeekNumber(DateTime date) {
    final startOfYear = DateTime(date.year, 1, 1);
    final dayOfYear = date.difference(startOfYear).inDays;
    return (dayOfYear / 7).ceil();
  }

  // ────────────────────────────────────────────────
  // ANOMALY DETECTION
  // ────────────────────────────────────────────────

  List<AnomalyFlag> detectAnomalies(
    List<Map<String, dynamic>> transactions,
  ) {
    if (transactions.isEmpty) return [];
    final flags = <AnomalyFlag>[];

    final expenses = transactions
        .where((t) => _safeAmount(t['amount']) < 0)
        .toList();

    // 1. Duplicate charges (same title + amount within 48h)
    _detectDuplicates(expenses, flags);

    // 2. Sudden category spikes (single transaction > 3× category median)
    _detectSingleTransactionSpikes(expenses, flags);

    // 3. Unusually large transaction (> 50% of month's total expense)
    _detectOversizedTransaction(expenses, flags);

    // 4. Data integrity check (category vs sign mismatch)
    // We check all transactions here, not just filtered expenses
    _detectDataInconsistency(transactions, flags);

    // 5. Suspicious Title Detection
    _detectSuspiciousTitles(transactions, flags);

    return flags;
  }

  void _detectDataInconsistency(
    List<Map<String, dynamic>> allTransactions,
    List<AnomalyFlag> flags,
  ) {
    // List of keywords that strongly indicate an expense
    const expenseCategories = {
      'Food',
      'Transport',
      'Entertainment',
      'Shopping',
      'Bills',
      'Healthcare',
      'Education',
      'EMI'
    };
    // List of keywords that strongly indicate income
    const incomeCategories = {
      'Salary',
      'Bonus',
      'Investment Returns',
      'Freelance',
      'Rental Income'
    };

    for (final t in allTransactions) {
      final amount = _safeAmount(t['amount']);
      final cat = (t['category'] ?? '').toString();
      final isExpenseFlag = t['is_expense'] == 1 || t['is_expense'] == true;

      // Check 1: Flag vs Amount sign mismatch
      if (t.containsKey('is_expense')) {
        if (isExpenseFlag && amount > 0) {
          flags.add(AnomalyFlag(
            emoji: '⚠️',
            title: 'Data Integrity Mismatch',
            description:
                'Transaction "${t['title']}" is marked as an expense but has a positive amount (₹$amount). This will distort your reports.',
            severity: AnomalySeverity.alert,
            transaction: t,
          ));
          continue; // Move to next to avoid double flagging
        }
      }

      // Check 2: Category vs Amount sign mismatch
      if (amount > 0 && expenseCategories.contains(cat)) {
        flags.add(AnomalyFlag(
          emoji: '❓',
          title: 'Suspicious Income Category',
          description:
              'Income of ₹$amount recorded in "$cat" category. Usually, $cat is an expense. Please verify.',
          severity: AnomalySeverity.warning,
          transaction: t,
        ));
      } else if (amount < 0 && incomeCategories.contains(cat)) {
        flags.add(AnomalyFlag(
          emoji: '❓',
          title: 'Suspicious Expense Category',
          description:
              'Expense of ₹${amount.abs()} recorded in "$cat" category. Usually, $cat is income. Please verify.',
          severity: AnomalySeverity.warning,
          transaction: t,
        ));
      }
    }
  }

  void _detectDuplicates(
    List<Map<String, dynamic>> expenses,
    List<AnomalyFlag> flags,
  ) {
    final seen = <String, Map<String, dynamic>>{};

    for (final t in expenses) {
      final title = (t['title'] ?? '').toString().toLowerCase().trim();
      final amount = _safeAmount(t['amount']).abs().toStringAsFixed(2);
      final dateStr = t['date']?.toString() ?? '';
      final key = '${title}_$amount';

      if (seen.containsKey(key)) {
        final prevDateStr = seen[key]!['date']?.toString() ?? '';
        try {
          final prevDate = DateTime.parse(prevDateStr);
          final currDate = DateTime.parse(dateStr);
          final diff = currDate.difference(prevDate).abs().inHours;
          if (diff <= 48) {
            flags.add(AnomalyFlag(
              emoji: '🔁',
              title: 'Possible Duplicate Charge',
              description:
                  '"${t['title']}" for ₹$amount was charged twice within ${diff}h. '
                  'This could be a double-billing error.',
              severity: AnomalySeverity.alert,
              transaction: t,
            ));
          }
        } catch (_) {}
      } else {
        seen[key] = t;
      }
    }
  }

  void _detectSingleTransactionSpikes(
    List<Map<String, dynamic>> expenses,
    List<AnomalyFlag> flags,
  ) {
    // Group amounts by category
    final Map<String, List<double>> catAmounts = {};
    for (final t in expenses) {
      final cat = (t['category'] ?? 'General').toString();
      final amount = _safeAmount(t['amount']).abs();
      catAmounts.putIfAbsent(cat, () => []).add(amount);
    }

    // For each transaction, check if it's > 3× its category median
    for (final t in expenses) {
      final cat = (t['category'] ?? 'General').toString();
      final amount = _safeAmount(t['amount']).abs();
      final amounts = List<double>.from(catAmounts[cat] ?? [])..sort();

      if (amounts.length < 3) continue;
      final median = amounts[amounts.length ~/ 2];

      if (median > 0 && amount > median * 3) {
        flags.add(AnomalyFlag(
          emoji: '🚨',
          title: 'Unusual Spike in $cat',
          description:
              '"${t['title']}" (₹${amount.toStringAsFixed(0)}) is '
              '${(amount / median).toStringAsFixed(1)}× your usual $cat spend of ₹${median.toStringAsFixed(0)}.',
          severity: AnomalySeverity.alert,
          transaction: t,
        ));
      }
    }
  }

  void _detectOversizedTransaction(
    List<Map<String, dynamic>> expenses,
    List<AnomalyFlag> flags,
  ) {
    // Group by month
    final Map<String, double> monthTotals = {};
    for (final t in expenses) {
      try {
        final date = DateTime.parse(t['date'] ?? '2000-01-01');
        final key = '${date.year}-${date.month}';
        monthTotals[key] = (monthTotals[key] ?? 0) + _safeAmount(t['amount']).abs();
      } catch (_) {}
    }

    for (final t in expenses) {
      try {
        final date = DateTime.parse(t['date'] ?? '2000-01-01');
        final key = '${date.year}-${date.month}';
        final monthTotal = monthTotals[key] ?? 0;
        final amount = _safeAmount(t['amount']).abs();

        if (monthTotal > 0 && amount > monthTotal * 0.5 && amount > 1000) {
          final pct = (amount / monthTotal * 100).round();
          flags.add(AnomalyFlag(
            emoji: '💸',
            title: 'Large Single Transaction',
            description:
                '"${t['title']}" (₹${amount.toStringAsFixed(0)}) accounts for '
                '$pct% of your total spending that month.',
            severity: AnomalySeverity.warning,
            transaction: t,
          ));
          break; // Only flag the most impactful one per month
        }
      } catch (_) {}
    }
  }

  void _detectSuspiciousTitles(
    List<Map<String, dynamic>> allTransactions,
    List<AnomalyFlag> flags,
  ) {
    const suspiciousKeywords = {
      'scam',
      'fraud',
      'hacked',
      'fake',
      'unauthorized',
      'stolen',
      'test',
      'demo',
      'placeholder',
      'unknown',
      'suspicious',
      'error',
      'bug',
      'yes',
      'no',
      'ok',
      'okay',
      'none',
      'nothing',
      'temp',
    };

    for (final t in allTransactions) {
      final title = (t['title'] ?? '').toString().toLowerCase().trim();
      if (title.isEmpty) continue;

      bool flagged = false;

      // 1. Keyword check
      for (final word in suspiciousKeywords) {
        if (title.contains(word)) {
          flags.add(AnomalyFlag(
            emoji: '🏷️',
            title: 'Suspicious Transaction Name',
            description:
                'The name "$title" contains words like "$word" which might indicate an error or unauthorized entry.',
            severity: AnomalySeverity.warning,
            transaction: t,
          ));
          flagged = true;
          break;
        }
      }
      if (flagged) continue;

      // 2. Symbolic/Gibberish check (No letters or numbers)
      if (!RegExp(r'[a-zA-Z0-9]').hasMatch(title)) {
        flags.add(AnomalyFlag(
          emoji: '🧩',
          title: 'Cryptic Transaction Name',
          description:
              'The name "$title" contains only symbols. This might be a placeholder or a corrupted entry.',
          severity: AnomalySeverity.warning,
          transaction: t,
        ));
        continue;
      }

      // 3. Repetitive characters (e.g. "aaaaa" or "11111")
      if (RegExp(r'(.)\1{4,}').hasMatch(title)) {
        flags.add(AnomalyFlag(
          emoji: '🤔',
          title: 'Unusual Name Pattern',
          description:
              'The name "$title" has highly repetitive characters. Please verify if this is a real transaction.',
          severity: AnomalySeverity.warning,
          transaction: t,
        ));
        continue;
      }

      // 4. Very short non-standard name
      if (title.length < 2 && !RegExp(r'[a-zA-Z]').hasMatch(title)) {
        flags.add(AnomalyFlag(
          emoji: '📏',
          title: 'Incomplete Transaction Name',
          description:
              'The name "$title" is too short to be descriptive. High-quality data helps AI give better insights!',
          severity: AnomalySeverity.warning,
          transaction: t,
        ));
        continue;
      }
    }
  }

  // ── ADVANCED PRO FEATURES ──

  /// Calculate a Financial Health Score (1-100)
  int calculateFinancialHealthScore(
    List<Map<String, dynamic>> transactions,
    List<AnomalyFlag> anomalies,
  ) {
    if (transactions.isEmpty) return 0;
    
    double income = 0;
    double expense = 0;
    for (final t in transactions) {
      final amt = _safeAmount(t['amount']);
      if (amt > 0) income += amt;
      else if (amt < 0) expense += amt.abs();
    }

    // 1. Savings Rate (40 points)
    double savingsScore = 0;
    if (income > 0) {
      final rate = (income - expense) / income;
      if (rate >= 0.3) savingsScore = 40; // 30%+ savings is perfect
      else if (rate > 0) savingsScore = (rate / 0.3) * 40;
    }

    // 2. Anomaly Regularity (30 points)
    // Fewer anomalies = higher score
    double anomalyScore = 30;
    if (anomalies.isNotEmpty) {
      anomalyScore = (30 - (anomalies.length * 5)).clamp(0, 30).toDouble();
    }

    // 3. Consistency (30 points)
    // Based on transaction count 
    double consistencyScore = 30;
    if (transactions.length < 10) consistencyScore = 10;
    else if (transactions.length < 20) consistencyScore = 20;

    return (savingsScore + anomalyScore + consistencyScore).round().clamp(0, 100);
  }

  /// Forecast total spending for the current month
  double getMonthlyForecast(List<Map<String, dynamic>> transactions) {
    final now = DateTime.now();
    final firstOfMonth = DateTime(now.year, now.month, 1);
    
    double monthToDateExpense = 0;
    for (final t in transactions) {
      try {
        final date = DateTime.parse(t['date'] ?? '');
        if (date.isAfter(firstOfMonth) || date.isAtSameMomentAs(firstOfMonth)) {
          final amt = _safeAmount(t['amount']);
          if (amt < 0) monthToDateExpense += amt.abs();
        }
      } catch (_) {}
    }

    final daysPassed = now.day;
    final totalDaysInMonth = DateTime(now.year, now.month + 1, 0).day;
    
    if (daysPassed == 0) return monthToDateExpense;
    
    final dailyVelocity = monthToDateExpense / daysPassed;
    return dailyVelocity * totalDaysInMonth;
  }

  /// Suggest realistic budget limits based on historical medians
  Map<String, double> getBudgetSuggestions(List<Map<String, dynamic>> transactions) {
    final Map<String, List<double>> catHistory = {};
    for (final t in transactions) {
      final amt = _safeAmount(t['amount']);
      if (amt < 0) {
        final cat = (t['category'] ?? 'General').toString();
        catHistory.putIfAbsent(cat, () => []).add(amt.abs());
      }
    }

    final Map<String, double> suggestions = {};
    for (final entry in catHistory.entries) {
      final sorted = List<double>.from(entry.value)..sort();
      if (sorted.isEmpty) continue;
      final median = sorted[sorted.length ~/ 2];
      // Suggest median + 15% buffer, rounded to nearest 100
      suggestions[entry.key] = ((median * 1.15) / 100).ceil() * 100;
    }
    return suggestions;
  }
}
