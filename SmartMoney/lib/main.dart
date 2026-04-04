import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math' as math;
import 'dart:io';
import 'dart:async';
import 'dart:ui';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'database_helper.dart';
import 'auth_service.dart';
import 'login_page.dart';
import 'notification_service.dart';
import 'ai_analyst_service.dart';
import 'biometric_service.dart';
import 'intro_screen.dart' as intro_screen;

Future<void> _initializeServices() async {
  debugPrint('=== STARTING SERVICE INITIALIZATION ===');

  // Initialize Firebase with timeout
  debugPrint('Step 1: Initializing Firebase...');
  try {
    debugPrint('  - Firebase.initializeApp starting...');

    final firebaseInit =
        Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        ).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('  - Firebase initialization TIMEOUT!');
            throw TimeoutException('Firebase init timeout');
          },
        );

    await firebaseInit;
    debugPrint('✓ Firebase initialized successfully');
  } catch (e, st) {
    debugPrint('✗ Firebase initialization error: $e');
    debugPrint('  Stack: $st');
    debugPrint('  WARNING: App will continue without Firebase');
  }

  // Initialize notifications
  debugPrint('Step 2: Initializing NotificationService...');
  try {
    await NotificationService().initialize();
    debugPrint('✓ Notification service initialized');
  } catch (e, st) {
    debugPrint('✗ Notification service error: $e');
    debugPrint('  Stack: $st');
  }

  // Initialize Auth service data state
  debugPrint('Step 3: Initializing AuthService data state...');
  try {
    await AuthService.instance.initialize();
    debugPrint('✓ Auth service initialized');
  } catch (e, st) {
    debugPrint('✗ Auth service init error: $e');
    debugPrint('  Stack: $st');
  }

  debugPrint('=== SERVICE INITIALIZATION COMPLETE ===');
}

void main() async {
  debugPrint('APP STARTUP: Ensuring Flutter binding...');
  WidgetsFlutterBinding.ensureInitialized();

  // Global error handler
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('🔴 FlutterError: ${details.exception}');
    debugPrint('   Stack: ${details.stack}');
  };

  debugPrint('APP STARTUP: Starting MoneyManagerApp...');
  runApp(const MoneyManagerApp());
}

/// Error app to display startup errors
class ErrorApp extends StatelessWidget {
  final String error;
  final String stackTrace;

  const ErrorApp({required this.error, required this.stackTrace, super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Error',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Application Error'),
          backgroundColor: Colors.red,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'An error occurred during app startup:',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red),
                ),
                child: Text(
                  error,
                  style: const TextStyle(fontSize: 14, fontFamily: 'Courier'),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Stack Trace:',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey),
                ),
                child: Text(
                  stackTrace,
                  style: const TextStyle(fontSize: 12, fontFamily: 'Courier'),
                  maxLines: 30,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  exit(0);
                },
                icon: const Icon(Icons.close),
                label: const Text('Exit App'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MoneyManagerApp extends StatefulWidget {
  const MoneyManagerApp({super.key});

  @override
  State<MoneyManagerApp> createState() => _MoneyManagerAppState();
}

class _MoneyManagerAppState extends State<MoneyManagerApp>
    with WidgetsBindingObserver {
  bool isDarkMode = false;
  bool _isInitialized = false;
  bool _appNeedsLock = true; // Initially true for cold start

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadTheme();
    _initApp();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        isDarkMode = prefs.getBool('is_dark_mode') ?? false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // App went to background, it will need a lock when it comes back
      _appNeedsLock = true;
    } else if (state == AppLifecycleState.resumed) {
      _handleBiometricLock();
    }
  }

  Future<void> _initApp() async {
    try {
      await _initializeServices();
      await _handleBiometricLock();
    } finally {
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    }
  }

  bool _isAuthenticating = false;

  Future<void> _handleBiometricLock() async {
    if (_isAuthenticating || !_appNeedsLock) return;

    try {
      final bool isLockEnabled = await BiometricService.instance
          .isLockEnabled();
      if (!isLockEnabled) {
        if (mounted) setState(() => _appNeedsLock = false);
        return;
      }
    } catch (e) {
      debugPrint('Biometric check error: $e');
      if (mounted) setState(() => _appNeedsLock = false);
      return;
    }

    _isAuthenticating = true;
    try {
      bool authenticated = false;
      int retryCount = 0;
      // Safety limit: Don't retry more than 3 times automatically to avoid locking out the user
      while (!authenticated && mounted && retryCount < 3) {
        authenticated = await BiometricService.instance.authenticate();
        if (authenticated) {
          if (mounted) setState(() => _appNeedsLock = false);
        } else {
          retryCount++;
          if (mounted) {
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }
      // If still not authenticated after retries, we might want to allow
      // standard login instead of blocking forever, but for now we'll just
      // stop the automatic retry.
    } finally {
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
        });
      }
    }
  }

  ThemeData _buildLightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorSchemeSeed: const Color(0xFF6366F1), // Indigo
      scaffoldBackgroundColor: const Color(0xFFF9FAFB),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF1F2937),
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        color: Colors.white,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6366F1), // Indigo
        brightness: Brightness.dark,
        primary: const Color(0xFF818CF8), // Indigo 400
        surface: const Color(0xFF1E293B), // Slate 800
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
      appBarTheme: const AppBarTheme(
        elevation: 0,
        backgroundColor: Color(0xFF0F172A),
        foregroundColor: Colors.white,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
        color: const Color(0xFF1E293B), // Slate 800
      ),
      bottomAppBarTheme: const BottomAppBarThemeData(
        color: Color(0xFF1E293B),
        elevation: 8,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: const Color(0xFF6366F1),
        ),
      ),
    );
  }

  Future<void> _toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      isDarkMode = !isDarkMode;
      prefs.setBool('is_dark_mode', isDarkMode);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartBudget',
      debugShowCheckedModeBanner: false,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: _isInitialized
          ? const intro_screen.IntroScreen()
          : const _MoneyLoadingScreen(),
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final headerBg = isDark ? const Color(0xFF1E293B) : Colors.white;
        final headerTextColor = isDark ? Colors.white : const Color(0xFF1E3A8A);
        final subTextColor = isDark ? Colors.white70 : Colors.black87;

        return Column(
          children: [
            // ── College Header Banner ──
            Material(
              color: headerBg,
              elevation: 4,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Logo
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF1E3A8A),
                            width: 2,
                          ),
                          color: Colors.white,
                        ),
                        child: ClipOval(
                          child: Image.asset(
                            'assets/college_logo.jpg',
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: const Color(0xFF1E3A8A),
                              child: const Center(
                                child: Text(
                                  'GVP',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // College Details
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'GAYATRI VIDYA PARISHAD COLLEGE FOR DEGREE AND PG COURSES (A)',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                color: headerTextColor,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Department of Computer Science and Engineering',
                              style: TextStyle(
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                                color: subTextColor,
                                height: 1.2,
                              ),
                            ),
                            // Text(
                            //   '(MBA and UG Engineering B.Tech programs are Accredited by NBA)',
                            //   style: TextStyle(
                            //     fontSize: 8.5,
                            //     fontStyle: FontStyle.italic,
                            //     color: subTextColor,
                            //     height: 1.2,
                            //   ),
                            // ),
                            // Text(
                            //   'Visakhapatnam – 530045.',
                            //   style: TextStyle(
                            //     fontSize: 8.5,
                            //     fontWeight: FontWeight.bold,
                            //     color: subTextColor,
                            //     height: 1.3,
                            //   ),
                            // ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Main App Content ──
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: child ?? const SizedBox.shrink(),
              ),
            ),

            // ── Project Guide Footer ──
            Material(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Project Guide: Mr. Sri T. SriKrishna',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Future<void> _toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('is_dark_mode') ?? false;
    prefs.setBool('is_dark_mode', !isDark);
    // Note: Since theme toggle needs to update MaterialApp,
    // it usually needs to be handled higher up. But for now
    // we just let SafeHomePage trigger a rebuild if possible or
    // we can rely on context.findAncestorStateOfType<_MoneyManagerAppState>()
    if (context.mounted) {
      final appState = context.findAncestorStateOfType<_MoneyManagerAppState>();
      appState?._toggleTheme();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: AuthService.instance.authStateChanges,
      initialData: AuthService.instance.isLoggedIn,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _MoneyLoadingScreen();
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  const Text('Authentication Error'),
                  const SizedBox(height: 8),
                  Text(
                    snapshot.error.toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () async {
                      await AuthService.instance.logout();
                    },
                    child: const Text('Return to Login'),
                  ),
                ],
              ),
            ),
          );
        }

        final bool isLoggedIn = snapshot.data == true;

        if (isLoggedIn) {
          return SafeHomePage(onToggleTheme: _toggleTheme);
        } else {
          return const LoginPage();
        }
      },
    );
  }
}

enum TransactionFilter { all, income, expense }

class BudgetAlert {
  final String category;
  final double spent;
  final double limit;
  final double usage;

  const BudgetAlert({
    required this.category,
    required this.spent,
    required this.limit,
    required this.usage,
  });
}

class SafeHomePage extends StatelessWidget {
  final VoidCallback onToggleTheme;

  const SafeHomePage({required this.onToggleTheme, super.key});

  @override
  Widget build(BuildContext context) {
    return ErrorHandler(child: HomePage(onToggleTheme: onToggleTheme));
  }
}

class ErrorHandler extends StatefulWidget {
  final Widget child;

  const ErrorHandler({required this.child, super.key});

  @override
  State<ErrorHandler> createState() => _ErrorHandlerState();
}

class _ErrorHandlerState extends State<ErrorHandler> {
  Object? error;
  StackTrace? stackTrace;

  @override
  void initState() {
    super.initState();
    FlutterError.onError = (FlutterErrorDetails details) {
      setState(() {
        error = details.exception;
        stackTrace = details.stack;
      });
    };
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'An error occurred:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Text(error.toString(), style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              if (stackTrace != null) ...[
                const Text(
                  'Stack Trace:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(stackTrace.toString()),
              ],
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () async {
                  await AuthService.instance.logout();
                },
                icon: const Icon(Icons.logout),
                label: const Text('Logout & Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    return widget.child;
  }
}

class HomePage extends StatefulWidget {
  final VoidCallback onToggleTheme;

  const HomePage({required this.onToggleTheme, super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final TextEditingController amountController = TextEditingController();
  final TextEditingController titleController = TextEditingController();
  final TextEditingController searchController = TextEditingController();
  final TextEditingController emiMonthsController = TextEditingController();
  final TextEditingController emiInterestRateController =
      TextEditingController();
  final TextEditingController newCategoryController = TextEditingController();
  final TextEditingController budgetLimitController = TextEditingController();

  List<Map<String, dynamic>> transactions = [];
  List<String> incomeCategories = [];
  List<String> expenseCategories = [];
  TransactionFilter selectedFilter = TransactionFilter.all;
  bool isExpense = true;
  bool isLoading = true;
  DateTime selectedDate = DateTime.now();
  DateTimeRange? insightsDateRange;
  String selectedCategory = 'General';
  String selectedBudgetCategory = '';
  int currentTabIndex = 0;
  bool isEMI = false;
  DateTime? emiStartDate;
  int emiMonths = 1;
  DateTime? emiDueDate;
  DateTime? emiLastPaymentDate;
  double emiInterestRate = 0.0;
  Map<String, double> categoryBudgets = {};
  Map<String, double> categorySpending = {};
  bool showBudgetWarnings = true;
  final Set<String> _dismissedWarnings = {};
  int emiReminderDays = 3; // Days before EMI to show reminder
  String _currencySymbol = '₹';

  // --- Top Notification State ---
  String? _notificationMessage;
  IconData? _notificationIcon;
  Color? _notificationColor;
  bool _isNotificationVisible = false;
  bool _isNotificationExpanded = false;
  Timer? _notificationTimer;

  List<Map<String, dynamic>> savingsGoals = [];
  int? _selectedSavingsGoalId;
  int durationMonths = 12; // Default duration for subscriptions
  List<Map<String, dynamic>> recurringTransactions = [];
  bool isRecurring = false;
  String selectedInterval = 'monthly';

  // Profile fields
  Map<String, dynamic> _userProfile = {};
  bool _profileLoaded = false;

  // AI Analyst state
  final Set<int> _dismissedAnomalyIds = {};
  List<SpendingInsight> _cachedInsights = [];
  List<AnomalyFlag> _cachedAnomalies = [];
  List<MerchantSuggestion> _cachedSuggestions = [];
  int _cachedHealthScore = 0;
  double _cachedForecast = 0;
  Map<String, double> _cachedBudgetSuggestions = {};
  bool _aiDataLoading = false;

  // Database sync subscription
  StreamSubscription? _dbSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      debugPrint('_HomePageState initState: Starting initialization...');
      _loadCategories();
      _loadBudgets();
      loadTransactions();
      _loadUserProfile();

      // Listen for background data changes (e.g., from Firebase sync)
      _dbSubscription = DatabaseHelper.instance.onDataChanged.listen((_) {
        debugPrint(
          'DatabaseHelper: Data change notification received. Refreshing UI...',
        );
        if (mounted) {
          _loadCategories();
          _loadBudgets();
          loadTransactions();
          _loadSavingsGoals();
          _loadUserProfile(forceReload: true);
          _loadRecurringTemplates();
        }
      });

      debugPrint('_HomePageState initState: Initialization complete');
    } catch (e, st) {
      debugPrint('_HomePageState initState error: $e');
      debugPrint('Stack: $st');
      if (mounted) {
        _showMessage('Error during app setup: $e');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    amountController.dispose();
    titleController.dispose();
    searchController.dispose();
    emiMonthsController.dispose();
    emiInterestRateController.dispose();
    newCategoryController.dispose();
    budgetLimitController.dispose();
    _dbSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('App resumed: Refreshing data...');
      loadTransactions();
    }
  }

  /// Returns true if the transaction was created within the last 12 hours.
  bool _canDelete(Map<String, dynamic> t) {
    final raw = t['created_at']?.toString();
    if (raw != null && raw.isNotEmpty) {
      final created = DateTime.tryParse(raw);
      if (created != null) {
        // Strict 12 hour check
        final diff = DateTime.now().difference(created);
        return diff.inMinutes < 12 * 60;
      }
    }

    // Fallback for legacy transactions without created_at:
    final dateRaw = t['date']?.toString();
    if (dateRaw != null && dateRaw.isNotEmpty) {
      final txDate = DateTime.tryParse(dateRaw);
      if (txDate != null) {
        final now = DateTime.now();
        // Fallback: If it's from a previous day, lock it.
        // If it's today, we can't be sure of the hour without created_at,
        // but we'll allow it for better UX on legacy data.
        final today = DateTime(now.year, now.month, now.day);
        final txDay = DateTime(txDate.year, txDate.month, txDate.day);
        return !txDay.isBefore(today);
      }
    }

    return false;
  }

  Future<void> _addDemoData() async {
    // Confirm with user first
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // title: const Text('Add Demo Data'),
        content: const Text(
          'This will add sample transactions, budgets, and savings goals to your account so you can explore the app. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add Demo Data'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Phase 3: Pick demo type
    final demoType = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Demo Data Mode'),
        content: const Text(
          'Choose "Clean Data" for a perfect history, or "Show AI Features" to add intentional errors (like sign mismatches and outliers) for the AI to detect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'clean'),
            child: const Text('Clean Data'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'anomalies'),
            child: const Text('Show AI Features'),
          ),
        ],
      ),
    );
    if (demoType == null) return;
    final bool isAnomalous = demoType == 'anomalies';

    // Offer to clear existing first for a cleaner demo
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fresh Start?'),
        content: const Text(
          'Would you like to clear existing transactions before adding demo data? This ensures a cleaner look.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep Existing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    final db = DatabaseHelper.instance;
    if (shouldClear == true) {
      await db.clearDatabase();
    }

    final now = DateTime.now();
    final math.Random random = math.Random();

    // Setup some realistic category-title pairs
    final incomeSources = [
      {
        'title': 'Monthly Salary',
        'category': 'Salary',
        'base': 45000.0,
        'var': 10000,
      },
      {
        'title': 'Freelance Work',
        'category': 'Freelance',
        'base': 5000.0,
        'var': 8000,
      },
      {
        'title': 'Investment Dividend',
        'category': 'Investment Returns',
        'base': 1000.0,
        'var': 3000,
      },
      {'title': 'Gift', 'category': 'Gift', 'base': 500.0, 'var': 2000},
    ];

    final expenseSources = [
      {
        'title': 'Big Bazaar Groceries',
        'category': 'Food',
        'base': 1200.0,
        'var': 2500,
      },
      {
        'title': 'Zomato/Swiggy',
        'category': 'Food',
        'base': 300.0,
        'var': 1000,
      },
      {
        'title': 'Shell Fuel',
        'category': 'Transport',
        'base': 1500.0,
        'var': 1500,
      },
      {
        'title': 'Uber/Ola Ride',
        'category': 'Transport',
        'base': 150.0,
        'var': 500,
      },
      {
        'title': 'Electricity Bill',
        'category': 'Bills',
        'base': 1200.0,
        'var': 1000,
      },
      {
        'title': 'Netflix/Prime',
        'category': 'Entertainment',
        'base': 199.0,
        'var': 500,
      },
      {
        'title': 'Cinema Tickets',
        'category': 'Entertainment',
        'base': 400.0,
        'var': 800,
      },
      {
        'title': 'Amazon Shopping',
        'category': 'Shopping',
        'base': 800.0,
        'var': 4000,
      },
      {
        'title': 'Pharmacy',
        'category': 'Healthcare',
        'base': 200.0,
        'var': 1500,
      },
      {'title': 'Home Loan EMI', 'category': 'EMI', 'base': 15000.0, 'var': 0},
    ];

    // Helper to build a date within a given month
    DateTime dateInMonth(
      int year,
      int month,
      int day, {
      int hour = 10,
      int minute = 0,
    }) {
      final maxDay = DateTime(year, month + 1, 0).day; // last day of the month
      return DateTime(year, month, day.clamp(1, maxDay), hour, minute);
    }

    // ── Determine this month and last month ──
    final thisMonth = now.month;
    final thisYear = now.year;
    final lastMonth = thisMonth == 1 ? 12 : thisMonth - 1;
    final lastMonthYear = thisMonth == 1 ? thisYear - 1 : thisYear;

    // ── THIS MONTH transactions ──
    // Salary (1st of this month)
    await db.insertTransaction({
      'title': 'Monthly Salary',
      'amount': 85000.0,
      'category': 'Salary',
      'date': dateInMonth(thisYear, thisMonth, 1).toIso8601String(),
      'notes': 'Demo: This month salary',
      'is_expense': 0,
      'created_at': dateInMonth(thisYear, thisMonth, 1).toIso8601String(),
    });
    // Freelance income
    await db.insertTransaction({
      'title': 'Freelance Work',
      'amount': 8500.0,
      'category': 'Freelance',
      'date': dateInMonth(thisYear, thisMonth, 3, hour: 14).toIso8601String(),
      'notes': 'Demo: Freelance payment this month',
      'is_expense': 0,
      'created_at': dateInMonth(
        thisYear,
        thisMonth,
        3,
        hour: 14,
      ).toIso8601String(),
    });
    // Groceries
    await db.insertTransaction({
      'title': 'Big Bazaar Groceries',
      'amount': -2100.0,
      'category': 'Food',
      'date': dateInMonth(thisYear, thisMonth, 2, hour: 11).toIso8601String(),
      'notes': 'Demo: Monthly grocery run',
      'is_expense': 1,

      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        4,
        hour: 11,
      ).toIso8601String(),
    });
    // Online delivery last month
    await db.insertTransaction({
      'title': 'Zomato/Swiggy',
      'amount': -620.0,
      'category': 'Food',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        10,
        hour: 19,
      ).toIso8601String(),
      'notes': 'Demo: Last month food order',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        10,
        hour: 19,
      ).toIso8601String(),
    });
    // Fuel last month
    await db.insertTransaction({
      'title': 'Shell Fuel',
      'amount': -1900.0,
      'category': 'Transport',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        5,
        hour: 8,
      ).toIso8601String(),
      'notes': 'Demo: Last month fuel',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        5,
        hour: 8,
      ).toIso8601String(),
    });
    // Uber ride last month
    await db.insertTransaction({
      'title': 'Uber/Ola Ride',
      'amount': -320.0,
      'category': 'Transport',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        18,
        hour: 22,
      ).toIso8601String(),
      'notes': 'Demo: Late night cab',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        18,
        hour: 22,
      ).toIso8601String(),
    });
    // Electricity bill last month
    await db.insertTransaction({
      'title': 'Electricity Bill',
      'amount': -1650.0,
      'category': 'Bills',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        3,
        hour: 16,
      ).toIso8601String(),
      'notes': 'Demo: Last month electricity',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        3,
        hour: 16,
      ).toIso8601String(),
    });
    // Cinema last month
    await db.insertTransaction({
      'title': 'Cinema Tickets',
      'amount': -800.0,
      'category': 'Entertainment',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        20,
        hour: 18,
      ).toIso8601String(),
      'notes': 'Demo: Weekend movie',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        20,
        hour: 18,
      ).toIso8601String(),
    });
    // Shopping last month
    await db.insertTransaction({
      'title': 'Amazon Shopping',
      'amount': -5500.0,
      'category': 'Shopping',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        12,
        hour: 14,
      ).toIso8601String(),
      'notes': 'Demo: Last month online shopping',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        12,
        hour: 14,
      ).toIso8601String(),
    });
    // Healthcare last month
    await db.insertTransaction({
      'title': 'Pharmacy',
      'amount': -750.0,
      'category': 'Healthcare',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        22,
        hour: 11,
      ).toIso8601String(),
      'notes': 'Demo: Medical expense',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        22,
        hour: 11,
      ).toIso8601String(),
    });
    // EMI last month
    await db.insertTransaction({
      'title': 'Home Loan EMI',
      'amount': -15000.0,
      'category': 'EMI',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        1,
        hour: 8,
      ).toIso8601String(),
      'notes': 'Demo: Last month EMI',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        1,
        hour: 8,
      ).toIso8601String(),
      'interest_rate': 8.5,
      'due_date': dateInMonth(lastMonthYear, lastMonth, 1).toIso8601String(),
    });
    // Streaming last month
    await db.insertTransaction({
      'title': 'Netflix/Prime',
      'amount': -649.0,
      'category': 'Entertainment',
      'date': dateInMonth(
        lastMonthYear,
        lastMonth,
        1,
        hour: 12,
      ).toIso8601String(),
      'notes': 'Demo: Streaming subscription last month',
      'is_expense': 1,
      'created_at': dateInMonth(
        lastMonthYear,
        lastMonth,
        1,
        hour: 12,
      ).toIso8601String(),
    });

    // ── OLDER history: 15 randomised transactions (days 35–90 ago) ──
    // In clean mode, also add guaranteed salary for 2 months back
    if (!isAnomalous) {
      final twoMonthsAgo = now.month <= 2
          ? DateTime(now.year - 1, now.month + 10, 1)
          : DateTime(now.year, now.month - 2, 1);
      await db.insertTransaction({
        'title': 'Monthly Salary',
        'amount': 85000.0,
        'category': 'Salary',
        'date': twoMonthsAgo.toIso8601String(),
        'notes': 'Demo: Steady Base Income (2 months ago)',
        'is_expense': 0,
        'created_at': twoMonthsAgo.toIso8601String(),
      });
    }

    for (int i = 0; i < 15; i++) {
      final bool isExpense = random.nextDouble() > 0.30; // 70% expenses
      final int daysAgo = 35 + random.nextInt(56); // 35–90 days ago
      final int hoursAgo = random.nextInt(24);
      final int minsAgo = random.nextInt(60);

      final txDateTime = now.subtract(
        Duration(days: daysAgo, hours: hoursAgo, minutes: minsAgo),
      );

      // Inject anomalies if requested
      if (isAnomalous && random.nextDouble() < 0.2) {
        final int type = random.nextInt(6);
        if (type == 0) {
          await db.insertTransaction({
            'title': 'Anomalous Entry (Sign Mismatch)',
            'amount': 2500.0,
            'category': 'Food',
            'date': txDateTime.toIso8601String(),
            'notes': 'AI Test: Positive amount in expense category',
          });
          continue;
        } else if (type == 1) {
          await db.insertTransaction({
            'title': 'Anomalous Entry (Outlier)',
            'amount': -45000.0,
            'category': 'Shopping',
            'date': txDateTime.toIso8601String(),
            'is_expense': 1,
            'notes': 'AI Test: Unusually high transaction',
          });
          continue;
        } else if (type == 2) {
          final duplicateTx = {
            'title': 'Anomalous Entry (Duplicate)',
            'amount': -1250.0,
            'category': 'Entertainment',
            'date': txDateTime.toIso8601String(),
            'is_expense': 1,
            'notes': 'AI Test: Duplicate entry',
          };
          await db.insertTransaction(duplicateTx);
          await db.insertTransaction(duplicateTx);
          continue;
        } else if (type == 3) {
          final lateNight = DateTime(
            txDateTime.year,
            txDateTime.month,
            txDateTime.day,
            3,
            15,
          );
          await db.insertTransaction({
            'title': 'Anomalous Entry (Late Night)',
            'amount': -850.0,
            'category': 'Transport',
            'date': lateNight.toIso8601String(),
            'is_expense': 1,
            'notes': 'AI Test: Transaction at 3:15 AM',
          });
          continue;
        } else if (type == 4) {
          await db.insertTransaction({
            'title': 'Unknown SCAM entry',
            'amount': -500.0,
            'category': 'General',
            'date': txDateTime.toIso8601String(),
            'is_expense': 1,
            'notes': 'AI Test: Suspicious name detection',
          });
          continue;
        } else if (type == 5) {
          await db.insertTransaction({
            'title': 'aaaaaaa',
            'amount': -150.0,
            'category': 'General',
            'date': txDateTime.toIso8601String(),
            'is_expense': 1,
            'notes': 'AI Test: Gibberish name detection',
          });
          continue;
        }
      }

      final Map<String, dynamic> source = isExpense
          ? expenseSources[random.nextInt(expenseSources.length)]
          : incomeSources[random.nextInt(incomeSources.length)];

      final double baseAmount = source['base'] as double;
      final double varAmount = random
          .nextInt((source['var'] as int) + 1)
          .toDouble();

      await db.insertTransaction({
        'title': source['title'],
        'amount': isExpense
            ? -(baseAmount + varAmount)
            : (baseAmount + varAmount),
        'category': source['category'],
        'date': txDateTime.toIso8601String(),
        'notes': 'Demo: Randomized entry',
        'is_expense': isExpense ? 1 : 0,
        'created_at': txDateTime.toIso8601String(),
        if (source['category'] == 'EMI') ...{
          'interest_rate': 8.5,
          'due_date': now.add(const Duration(days: 12)).toIso8601String(),
          'last_payment_date': now
              .subtract(const Duration(days: 18))
              .toIso8601String(),
        },
      });
    }

    // -- Demo Subscriptions (Recurring Transactions) --
    await db.addRecurringTransaction(
      title: 'Netflix Premium',
      amount: -649.0,
      category: 'Entertainment',
      interval: 'monthly',
      startDate: now.subtract(const Duration(days: 5)),
      isExpense: true,
    );
    await db.addRecurringTransaction(
      title: 'Gym Membership',
      amount: -2000.0,
      category: 'Healthcare',
      interval: 'monthly',
      startDate: now.subtract(const Duration(days: 10)),
      isExpense: true,
    );
    await db.addRecurringTransaction(
      title: 'Cloud Storage',
      amount: -130.0,
      category: 'Bills',
      interval: 'monthly',
      startDate: now.subtract(const Duration(days: 2)),
      isExpense: true,
    );

    // -- Demo Budgets (this month & last month) --
    await db.setBudgetLimit('Food', 8000.0, thisMonth, thisYear);
    await db.setBudgetLimit('Transport', 3000.0, thisMonth, thisYear);
    await db.setBudgetLimit('Entertainment', 2000.0, thisMonth, thisYear);
    await db.setBudgetLimit('Shopping', 6000.0, thisMonth, thisYear);
    await db.setBudgetLimit('Bills', 5000.0, thisMonth, thisYear);
    await db.setOverallBudget(35000.0);
    // Last month budgets
    await db.setBudgetLimit('Food', 7500.0, lastMonth, lastMonthYear);
    await db.setBudgetLimit('Transport', 3000.0, lastMonth, lastMonthYear);
    await db.setBudgetLimit('Entertainment', 2500.0, lastMonth, lastMonthYear);
    await db.setBudgetLimit('Shopping', 6000.0, lastMonth, lastMonthYear);
    await db.setBudgetLimit('Bills', 5000.0, lastMonth, lastMonthYear);

    // -- Demo Savings Goals --
    final goalId = await db.addSavingsGoal('Dream Vacation', 100000.0, 0);
    await db.addFundsToGoal(goalId, 15000.0);
    await db.addSavingsGoal('Emergency Fund', 200000.0, 2);
    await db.addSavingsGoal('New Laptop', 80000.0, 4);

    // Reload all data
    await loadTransactions();
    await _loadBudgets();
    await _loadSavingsGoals();

    if (mounted) {
      _showMessage('🎉 Demo data added successfully!');
    }
  }

  Future<void> _handleLogout() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text('Logging out safely...'),
            SizedBox(height: 8),
            Text(
              'Your final changes are being uploaded to the cloud.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );

    try {
      // Add a safety timeout for the UI transition too
      await AuthService.instance.logout().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Logout error: $e');
    } finally {
      if (mounted) {
        Navigator.of(
          context,
          rootNavigator: true,
        ).pop(); // Close loading dialog
      }
    }
  }

  Future<void> loadTransactions() async {
    try {
      debugPrint('loadTransactions: Starting...');
      final data = await DatabaseHelper.instance.getTransactions();

      if (mounted) {
        setState(() {
          transactions = data;
          isLoading = false;
        });
        // Recalculate AI data in background
        _refreshAIData();
      }
      // Load savings goals too
      _loadSavingsGoals();
      // Schedule EMI reminders after loading transactions
      try {
        _scheduleEMIReminders();
      } catch (e) {
        debugPrint('Error scheduling EMI reminders: $e');
      }
      // Process recurring transactions
      try {
        final count = await DatabaseHelper.instance
            .processRecurringTransactions();
        if (count > 0) {
          debugPrint('Processed $count recurring transactions');
          // Reload if any were created
          final updatedData = await DatabaseHelper.instance.getTransactions();
          if (mounted) {
            setState(() {
              transactions = updatedData;
            });
          }
        }
      } catch (e) {
        debugPrint('Error processing recurring: $e');
      }
      // Load recurring templates
      _loadRecurringTemplates();
      debugPrint('loadTransactions: Complete with ${data.length} transactions');
    } catch (e, st) {
      debugPrint('loadTransactions error: $e');
      debugPrint('Stack: $st');
      if (mounted) {
        setState(() => isLoading = false);
        // Show recovery dialog for database errors
        if (e.toString().contains('duplicate column') ||
            e.toString().contains('database')) {
          _showDatabaseErrorDialog();
        } else {
          _showMessage('Error loading transactions: ${e.toString()}');
        }
      }
    }
  }

  Future<void> _refreshAIData() async {
    if (transactions.isEmpty) return;

    // Run AI analysis in background to keep UI smooth
    setState(() => _aiDataLoading = true);

    final ai = AIAnalystService.instance;
    final insights = ai.analyzeSpending(transactions);
    final allAnomalies = ai.detectAnomalies(transactions);
    final recommendations = ai.getMerchantSuggestions(transactions);
    final healthScore = ai.calculateFinancialHealthScore(
      transactions,
      allAnomalies,
    );
    final forecast = ai.getMonthlyForecast(transactions);
    final budgetSuggestions = ai.getBudgetSuggestions(transactions);

    if (mounted) {
      setState(() {
        _cachedInsights = insights;
        _cachedAnomalies = allAnomalies;
        _cachedSuggestions = recommendations;
        _cachedHealthScore = healthScore;
        _cachedForecast = forecast;
        _cachedBudgetSuggestions = budgetSuggestions;
        _aiDataLoading = false;
      });
    }
  }

  Future<void> _loadBudgets() async {
    final now = DateTime.now();
    try {
      debugPrint('_loadBudgets: Getting budgets for $now');
      final budgets = await DatabaseHelper.instance.getAllBudgets(
        now.month,
        now.year,
      );
      if (!mounted) return;
      setState(() {
        categoryBudgets = {
          for (final b in budgets)
            b['category'].toString(): (b['limit_amount'] as num).toDouble(),
        };
      });
      debugPrint('_loadBudgets: Loaded ${budgets.length} budgets');
    } catch (e, st) {
      debugPrint('_loadBudgets error: $e');
      debugPrint('Stack: $st');
      if (mounted) {
        _showMessage('Error loading budgets: $e');
      }
    }
  }

  Future<void> _setBudgetLimitForCategory(
    String category,
    double amount,
  ) async {
    final now = DateTime.now();
    try {
      await DatabaseHelper.instance.setBudgetLimit(
        category,
        amount,
        now.month,
        now.year,
      );
      await _loadBudgets();
      _showMessage('Budget updated for $category');

      // Check current spending and show notifications
      final spending = getCategorySpendingForMonth(now.month, now.year);
      final spent = spending[category] ?? 0;
      if (spent > 0) {
        _checkAndShowBudgetNotification(category, spent, amount);
      }
    } catch (e) {
      _showMessage('Failed to save budget: $e');
    }
  }

  void _checkAndShowBudgetNotification(
    String category,
    double spent,
    double limit,
  ) {
    if (limit <= 0) return;

    final percentage = (spent / limit) * 100;

    if (spent >= limit) {
      // Budget exceeded
      NotificationService().showBudgetExceededNotification(
        category: category,
        spent: spent,
        limit: limit,
      );
    } else if (percentage >= 80) {
      // Budget at 80% or higher
      NotificationService().showBudgetLowNotification(
        category: category,
        spent: spent,
        limit: limit,
        percentage: percentage,
      );
    }
  }

  void _checkBudgetsAfterTransaction() {
    if (!showBudgetWarnings) return;
    final now = DateTime.now();
    final spending = getCategorySpendingForMonth(now.month, now.year);

    // Check Overall Budget
    if (categoryBudgets.containsKey('OVERALL') &&
        categoryBudgets['OVERALL']! > 0) {
      final monthlyStats = getMonthlyStats(now.month, now.year);
      final totalExpense = monthlyStats['expense'] as double;
      _checkAndShowBudgetNotification(
        'OVERALL',
        totalExpense,
        categoryBudgets['OVERALL']!,
      );
    }

    // Check Individual Categories
    for (final entry in categoryBudgets.entries) {
      if (entry.key == 'OVERALL') continue;
      final limit = entry.value;
      if (limit > 0) {
        final spent = spending[entry.key] ?? 0;
        if (spent > 0) {
          _checkAndShowBudgetNotification(entry.key, spent, limit);
        }
      }
    }
  }

  void _checkAnomaliesAfterTransaction(int txId) {
    final ai = AIAnalystService.instance;
    final allAnomalies = ai.detectAnomalies(transactions);

    for (final flag in allAnomalies) {
      if (flag.transaction != null && flag.transaction!['id'] == txId) {
        NotificationService().showAnomalyNotification(
          title: flag.title,
          body: flag.description,
          isAlert: flag.severity == AnomalySeverity.alert,
        );
        break;
      }
    }
  }

  void _scheduleEMIReminders() {
    final emiTransactions = transactions
        .where((t) => (t['category'] ?? '').toString() == 'EMI')
        .toList();

    for (final emi in emiTransactions) {
      try {
        final dueDate =
            emi['due_date'] != null && (emi['due_date'] as String).isNotEmpty
            ? DateTime.parse(emi['due_date'])
            : null;

        if (dueDate != null && dueDate.isAfter(DateTime.now())) {
          final amount = _safeAmount(emi['amount']).abs();
          final title = emi['title'] ?? 'EMI';

          // Schedule reminder X days before
          NotificationService().scheduleEMIReminder(
            emiTitle: title,
            dueDate: dueDate,
            amount: amount,
            daysBeforeReminder: emiReminderDays,
          );

          // Schedule due date notification
          NotificationService().scheduleEMIDueNotification(
            emiTitle: title,
            dueDate: dueDate,
            amount: amount,
          );
        }
      } catch (e) {
        debugPrint('Error scheduling EMI reminder: $e');
      }
    }
  }

  void _showDatabaseErrorDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Database Error'),
        content: const Text(
          'There was an error with your local database. Would you like to reset it? Your data will be cleared.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await DatabaseHelper.instance.clearDatabase();
              if (mounted) {
                setState(() => isLoading = true);
                await loadTransactions();
              }
            },
            child: const Text(
              'Reset Database',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadCategories() async {
    try {
      debugPrint('_loadCategories: Starting...');
      final income = await DatabaseHelper.instance.getCategories('income');
      final expense = await DatabaseHelper.instance.getCategories('expense');
      debugPrint(
        '_loadCategories: Got ${income.length} income and ${expense.length} expense categories',
      );
      if (mounted) {
        setState(() {
          incomeCategories = income;
          expenseCategories = expense;
          if (selectedCategory == 'General') {
            selectedCategory = isExpense
                ? (expenseCategories.isNotEmpty
                      ? expenseCategories.first
                      : 'General')
                : (incomeCategories.isNotEmpty
                      ? incomeCategories.first
                      : 'Salary');
          }
        });
      }
    } catch (e, st) {
      debugPrint('_loadCategories error: $e');
      debugPrint('Stack: $st');
      if (mounted) {
        _showMessage('Error loading categories: $e');
      }
    }
  }

  Future<void> _loadSavingsGoals() async {
    try {
      debugPrint('_loadSavingsGoals: Starting...');
      final goals = await DatabaseHelper.instance.getSavingsGoals();
      if (mounted) {
        setState(() {
          savingsGoals = goals;
          debugPrint('_loadSavingsGoals: Loaded ${goals.length} goals');
        });
      }
    } catch (e, st) {
      debugPrint('_loadSavingsGoals error: $e');
      debugPrint('Stack: $st');
    }
  }

  Future<void> _loadRecurringTemplates() async {
    try {
      final templates = await DatabaseHelper.instance
          .getRecurringTransactions();
      if (mounted) {
        setState(() {
          recurringTransactions = templates;
        });
      }
    } catch (e) {
      debugPrint('Error loading recurring templates: $e');
    }
  }

  Future<void> _loadUserProfile({bool forceReload = false}) async {
    if (_profileLoaded && !forceReload) return;
    try {
      final profile = await DatabaseHelper.instance.getUserProfile();
      if (mounted) {
        setState(() {
          if (profile != null) _userProfile = profile;
          _profileLoaded = true;
        });
      }
    } catch (e) {
      debugPrint('Error loading user profile: $e');
    }
  }

  Future<void> _addCategory(String categoryName) async {
    try {
      if (categoryName.trim().isEmpty) {
        _showMessage('Category name cannot be empty');
        return;
      }

      final type = isExpense ? 'expense' : 'income';
      await DatabaseHelper.instance.addCategory(categoryName.trim(), type);
      await _loadCategories();
      if (mounted) {
        _showMessage('Category added successfully');
      }
    } catch (e) {
      _showMessage(e.toString());
    }
  }

  Future<void> _deleteCategory(String categoryName) async {
    try {
      await DatabaseHelper.instance.deleteCategory(categoryName);
      await _loadCategories();
      if (mounted) {
        setState(() {
          if (selectedCategory == categoryName) {
            selectedCategory = isExpense
                ? expenseCategories.first
                : incomeCategories.first;
          }
        });
        _showMessage('Category deleted successfully');
      }
    } catch (e) {
      _showMessage(e.toString());
    }
  }

  Future<bool> addTransaction() async {
    try {
      final title = titleController.text.trim();
      final amountValue = double.tryParse(amountController.text.trim());

      if (title.isEmpty || amountValue == null || amountValue <= 0) {
        _showMessage('Please enter a valid title and amount.');
        return false;
      }

      final signedAmount = isExpense ? -amountValue : amountValue;

      final transactionData = {
        'title': title,
        'amount': signedAmount.toStringAsFixed(2),
        'date': selectedDate.toString().split(' ')[0],
        'category': selectedCategory,
      };

      // Add EMI specific fields if category is EMI
      if (selectedCategory == 'EMI') {
        transactionData['interest_rate'] = emiInterestRate.toString();
        transactionData['due_date'] = emiDueDate != null
            ? emiDueDate.toString().split(' ')[0]
            : '';
        transactionData['last_payment_date'] = emiLastPaymentDate != null
            ? emiLastPaymentDate.toString().split(' ')[0]
            : '';
      }

      final newId = await DatabaseHelper.instance.insertTransaction(
        transactionData,
      );

      titleController.clear();
      amountController.clear();
      selectedDate = DateTime.now();
      selectedCategory = 'General';
      isRecurring = false;
      selectedInterval = 'monthly';

      await loadTransactions();
      _checkBudgetsAfterTransaction();
      _checkAnomaliesAfterTransaction(newId);
      _showActionNotification(
        'Transaction added successfully',
        icon: Icons.check_circle_outline,
        color: const Color(0xFF2D9CDB), // Harmonious Blue/Teal
      );
      return true;
    } catch (e) {
      _showActionNotification(
        'Error adding: ${e.toString()}',
        icon: Icons.error_outline,
        color: Colors.red.shade400,
      );
      return false;
    }
  }

  Future<bool> updateTransaction(Map<String, dynamic> transaction) async {
    try {
      final title = titleController.text.trim();
      final amountValue = double.tryParse(amountController.text.trim());

      if (title.isEmpty || amountValue == null || amountValue <= 0) {
        _showMessage('Please enter a valid title and amount.');
        return false;
      }

      final signedAmount = isExpense ? -amountValue : amountValue;

      final updateData = {
        'id': transaction['id'],
        'title': title,
        'amount': signedAmount.toStringAsFixed(2),
        'date': selectedDate.toString().split(' ')[0],
        'category': selectedCategory,
      };

      // Add EMI specific fields if category is EMI
      if (selectedCategory == 'EMI') {
        updateData['interest_rate'] = emiInterestRate.toString();
        updateData['due_date'] = emiDueDate != null
            ? emiDueDate.toString().split(' ')[0]
            : '';
        updateData['last_payment_date'] = emiLastPaymentDate != null
            ? emiLastPaymentDate.toString().split(' ')[0]
            : '';
      }

      await DatabaseHelper.instance.updateTransaction(updateData);

      titleController.clear();
      amountController.clear();
      selectedDate = DateTime.now();
      selectedCategory = 'General';
      await loadTransactions();
      _checkBudgetsAfterTransaction();
      _checkAnomaliesAfterTransaction(updateData['id'] as int);
      _showActionNotification(
        'Transaction updated',
        icon: Icons.edit_outlined,
        color: const Color(0xFFF2994A), // Harmonious Orange/Peach
      );
      return true;
    } catch (e) {
      _showActionNotification(
        'Error updating: ${e.toString()}',
        icon: Icons.error_outline,
        color: const Color(0xFFEB5757), // Harmonious Soft Red/Coral
      );
      return false;
    }
  }

  Future<void> deleteTransaction(int id) async {
    try {
      final t = transactions.firstWhere((tx) => tx['id'] == id);
      if (!_canDelete(t)) {
        _showActionNotification(
          'Transactions older than 12 hours are locked 🔒',
          icon: Icons.lock_outline,
          color: const Color(0xFF4F4F4F),
        );
        return;
      }
      await DatabaseHelper.instance.deleteTransaction(id);
      await loadTransactions();
      _showActionNotification(
        'Transaction deleted',
        icon: Icons.delete_outline,
        color: const Color(0xFFEB5757), // Harmonious Soft Red/Coral
      );
    } catch (e) {
      _showActionNotification(
        'Error deleting: ${e.toString()}',
        icon: Icons.error_outline,
        color: const Color(0xFFF2994A), // Harmonious Orange/Peach
      );
    }
  }

  void openAddDialog() {
    titleController.clear();
    amountController.clear();
    emiMonthsController.clear();
    emiInterestRateController.clear();
    isExpense = true;
    selectedDate = DateTime.now();
    selectedCategory = currentTabIndex == 2 ? 'EMI' : 'General';
    isEMI = false;
    emiStartDate = null;
    emiMonths = 1;
    emiDueDate = null;
    emiLastPaymentDate = null;
    emiInterestRate = 0.0;
    isRecurring = false;
    selectedInterval = 'monthly';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _buildTransactionSheet(
        title: 'Add Transaction',
        buttonText: 'Save',
        onSubmit: addTransaction,
      ),
    );
  }

  void openEditDialog(Map<String, dynamic> transaction) {
    if (!_canDelete(transaction)) {
      _showActionNotification(
        'Cannot edit – transactions older than 12 hours are locked 🔒',
        icon: Icons.lock_outline,
        color: const Color(0xFF4F4F4F),
      );
      return;
    }
    final existingAmount = _safeAmount(transaction['amount']);
    titleController.text = (transaction['title'] ?? '').toString();
    amountController.text = existingAmount.abs().toStringAsFixed(2);
    isExpense = existingAmount < 0;
    selectedDate = DateTime.parse(
      transaction['date'] ?? DateTime.now().toString(),
    );
    selectedCategory = transaction['category'] ?? 'General';
    isEMI = false;
    emiStartDate = null;
    emiMonthsController.clear();
    emiMonths = 1;
    emiDueDate = null;
    emiLastPaymentDate = null;
    emiInterestRateController.clear();
    emiInterestRate = 0.0;

    // Load EMI specific fields if category is EMI
    if (selectedCategory == 'EMI') {
      emiInterestRate =
          double.tryParse(transaction['interest_rate'] ?? '0') ?? 0.0;
      emiInterestRateController.text = emiInterestRate.toString();
      if (transaction['due_date'] != null &&
          transaction['due_date'].toString().isNotEmpty) {
        emiDueDate = DateTime.tryParse(transaction['due_date']);
      }
      if (transaction['last_payment_date'] != null &&
          transaction['last_payment_date'].toString().isNotEmpty) {
        emiLastPaymentDate = DateTime.tryParse(
          transaction['last_payment_date'],
        );
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _buildTransactionSheet(
        title: 'Edit Transaction',
        buttonText: 'Update',
        onSubmit: () async => updateTransaction(transaction),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Shows a harmonious top notification banner.
  void _showActionNotification(
    String message, {
    IconData icon = Icons.info_outline,
    Color color = const Color(0xFF6366F1),
  }) {
    if (!mounted) return;

    _notificationTimer?.cancel();

    setState(() {
      _notificationMessage = message;
      _notificationIcon = icon;
      _notificationColor = color;
      _isNotificationVisible = true;
      _isNotificationExpanded = false; // Reset expansion on new message
    });

    _notificationTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _isNotificationVisible = false;
        });
      }
    });
  }

  Widget _buildTopNotification() {
    final mq = MediaQuery.of(context);
    final topPadding = mq.padding.top + 8;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutQuint,
      top: _isNotificationVisible ? topPadding : -120,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _isNotificationExpanded = !_isNotificationExpanded;
            });
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: (_notificationColor ?? const Color(0xFF6366F1))
                      .withOpacity(0.85),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Row(
                  crossAxisAlignment: _isNotificationExpanded
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    Container(
                      margin: _isNotificationExpanded
                          ? const EdgeInsets.only(top: 4)
                          : null,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _notificationIcon ?? Icons.info_outline,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _notificationMessage ?? '',
                            maxLines: _isNotificationExpanded ? 10 : 1,
                            overflow: _isNotificationExpanded
                                ? TextOverflow.visible
                                : TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              letterSpacing: 0.1,
                            ),
                          ),
                          if (!_isNotificationExpanded &&
                              (_notificationMessage?.length ?? 0) > 30)
                            Text(
                              'Tap to read more...',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white.withOpacity(0.7),
                                height: 1.5,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () =>
                              setState(() => _isNotificationVisible = false),
                          child: Icon(
                            Icons.close,
                            color: Colors.white.withOpacity(0.7),
                            size: 18,
                          ),
                        ),
                        if (_isNotificationExpanded) ...[
                          const SizedBox(height: 8),
                          Icon(
                            Icons.expand_less,
                            color: Colors.white.withOpacity(0.7),
                            size: 18,
                          ),
                        ] else if ((_notificationMessage?.length ?? 0) >
                            30) ...[
                          const SizedBox(height: 2),
                          Icon(
                            Icons.expand_more,
                            color: Colors.white.withOpacity(0.7),
                            size: 18,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showManageSubscriptionsDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Container(
              padding: const EdgeInsets.all(20),
              height: MediaQuery.of(context).size.height * 0.7,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Recurring Transactions',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.add_circle,
                          color: Color(0xFF6366F1),
                          size: 28,
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showAddSubscriptionSheet();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'These are templates that automatically create transactions.',
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: recurringTransactions.isEmpty
                        ? const Center(
                            child: Text(
                              'No recurring transactions set up yet.',
                            ),
                          )
                        : ListView.builder(
                            itemCount: recurringTransactions.length,
                            itemBuilder: (context, index) {
                              final rt = recurringTransactions[index];
                              return Card(
                                child: ListTile(
                                  leading: const CircleAvatar(
                                    child: Icon(Icons.repeat),
                                  ),
                                  title: Text(rt['title'] ?? 'Recurring'),
                                  subtitle: Text(
                                    '${rt['interval']} • Next: ${formatDate(rt['next_due_date'])}${rt['end_date'] != null ? '\nEnds: ${formatDate(rt['end_date'])}' : ''}',
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(
                                      Icons.delete,
                                      color: Colors.red,
                                    ),
                                    onPressed: () async {
                                      await DatabaseHelper.instance
                                          .deleteRecurringTransaction(
                                            rt['id'] as int,
                                          );
                                      final updated = await DatabaseHelper
                                          .instance
                                          .getRecurringTransactions();
                                      setDialogState(() {
                                        recurringTransactions = updated;
                                      });
                                      setState(() {
                                        recurringTransactions = updated;
                                      });
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showAddSubscriptionSheet() {
    titleController.clear();
    amountController.clear();
    selectedDate = DateTime.now();
    selectedCategory = 'Bills';
    selectedInterval = 'monthly';
    durationMonths = 12;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 24,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Add New Subscription',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: titleController,
                      decoration: InputDecoration(
                        labelText: 'Subscription Title',
                        prefixIcon: const Icon(Icons.label),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Amount',
                        prefixIcon: const Icon(Icons.currency_rupee),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text(
                          'Interval:',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButton<String>(
                            value: selectedInterval,
                            isExpanded: true,
                            style: TextStyle(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black87,
                              fontSize: 16,
                            ),
                            items: ['daily', 'weekly', 'monthly', 'yearly']
                                .map(
                                  (i) => DropdownMenuItem(
                                    value: i,
                                    child: Text(i.toUpperCase()),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null)
                                setModalState(() => selectedInterval = val);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text(
                          'Duration (Months):',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButton<int>(
                            value: durationMonths,
                            isExpanded: true,
                            items: [1, 3, 6, 12, 24, 36]
                                .map(
                                  (m) => DropdownMenuItem(
                                    value: m,
                                    child: Text('$m Months'),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null)
                                setModalState(() => durationMonths = val);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () async {
                          final title = titleController.text.trim();
                          final amount =
                              double.tryParse(amountController.text.trim()) ??
                              0.0;

                          if (title.isEmpty || amount <= 0) {
                            _showMessage('Please enter valid title and amount');
                            return;
                          }

                          await DatabaseHelper.instance.addRecurringTransaction(
                            title: title,
                            amount: -amount,
                            category: selectedCategory,
                            interval: selectedInterval,
                            startDate: DateTime.now(),
                            durationMonths: durationMonths,
                            isExpense: true,
                          );

                          await _loadRecurringTemplates();
                          if (mounted) Navigator.pop(ctx);
                          _showManageSubscriptionsDialog();
                        },
                        child: const Text('Save Subscription'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  bool _isDefaultCategory(String categoryName) {
    // List of default categories that come with the app
    final defaultExpenseCategories = [
      'General',
      'Food',
      'Transport',
      'Entertainment',
      'Shopping',
      'Bills',
      'Healthcare',
      'Education',
      'EMI',
      'Other',
    ];
    final defaultIncomeCategories = [
      'Salary',
      'Bonus',
      'Investment Returns',
      'Freelance',
      'Rental Income',
      'Gift',
      'Other',
    ];

    final defaultCategories = [
      ...defaultExpenseCategories,
      ...defaultIncomeCategories,
    ];
    return defaultCategories.contains(categoryName);
  }

  double _safeAmount(dynamic value) {
    return double.tryParse((value ?? '0').toString()) ?? 0;
  }

  double getTotalBalance() {
    double total = 0;
    for (final t in transactions) {
      total += _safeAmount(t['amount']);
    }
    return total;
  }

  double getIncomeTotal() {
    double total = 0;
    for (final t in transactions) {
      final amount = _safeAmount(t['amount']);
      if (amount > 0) {
        total += amount;
      }
    }
    return total;
  }

  double getExpenseTotal() {
    double total = 0;
    for (final t in transactions) {
      final amount = _safeAmount(t['amount']);
      if (amount < 0) {
        total += amount.abs();
      }
    }
    return total;
  }

  List<Map<String, dynamic>> get filteredTransactions {
    final query = searchController.text.trim().toLowerCase();

    return transactions.where((t) {
      final title = (t['title'] ?? '').toString().toLowerCase();
      final amount = _safeAmount(t['amount']);

      final matchesSearch = query.isEmpty || title.contains(query);
      final matchesFilter = switch (selectedFilter) {
        TransactionFilter.all => true,
        TransactionFilter.income => amount > 0,
        TransactionFilter.expense => amount < 0,
      };

      return matchesSearch && matchesFilter;
    }).toList();
  }

  String formatMoney(double amount) {
    return '$_currencySymbol${amount.toStringAsFixed(2)}';
  }

  Map<String, double> getCategoryTotals() {
    final Map<String, double> categoryTotals = {};
    for (final t in transactions) {
      if (insightsDateRange != null && currentTabIndex == 1) {
        final dStr = t['date']?.toString();
        if (dStr == null) continue;
        final d = DateTime.tryParse(dStr);
        if (d == null) continue;
        final day = DateTime(d.year, d.month, d.day);
        final start = DateTime(
          insightsDateRange!.start.year,
          insightsDateRange!.start.month,
          insightsDateRange!.start.day,
        );
        final end = DateTime(
          insightsDateRange!.end.year,
          insightsDateRange!.end.month,
          insightsDateRange!.end.day,
        );
        if (day.isBefore(start) || day.isAfter(end)) continue;
      }
      final amount = _safeAmount(t['amount']);
      final category = t['category'] ?? 'General';
      categoryTotals[category] = (categoryTotals[category] ?? 0) + amount;
    }
    return categoryTotals;
  }

  Map<String, dynamic> getMonthlyStats(int month, int year) {
    double income = 0;
    double expense = 0;
    int transactionCount = 0;

    final Iterable<Map<String, dynamic>> sourceTxs;
    if (insightsDateRange != null && currentTabIndex == 1) {
      // In Insights tab with a date range selected, filter by that range instead of month/year
      sourceTxs = transactions.where((t) {
        final dStr = t['date']?.toString();
        if (dStr == null) return false;
        final d = DateTime.tryParse(dStr);
        if (d == null) return false;
        final day = DateTime(d.year, d.month, d.day);
        final start = DateTime(
          insightsDateRange!.start.year,
          insightsDateRange!.start.month,
          insightsDateRange!.start.day,
        );
        final end = DateTime(
          insightsDateRange!.end.year,
          insightsDateRange!.end.month,
          insightsDateRange!.end.day,
        );
        return !day.isBefore(start) && !day.isAfter(end);
      });
    } else {
      sourceTxs = transactions.where((t) {
        final d = DateTime.tryParse(t['date'] ?? '2000-01-01');
        return d != null && d.month == month && d.year == year;
      });
    }

    for (final t in sourceTxs) {
      final amount = _safeAmount(t['amount']);
      if (amount > 0) {
        income += amount;
      } else {
        expense += amount.abs();
      }
      transactionCount++;
    }

    return {
      'income': income,
      'expense': expense,
      'balance': income - expense,
      'count': transactionCount,
    };
  }

  // Analytics: Get highest spending category
  String getHighestSpendingCategory() {
    final now = DateTime.now();
    final categoryTotals = insightsDateRange != null && currentTabIndex == 1
        ? _getFilteredCategorySpending(insightsDateRange!)
        : getCategorySpendingForMonth(now.month, now.year);
    if (categoryTotals.isEmpty) return 'N/A';
    return categoryTotals.entries
        .reduce((a, b) => a.value > b.value ? a : b)
        .key;
  }

  Map<String, double> _getFilteredCategorySpending(DateTimeRange range) {
    final Map<String, double> expenses = {};
    for (final t in transactions) {
      final dStr = t['date']?.toString();
      if (dStr == null) continue;
      final d = DateTime.tryParse(dStr);
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      final start = DateTime(
        range.start.year,
        range.start.month,
        range.start.day,
      );
      final end = DateTime(range.end.year, range.end.month, range.end.day);
      if (!day.isBefore(start) && !day.isAfter(end)) {
        final amt = _safeAmount(t['amount']);
        if (amt < 0) {
          final cat = t['category'] ?? 'General';
          expenses[cat] = (expenses[cat] ?? 0) + amt.abs();
        }
      }
    }
    return expenses;
  }

  // Analytics: Get average daily expense
  double getAverageDailyExpense() {
    final now = DateTime.now();
    final monthlyStats = getMonthlyStats(now.month, now.year);
    if (insightsDateRange != null && currentTabIndex == 1) {
      final diff =
          insightsDateRange!.end.difference(insightsDateRange!.start).inDays +
          1;
      if (diff <= 0) return 0;
      return (monthlyStats['expense'] as double) / diff;
    }
    final elapsedDays = now.day;
    if (elapsedDays == 0) return 0;
    return (monthlyStats['expense'] as double) / elapsedDays;
  }

  // Analytics: Calculate Financial Score (0-100)
  int calculateFinancialScore() {
    final now = DateTime.now();
    final stats = getMonthlyStats(now.month, now.year);
    double income = stats['income'] ?? 0;
    double expense = stats['expense'] ?? 0;
    double savingsRate = income > 0 ? (income - expense) / income : 0;
    int score = 0;

    // 1. Savings Rate (Max 40 points)
    // >20% savings = 40 pts. <0% savings = 0 pts.
    if (savingsRate >= 0.20) {
      score += 40;
    } else if (savingsRate > 0) {
      score += (savingsRate / 0.20 * 40).toInt();
    }

    // 2. Budget Adherence (Max 30 points)
    int budgetPoints = 30;
    final spending = getCategorySpendingForMonth(now.month, now.year);
    for (final entry in categoryBudgets.entries) {
      final category = entry.key;
      final limit = entry.value;
      if (limit <= 0) continue;

      final spent = category == 'OVERALL' ? expense : (spending[category] ?? 0);
      final usage = spent / limit;

      if (usage > 1.0) {
        budgetPoints -= 15; // Heavy penalty for exceeding
      } else if (usage >= 0.8) {
        budgetPoints -= 5; // Slight penalty for nearing limit
      }
    }
    score += budgetPoints.clamp(0, 30);

    // 3. Consistency (Max 30 points)
    int safeDays = 0;
    final dailyLimit = getAverageDailyExpense();
    if (dailyLimit > 0) {
      for (int i = 1; i <= now.day; i++) {
        double dayExpense = 0;
        final dateToCheck = DateTime(now.year, now.month, i);
        for (final t in transactions) {
          final tDate = DateTime.tryParse(t['date'] ?? '') ?? DateTime(2000);
          if (tDate.year == dateToCheck.year &&
              tDate.month == dateToCheck.month &&
              tDate.day == dateToCheck.day) {
            final amt = _safeAmount(t['amount']);
            if (amt < 0) dayExpense += amt.abs();
          }
        }
        if (dayExpense <= dailyLimit) {
          safeDays++;
        }
      }
      double consistencyRatio = now.day > 0 ? safeDays / now.day : 0;
      score += (consistencyRatio * 30).toInt();
    } else {
      score += 30; // No expenses yet, perfect consistency
    }

    return score.clamp(0, 100);
  }

  // Analytics: Get category spending for current month
  Map<String, double> getCategorySpendingForMonth(int month, int year) {
    final Map<String, double> categorySpending = {};
    for (final t in transactions) {
      try {
        final date = DateTime.parse(t['date'] ?? '2000-01-01');
        if (date.month == month && date.year == year) {
          final amount = _safeAmount(t['amount']);
          if (amount < 0) {
            final category = t['category'] ?? 'General';
            categorySpending[category] =
                (categorySpending[category] ?? 0) + amount.abs();
          }
        }
      } catch (e) {
        continue;
      }
    }
    return categorySpending;
  }

  // Analytics: Get pie chart data for categories
  List<PieChartSectionData> getPieChartData() {
    final now = DateTime.now();
    final categorySpending = insightsDateRange != null && currentTabIndex == 1
        ? _getFilteredCategorySpending(insightsDateRange!)
        : getCategorySpendingForMonth(now.month, now.year);
    if (categorySpending.isEmpty) return [];

    final colors = [
      const Color(0xFF6366F1), // Indigo
      const Color(0xFFF43F5E), // Rose
      const Color(0xFF10B981), // Emerald
      const Color(0xFFF59E0B), // Amber
      const Color(0xFF8B5CF6), // Violet
      const Color(0xFFEC4899), // Pink
      const Color(0xFF06B6D4), // Cyan
      const Color(0xFF84CC16), // Lime
    ];

    int colorIndex = 0;
    return categorySpending.entries.map((entry) {
      final baseColor = colors[colorIndex % colors.length];
      final section = PieChartSectionData(
        value: entry.value,
        title: entry.key,
        color: baseColor,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [baseColor.withOpacity(0.85), baseColor],
        ),
        radius: 85,
        showTitle: true,
        titleStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          shadows: [Shadow(color: Colors.black26, blurRadius: 4)],
        ),
      );
      colorIndex++;
      return section;
    }).toList();
  }

  // Analytics: Get monthly spending data for bar chart
  List<BarChartGroupData> getMonthlySpendingData() {
    final now = DateTime.now();
    final List<BarChartGroupData> data = [];

    for (int i = 5; i >= 0; i--) {
      final date = DateTime(now.year, now.month - i, 1);
      final stats = getMonthlyStats(date.month, date.year);
      final income = stats['income'] as double;
      final expense = stats['expense'] as double;

      data.add(
        BarChartGroupData(
          x: 5 - i,
          barRods: [
            BarChartRodData(
              toY: income > 0 ? income : 0,
              gradient: const LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xFF10B981), Color(0xFF34D399)],
              ),
              width: 10,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(6),
              ),
            ),
            BarChartRodData(
              toY: expense > 0 ? expense : 0,
              gradient: const LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xFFEF4444), Color(0xFFF87171)],
              ),
              width: 10,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(6),
              ),
            ),
          ],
        ),
      );
    }

    return data;
  }

  List<String> getMonthlyLabels() {
    const names = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final now = DateTime.now();
    return List.generate(6, (index) {
      final date = DateTime(now.year, now.month - (5 - index), 1);
      return names[date.month - 1];
    });
  }

  List<BudgetAlert> getBudgetAlerts() {
    final now = DateTime.now();
    final spending = getCategorySpendingForMonth(now.month, now.year);
    final monthlyStats = getMonthlyStats(now.month, now.year);
    final totalExpense = (monthlyStats['expense'] as num).toDouble();
    final alerts = <BudgetAlert>[];

    for (final entry in categoryBudgets.entries) {
      final spent = entry.key == 'OVERALL'
          ? totalExpense
          : (spending[entry.key] ?? 0);
      final limit = entry.value;
      if (limit <= 0) continue;
      final usage = spent / limit;
      if (usage >= 0.8) {
        alerts.add(
          BudgetAlert(
            category: entry.key,
            spent: spent,
            limit: limit,
            usage: usage,
          ),
        );
      }
    }

    alerts.sort((a, b) => b.usage.compareTo(a.usage));
    return alerts;
  }

  String formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return '${date.day}/${date.month}/${date.year}';
    } catch (e) {
      return 'N/A';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const _MoneyLoadingScreen();

    final titles = ['Home', 'Insights', 'Budget', 'AI Analyst', 'Settings'];
    return Stack(
      children: [
        Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            title: Text(
              titles[currentTabIndex],
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            centerTitle: false,
            elevation: 0,
            actions: [
              IconButton(
                icon: const Icon(Icons.home_outlined),
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const intro_screen.IntroScreen(),
                    ),
                  );
                },
                tooltip: 'Back to Intro',
              ),
              IconButton(
                icon: Icon(
                  Theme.of(context).brightness == Brightness.dark
                      ? Icons.light_mode
                      : Icons.dark_mode,
                ),
                onPressed: widget.onToggleTheme,
                tooltip: 'Toggle Theme',
              ),
            ],
          ),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
          floatingActionButton:
              (currentTabIndex == 1 ||
                  currentTabIndex == 3 ||
                  currentTabIndex == 4)
              ? null
              : FloatingActionButton(
                  onPressed: openAddDialog,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: const Icon(Icons.add, color: Colors.white),
                ),
          drawer: _buildDrawer(),
          body: ClipRect(
            child: IndexedStack(
              index: currentTabIndex,
              children: [
                _buildTransactionsTab(),
                _buildAnalyticsTab(),
                _buildBudgetTab(),
                _buildAIAnalystTab(),
                _buildSettingsTab(),
              ],
            ),
          ),
        ),
        _buildTopNotification(),
      ],
    );
  }

  Widget _buildDrawer() {
    final score = calculateFinancialScore();
    Color scoreColor;
    if (score >= 80)
      scoreColor = Colors.green;
    else if (score >= 50)
      scoreColor = Colors.orange;
    else
      scoreColor = Colors.red;

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                CircleAvatar(
                  backgroundColor: Colors.white,
                  radius: 24,
                  child: Icon(
                    Icons.person,
                    size: 32,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  AuthService.instance.currentUserDisplayName ?? 'User',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  AuthService.instance.currentUserEmail ?? 'Offline User',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.health_and_safety,
                        color: scoreColor,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Financial Score: $score',
                        style: TextStyle(
                          color: scoreColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Home'),
            selected: currentTabIndex == 0,
            onTap: () {
              setState(() => currentTabIndex = 0);
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const Text('Insights'),
            selected: currentTabIndex == 1,
            onTap: () {
              setState(() => currentTabIndex = 1);
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.pie_chart_outline),
            title: const Text('Budget'),
            selected: currentTabIndex == 2,
            onTap: () {
              setState(() => currentTabIndex = 2);
              Navigator.pop(context);
            },
          ),
          const Divider(),
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.auto_awesome,
                color: Colors.white,
                size: 16,
              ),
            ),
            title: const Text('AI Analyst'),
            subtitle: const Text(
              'Insights & Alerts',
              style: TextStyle(fontSize: 11),
            ),
            selected: currentTabIndex == 3,
            onTap: () {
              setState(() => currentTabIndex = 3);
              Navigator.pop(context);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            selected: currentTabIndex == 4,
            onTap: () {
              setState(() => currentTabIndex = 4);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTab() {
    final avatarColors = [
      const Color(0xFF6366F1),
      const Color(0xFF8B5CF6),
      const Color(0xFFEC4899),
      const Color(0xFF14B8A6),
      const Color(0xFFF59E0B),
      const Color(0xFF10B981),
    ];
    final colorIdx = (_userProfile['avatar_color_index'] as int?) ?? 0;
    final avatarColor = avatarColors[colorIdx % avatarColors.length];
    final displayName = (_userProfile['name'] as String?)?.isNotEmpty == true
        ? _userProfile['name'] as String
        : (AuthService.instance.currentUserDisplayName ?? 'User');
    final email = AuthService.instance.currentUserEmail ?? 'Offline User';
    final dob = (_userProfile['dob'] as String?) ?? '';
    final phone = (_userProfile['phone'] as String?) ?? '';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        // ── Rich Profile Card ──
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 36,
                      backgroundColor: avatarColor,
                      child: Text(
                        displayName.isNotEmpty
                            ? displayName[0].toUpperCase()
                            : 'U',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            email,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (dob.isNotEmpty || phone.isNotEmpty) ...[
                  const Divider(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (dob.isNotEmpty) _infoChip(Icons.cake_outlined, dob),
                      if (phone.isNotEmpty)
                        _infoChip(Icons.phone_outlined, phone),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _openEditProfileSheet(),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit Profile'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.currency_exchange),
            title: const Text('Currency Symbol'),
            subtitle: Text('Currently: $_currencySymbol'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showCurrencyPicker(),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'EMI Reminder Days',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  'Get reminded $emiReminderDays days before EMI due date',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Slider(
                  value: emiReminderDays.toDouble(),
                  min: 1,
                  max: 7,
                  divisions: 6,
                  label: '$emiReminderDays days',
                  onChanged: (value) {
                    setState(() {
                      emiReminderDays = value.toInt();
                    });
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Export to CSV'),
            subtitle: const Text('Download all transactions'),
            onTap: () => _exportToCSV(),
          ),
        ),

        const SizedBox(height: 12),
        // Biometric Lock Setting
        FutureBuilder<String>(
          future: BiometricService.instance.getBiometricTypeLabel(),
          builder: (context, typeSnapshot) {
            final typeLabel = typeSnapshot.data ?? 'Biometric';
            return FutureBuilder<bool>(
              future: BiometricService.instance.isLockEnabled(),
              builder: (context, snapshot) {
                final isEnabled = snapshot.data ?? false;
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.fingerprint),
                    title: const Text('Biometric Lock'),
                    subtitle: Text('Use $typeLabel to open app'),
                    trailing: Switch(
                      value: isEnabled,
                      onChanged: (value) async {
                        if (value) {
                          // Verify they CAN use biometrics before enabling
                          final available = await BiometricService
                              .instance
                              .isBiometricAvailable;
                          if (!available) {
                            _showActionNotification(
                              'Biometrics not available on this device',
                              icon: Icons.error_outline,
                              color: const Color(0xFFEB5757),
                            );
                            return;
                          }

                          // Authenticate once to confirm setup
                          final authenticated = await BiometricService.instance
                              .authenticate();
                          if (!authenticated) return;
                        }

                        await BiometricService.instance.setLockEnabled(value);
                        setState(() {});
                        _showActionNotification(
                          value
                              ? 'Biometric Lock enabled'
                              : 'Biometric Lock disabled',
                          icon: value ? Icons.lock : Icons.lock_open,
                          color: value
                              ? const Color(0xFF2D9CDB)
                              : const Color(0xFFF2994A),
                        );
                      },
                    ),
                  ),
                );
              },
            );
          },
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _addDemoData,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Add Demo Data'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigo.shade50,
            foregroundColor: Colors.indigo.shade700,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _handleLogout,
          icon: const Icon(Icons.logout),
          label: const Text('Logout'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade50,
            foregroundColor: Colors.red.shade700,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: () async {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Wipe All Data?'),
                content: const Text(
                  'This will permanently delete all transactions, budgets, and savings goals. This cannot be undone.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text(
                      'Wipe Everything',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            );
            if (confirm == true) {
              await DatabaseHelper.instance.clearDatabase();
              await loadTransactions();
              _showMessage('Database wiped clean');
            }
          },
          icon: const Icon(Icons.delete_forever),
          label: const Text('Wipe All Data'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange.shade50,
            foregroundColor: Colors.orange.shade900,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildEMITab() {
    final emiTransactions = transactions
        .where((t) => (t['category'] ?? '').toString() == 'EMI')
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Active EMIs',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          if (emiTransactions.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Text(
                  'No EMIs added yet',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ),
            )
          else
            ...emiTransactions.map((transaction) {
              final amount = _safeAmount(transaction['amount']).abs();
              return Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  border: Border.all(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withOpacity(0.08)
                        : Colors.indigo.shade100,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            transaction['title'] ?? 'EMI',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.shade100,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.red.shade300,
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            formatMoney(amount),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: Colors.red.shade700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          'Date: ${formatDate(transaction['date'] ?? '')}',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.indigo.withOpacity(0.15)
                            : Colors.indigo.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '📋 EMI Details',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const Divider(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Total Amount:'),
                              Text(
                                formatMoney(amount),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Category:'),
                              Text(
                                transaction['category'] ?? 'General',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Interest Rate
                          if (transaction['interest_rate'] != null &&
                              transaction['interest_rate']
                                  .toString()
                                  .isNotEmpty)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Interest Rate:'),
                                Text(
                                  '${transaction['interest_rate']}%',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                            ),
                          // Due Date
                          if (transaction['due_date'] != null &&
                              transaction['due_date']
                                  .toString()
                                  .isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Due Date:'),
                                Text(
                                  formatDate(transaction['due_date']),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.purple,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          // Last Payment Date
                          if (transaction['last_payment_date'] != null &&
                              transaction['last_payment_date']
                                  .toString()
                                  .isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Last Payment:'),
                                Text(
                                  formatDate(transaction['last_payment_date']),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => openEditDialog(transaction),
                            icon: const Icon(Icons.edit, size: 18),
                            label: const Text('Edit'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              if (!_canDelete(transaction)) {
                                _showActionNotification(
                                  'Cannot delete – transactions older than 12 hours are locked 🔒',
                                  icon: Icons.lock_outline,
                                  color: const Color(0xFF4F4F4F),
                                );
                                return;
                              }
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Delete EMI?'),
                                  content: const Text(
                                    'Are you sure you want to delete this EMI?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        deleteTransaction(transaction['id']);
                                      },
                                      child: const Text(
                                        'Delete',
                                        style: TextStyle(color: Colors.red),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade100,
                            ),
                            icon: Icon(
                              Icons.delete,
                              size: 18,
                              color: Colors.red.shade700,
                            ),
                            label: Text(
                              'Delete',
                              style: TextStyle(color: Colors.red.shade700),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildSavingsSection() {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    if (savingsGoals.isNotEmpty) {
      bool idExists = savingsGoals.any(
        (g) => g['id'] == _selectedSavingsGoalId,
      );
      if (!idExists) {
        _selectedSavingsGoalId = savingsGoals.first['id'] as int;
      }
    } else {
      _selectedSavingsGoalId = null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Savings Goals',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            TextButton.icon(
              onPressed: _showCreateGoalDialog,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Goal'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (savingsGoals.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.08)
                    : Colors.grey.shade200,
              ),
            ),
            child: const Center(
              child: Text('No savings goals yet. Create one to start saving!'),
            ),
          )
        else ...[
          // Dropdown for selecting Goal
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.08)
                    : Colors.grey.shade200,
              ),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _selectedSavingsGoalId,
                isExpanded: true,
                items: savingsGoals.map((goal) {
                  return DropdownMenuItem<int>(
                    value: goal['id'] as int,
                    child: Text(
                      goal['title'] ?? 'Goal',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _selectedSavingsGoalId = val;
                    });
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Display the selected Goal
          Builder(
            builder: (ctx) {
              final goal = savingsGoals.firstWhere(
                (g) => g['id'] == _selectedSavingsGoalId,
                orElse: () => savingsGoals.first,
              );
              final double current = (goal['current_amount'] as num).toDouble();
              final double target = (goal['target_amount'] as num).toDouble();
              final double progress = target > 0
                  ? (current / target).clamp(0.0, 1.0)
                  : 0.0;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E293B) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withOpacity(0.08)
                        : Colors.grey.shade200,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF0D9488,
                                ).withOpacity(0.12),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.savings_rounded,
                                color: Color(0xFF0D9488),
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  goal['title'] ?? 'Goal',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${formatMoney(current)} / ${formatMoney(target)}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: isDark
                                        ? Colors.grey.shade400
                                        : Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.more_vert),
                          onPressed: () => _showGoalOptionsDialog(goal),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                      backgroundColor: Colors.grey.shade200,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF0D9488),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF0D9488),
                        ),
                        onPressed: () => _showAddFundsDialog(goal),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Funds'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  void _showCreateGoalDialog() {
    final titleCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Savings Goal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Goal Name (e.g., Vacation)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Target Amount',
                prefixText: _currencySymbol,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final title = titleCtrl.text.trim();
              final amount = double.tryParse(amountCtrl.text.trim());
              if (title.isEmpty || amount == null || amount <= 0) return;
              Navigator.pop(ctx);
              await DatabaseHelper.instance.addSavingsGoal(title, amount, 0);
              await _loadSavingsGoals();
              _showActionNotification(
                'Savings goal created!',
                icon: Icons.flag,
                color: const Color(0xFF0D9488),
              );
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showAddFundsDialog(Map<String, dynamic> goal) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add to ${goal['title']}'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Amount',
            prefixText: _currencySymbol,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0D9488),
            ),
            onPressed: () async {
              final amount = double.tryParse(ctrl.text.trim());
              if (amount == null || amount <= 0) return;
              Navigator.pop(ctx);
              await DatabaseHelper.instance.addFundsToGoal(
                goal['id'] as int,
                amount,
              );
              await DatabaseHelper.instance.insertTransaction({
                'title': 'Added to ${goal['title']}',
                'amount': -amount,
                'category': 'Savings',
                'date': DateTime.now().toIso8601String().split('T')[0],
                'is_expense': 1,
                'notes': 'Money moved to savings goal',
              });
              await _loadSavingsGoals();
              await loadTransactions();
              _showActionNotification(
                '${formatMoney(amount)} added to ${goal['title']}',
                icon: Icons.savings_rounded,
                color: const Color(0xFF0D9488),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showGoalOptionsDialog(Map<String, dynamic> goal) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text(
                'Delete Goal',
                style: TextStyle(color: Colors.red),
              ),
              subtitle: const Text(
                'This will delete the goal (Transactions are not affected).',
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Delete Goal?'),
                    content: const Text(
                      'Are you sure you want to delete this goal? This action cannot be undone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await DatabaseHelper.instance.deleteSavingsGoal(
                    goal['id'] as int,
                  );
                  await _loadSavingsGoals();
                  _showActionNotification(
                    'Goal deleted',
                    icon: Icons.delete_outline,
                    color: Colors.red,
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionsTab() {
    final allAlerts = showBudgetWarnings ? getBudgetAlerts() : <BudgetAlert>[];
    final alerts = allAlerts
        .where((a) => !_dismissedWarnings.contains(a.category))
        .toList();

    return Column(
      children: [
        _buildSummaryCard(),
        if (alerts.isNotEmpty)
          SizedBox(
            height: 90,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              scrollDirection: Axis.horizontal,
              itemCount: alerts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final alert = alerts[index];
                final isExceeded = alert.usage >= 1;
                final bool isDark =
                    Theme.of(context).brightness == Brightness.dark;
                return Container(
                  width: 250,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isExceeded
                        ? (isDark
                              ? const Color(0xFF442726)
                              : const Color(0xFFFFE3E1))
                        : (isDark
                              ? const Color(0xFF423306)
                              : const Color(0xFFFFF4DA)),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isExceeded
                          ? const Color(0xFFEB5757)
                          : const Color(0xFFF2C94C),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isExceeded
                            ? Icons.warning_amber_rounded
                            : Icons.notifications_active_outlined,
                        color: isExceeded
                            ? (isDark
                                  ? Colors.red.shade300
                                  : const Color(0xFFB42318))
                            : (isDark
                                  ? Colors.orange.shade300
                                  : const Color(0xFFB58108)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          isExceeded
                              ? '${alert.category} exceeded by ${formatMoney(alert.spent - alert.limit)}'
                              : '${alert.category} reached ${(alert.usage * 100).toStringAsFixed(0)}% of limit',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: isExceeded
                                ? (isDark
                                      ? Colors.red.shade300
                                      : const Color(0xFF7A2714))
                                : (isDark
                                      ? Colors.orange.shade300
                                      : const Color(0xFF713B12)),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          setState(() {
                            _dismissedWarnings.add(alert.category);
                          });
                        },
                        color: isExceeded
                            ? (isDark
                                  ? Colors.red.shade200
                                  : Colors.red.shade700)
                            : (isDark
                                  ? Colors.orange.shade200
                                  : Colors.orange.shade700),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: TextField(
            controller: searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search transactions...',
              hintStyle: TextStyle(color: Theme.of(context).hintColor),
              prefixIcon: Icon(
                Icons.search,
                color: Theme.of(context).iconTheme.color,
              ),
              suffixIcon: searchController.text.isNotEmpty
                  ? IconButton(
                      onPressed: () {
                        searchController.clear();
                        setState(() {});
                      },
                      icon: Icon(
                        Icons.clear,
                        color: Theme.of(context).iconTheme.color,
                      ),
                    )
                  : null,
              filled: true,
              fillColor: Theme.of(context).cardColor,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterChip('All', TransactionFilter.all),
                const SizedBox(width: 10),
                _buildFilterChip('Income', TransactionFilter.income),
                const SizedBox(width: 10),
                _buildFilterChip('Expense', TransactionFilter.expense),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: filteredTransactions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.receipt_long,
                        size: 64,
                        color: Theme.of(context).dividerColor,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No transactions found',
                        style: TextStyle(
                          fontSize: 18,
                          color: Theme.of(context).hintColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 120),
                  itemCount: filteredTransactions.length,
                  itemBuilder: (context, index) {
                    final t = filteredTransactions[index];
                    final amount = _safeAmount(t['amount']);
                    final isExp = amount < 0;

                    final canDel = _canDelete(t);
                    return Dismissible(
                      key: ValueKey(t['id']),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: canDel
                              ? Colors.red.shade400
                              : Colors.grey.shade400,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              canDel ? Icons.delete : Icons.lock_outline,
                              color: Colors.white,
                            ),
                            if (!canDel)
                              const Text(
                                'Locked',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                      confirmDismiss: (_) async {
                        if (!canDel) {
                          _showActionNotification(
                            'Cannot delete – transactions older than 12 hours are locked 🔒',
                            icon: Icons.lock_outline,
                            color: const Color(
                              0xFF4F4F4F,
                            ), // Harmonious Dark Grey
                          );
                          return false;
                        }
                        return true;
                      },
                      onDismissed: (_) => deleteTransaction(t['id']),
                      child: Card(
                        margin: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 4,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? [
                                      const Color(0xFF1E293B),
                                      const Color(0xFF1F2937),
                                    ]
                                  : (isExp
                                        ? [Colors.white, Colors.red.shade50]
                                        : [Colors.white, Colors.green.shade50]),
                            ),
                          ),
                          child: ListTile(
                            onTap: () => openEditDialog(t),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            leading: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: isExp
                                      ? [
                                          Colors.red.shade400,
                                          Colors.red.shade600,
                                        ]
                                      : [
                                          Colors.green.shade400,
                                          Colors.green.shade600,
                                        ],
                                ),
                              ),
                              child: Icon(
                                isExp
                                    ? Icons.arrow_downward
                                    : Icons.arrow_upward,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                            title: Text(
                              (t['title'] ?? '').toString(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 17,
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black87,
                                letterSpacing: 0.3,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 6),
                                Text(
                                  '${t['category'] ?? 'General'} • ${formatDate(t['date'] ?? '')}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Theme.of(context).hintColor,
                                  ),
                                ),
                              ],
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isExp
                                    ? Colors.red.shade50
                                    : Colors.green.shade50,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isExp
                                      ? Colors.red.shade200
                                      : Colors.green.shade200,
                                  width: 1.5,
                                ),
                              ),
                              child: Text(
                                '${isExp ? '−' : '+'} ${formatMoney(amount.abs())}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: isExp
                                      ? Colors.red.shade700
                                      : Colors.green.shade700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildAnalyticsTab() {
    final now = DateTime.now();
    final currentMonthStats = getMonthlyStats(now.month, now.year);
    final categoryTotals = getCategoryTotals();
    final pieData = getPieChartData();
    final monthlyBars = getMonthlySpendingData();
    final labels = getMonthlyLabels();
    final highestCategory = getHighestSpendingCategory();
    final averageDaily = getAverageDailyExpense();
    final double maxY = monthlyBars.isEmpty
        ? 10000
        : math
              .max(
                10000,
                monthlyBars
                        .map((e) => e.barRods.first.toY)
                        .fold<double>(
                          0,
                          (prev, next) => prev > next ? prev : next,
                        ) *
                    1.2,
              )
              .toDouble();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildInsightMiniCard(
                  title: 'Highest spending category',
                  value: highestCategory,
                  icon: Icons.local_fire_department_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildInsightMiniCard(
                  title: 'Average daily expense',
                  value: formatMoney(averageDaily),
                  icon: Icons.calendar_view_day_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                insightsDateRange != null
                    ? '${insightsDateRange!.start.day}/${insightsDateRange!.start.month} - ${insightsDateRange!.end.day}/${insightsDateRange!.end.month}'
                    : 'This Month',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              if (insightsDateRange != null)
                IconButton(
                  icon: const Icon(Icons.clear, color: Colors.red),
                  onPressed: () => setState(() => insightsDateRange = null),
                  tooltip: 'Clear Filter',
                ),
              TextButton.icon(
                icon: const Icon(Icons.date_range),
                label: const Text('Filter'),
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                    initialDateRange: insightsDateRange,
                  );
                  if (picked != null) {
                    setState(() {
                      insightsDateRange = picked;
                    });
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: Theme.of(context).brightness == Brightness.dark
                    ? [const Color(0xFF1E293B), const Color(0xFF0F172A)]
                    : [const Color(0xFF6366F1), const Color(0xFF818CF8)],
              ),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                  blurRadius: 15,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              children: [
                // Income Row
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.arrow_upward,
                            color: Colors.green.shade600,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Income',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        formatMoney(currentMonthStats['income']),
                        style: TextStyle(
                          color: Colors.green.shade700,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Expense Row
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.arrow_downward,
                            color: Colors.red.shade600,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Expense',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        formatMoney(currentMonthStats['expense']),
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 2,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.blue.shade200, Colors.blue.shade100],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Balance Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Balance',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: currentMonthStats['balance'] >= 0
                            ? Colors.green.shade100
                            : Colors.red.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        formatMoney(currentMonthStats['balance']),
                        style: TextStyle(
                          color: currentMonthStats['balance'] >= 0
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'By Category',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),
          ...categoryTotals.entries.map((entry) {
            final isExp = entry.value < 0;
            final bool isDark = Theme.of(context).brightness == Brightness.dark;
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isExp
                      ? [
                          isDark ? const Color(0xFF451A1A) : Colors.red.shade50,
                          isDark
                              ? const Color(0xFF2D1212)
                              : Colors.red.shade100,
                        ]
                      : [
                          isDark
                              ? const Color(0xFF143021)
                              : Colors.green.shade50,
                          isDark
                              ? const Color(0xFF0F2418)
                              : Colors.green.shade100,
                        ],
                ),
                border: Border.all(
                  color: isExp
                      ? (isDark
                            ? Colors.red.withOpacity(0.3)
                            : Colors.red.shade200)
                      : (isDark
                            ? Colors.green.withOpacity(0.3)
                            : Colors.green.shade200),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      entry.key,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatMoney(entry.value.abs()),
                    style: TextStyle(
                      color: isExp
                          ? (isDark ? Colors.red.shade300 : Colors.red.shade700)
                          : (isDark
                                ? Colors.green.shade300
                                : Colors.green.shade700),
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 20),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Category Pie Chart',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 240,
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Theme.of(context).dividerColor.withOpacity(0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: pieData.isEmpty
                ? const Center(child: Text('No expense data this month'))
                : PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 30,
                      sections: pieData,
                    ),
                  ),
          ),
          const SizedBox(height: 20),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Monthly Spending Overview',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Last 6 months - Green: Income, Red: Expense',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                height: 16,
                width: 16,
                decoration: BoxDecoration(
                  color: const Color(0xFF36D6A8),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Income',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(width: 20),
              Container(
                height: 16,
                width: 16,
                decoration: BoxDecoration(
                  color: const Color(0xFFEB5757),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Expense',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 300,
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(0, 20, 12, 8),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Theme.of(context).dividerColor.withOpacity(0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: monthlyBars.isEmpty
                ? const Center(child: Text('No monthly data available'))
                : BarChart(
                    BarChartData(
                      maxY: maxY,
                      gridData: FlGridData(
                        drawVerticalLine: false,
                        horizontalInterval: maxY / 4,
                        getDrawingHorizontalLine: (value) =>
                            FlLine(color: Colors.grey.shade100, strokeWidth: 1),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border(
                          left: BorderSide(
                            color: Colors.grey.shade300,
                            width: 1,
                          ),
                          bottom: BorderSide(
                            color: Colors.grey.shade300,
                            width: 1,
                          ),
                        ),
                      ),
                      barGroups: monthlyBars,
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 45,
                            interval: maxY / 4,
                            getTitlesWidget: (value, meta) => Text(
                              '${formatMoney(value)}',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (value, meta) {
                              final idx = value.toInt();
                              return Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  idx >= 0 && idx < labels.length
                                      ? labels[idx]
                                      : '',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionsSection() {
    final double monthlyTotal = recurringTransactions.fold(
      0.0,
      (sum, rt) => sum + (rt['amount'] as num).abs().toDouble(),
    );
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Subscriptions',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.08)
                  : Colors.grey.shade200,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.repeat_rounded,
                      color: Color(0xFF6366F1),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${recurringTransactions.length} active subscription${recurringTransactions.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatMoney(monthlyTotal)} / month',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? Colors.grey.shade400
                                : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _showManageSubscriptionsDialog,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Manage'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF6366F1),
                    ),
                  ),
                ],
              ),
              if (recurringTransactions.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                ...recurringTransactions.take(3).map((rt) {
                  final amt = (rt['amount'] as num).abs().toDouble();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.circle,
                              size: 8,
                              color: Color(0xFF6366F1),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              rt['title'] ?? 'Recurring',
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          formatMoney(amt),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: isDark
                                ? Colors.red.shade300
                                : Colors.red.shade700,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (recurringTransactions.length > 3)
                  Center(
                    child: TextButton(
                      onPressed: _showManageSubscriptionsDialog,
                      child: Text('+${recurringTransactions.length - 3} more…'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBudgetTab() {
    final now = DateTime.now();
    final spending = getCategorySpendingForMonth(now.month, now.year);
    final categories = expenseCategories.where((e) => e != 'EMI').toList();

    if (selectedBudgetCategory.isEmpty && categories.isNotEmpty) {
      selectedBudgetCategory = categories.first;
    } else if (selectedBudgetCategory == 'OVERALL' && categories.isNotEmpty) {
      selectedBudgetCategory = categories.first;
    }

    final emiTransactions = transactions
        .where((t) => (t['category'] ?? '') == 'EMI')
        .toList();
    final emiTotal = emiTransactions.fold<double>(
      0,
      (sum, t) => sum + _safeAmount(t['amount']).abs(),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
      children: [
        const Text(
          'Budget Limits',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'Set monthly limits and track warning levels for ${now.month}/${now.year}.',
        ),
        const SizedBox(height: 16),
        // Dedicated Overall Budget Card
        Builder(
          builder: (context) {
            final spent =
                (getMonthlyStats(now.month, now.year)['expense'] as num)
                    .toDouble();
            final limit = categoryBudgets['OVERALL'] ?? 0;
            final usage = limit <= 0 ? 0 : spent / limit;

            return Card(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1E293B)
                  : Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withOpacity(0.1),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.account_balance_wallet, size: 20),
                            SizedBox(width: 8),
                            Text(
                              'Overall Monthly Budget',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        TextButton.icon(
                          onPressed: () => _showBudgetEditor('OVERALL', limit),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: Text(limit <= 0 ? 'Set Budget' : 'Edit'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: limit <= 0 ? 0 : usage.clamp(0.0, 1.0).toDouble(),
                      minHeight: 12,
                      borderRadius: BorderRadius.circular(10),
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        usage >= 1
                            ? const Color(0xFFEB5757)
                            : usage >= 0.8
                            ? const Color(0xFFF2C94C)
                            : const Color(0xFF36D6A8),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Spent: ${formatMoney(spent)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Limit: ${limit <= 0 ? 'Not set' : formatMoney(limit)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 24),
        const Text(
          'Category Budgets',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        DropdownButton<String>(
          isExpanded: true,
          style: TextStyle(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white
                : Colors.black87,
            fontSize: 16,
          ),
          value: categories.contains(selectedBudgetCategory)
              ? selectedBudgetCategory
              : (categories.isNotEmpty ? categories.first : ''),
          items: categories.map((category) {
            return DropdownMenuItem<String>(
              value: category,
              child: Text(
                category,
                style: TextStyle(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : Colors.black87,
                ),
              ),
            );
          }).toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() {
                selectedBudgetCategory = value;
              });
            }
          },
        ),
        const SizedBox(height: 16),
        if (selectedBudgetCategory.isNotEmpty)
          Builder(
            builder: (context) {
              final spent = spending[selectedBudgetCategory] ?? 0;
              final limit = categoryBudgets[selectedBudgetCategory] ?? 0;
              final usage = limit <= 0 ? 0 : spent / limit;
              final suggestion =
                  _cachedBudgetSuggestions[selectedBudgetCategory] ?? 0.0;

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              selectedBudgetCategory,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => _showBudgetEditor(
                              selectedBudgetCategory,
                              limit,
                            ),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: Text(limit <= 0 ? 'Set limit' : 'Edit'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Spent: ${formatMoney(spent)}'),
                      Text(
                        'Limit: ${limit <= 0 ? 'Not set' : formatMoney(limit)}',
                      ),
                      if (suggestion > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: InkWell(
                            onTap: () => _showBudgetEditor(
                              selectedBudgetCategory,
                              suggestion,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF6366F1).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(
                                    0xFF6366F1,
                                  ).withOpacity(0.3),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.auto_awesome,
                                    size: 14,
                                    color: Color(0xFF6366F1),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'AI Suggests: ${formatMoney(suggestion)}',
                                    style: const TextStyle(
                                      color: Color(0xFF6366F1),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: limit <= 0
                            ? 0
                            : usage.clamp(0.0, 1.0).toDouble(),
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(10),
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          usage >= 1
                              ? const Color(0xFFEB5757)
                              : usage >= 0.8
                              ? const Color(0xFFF2C94C)
                              : const Color(0xFF36D6A8),
                        ),
                      ),
                      if (limit > 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          usage >= 1
                              ? 'Limit exceeded'
                              : usage >= 0.8
                              ? 'Warning: ${(usage * 100).toStringAsFixed(0)}% used'
                              : '${(usage * 100).toStringAsFixed(0)}% used',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: usage >= 1
                                ? const Color(0xFFB42318)
                                : usage >= 0.8
                                ? const Color(0xFFB58108)
                                : const Color(0xFF0E7A5F),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 8),
        const Text(
          'EMI Overview',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.credit_card),
            title: Text('Active EMI entries: ${emiTransactions.length}'),
            subtitle: Text('Total EMI spending: ${formatMoney(emiTotal)}'),
            children: [SizedBox(height: 420, child: _buildEMITab())],
          ),
        ),
        const SizedBox(height: 20),
        _buildSavingsSection(),
        const SizedBox(height: 20),
        _buildSubscriptionsSection(),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildInsightMiniCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF1E293B)
            : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withOpacity(0.1)
              : Colors.grey.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Future<void> _showBudgetEditor(String category, double currentValue) async {
    budgetLimitController.text = currentValue > 0
        ? currentValue.toStringAsFixed(0)
        : '';
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Budget for $category'),
        content: TextField(
          controller: budgetLimitController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Monthly limit',
            prefixText: '\u20B9',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final value = double.tryParse(budgetLimitController.text.trim());
              if (value == null || value <= 0) {
                _showMessage('Enter a valid amount');
                return;
              }
              Navigator.pop(context);
              await _setBudgetLimitForCategory(category, value);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    final totalBalance = getTotalBalance();
    final incomeTotal = getIncomeTotal();
    final expenseTotal = getExpenseTotal();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? [const Color(0xFF6366F1), const Color(0xFF4338CA)]
              : [const Color(0xFF4F46E5), const Color(0xFF6366F1)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withOpacity(0.4),
            blurRadius: 25,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total Balance',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
              Icon(
                Icons.wallet_rounded,
                color: Colors.white.withOpacity(0.5),
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            formatMoney(totalBalance),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: _buildMiniStat(
                  'Income',
                  formatMoney(incomeTotal),
                  const Color(0xFF34D399), // Emerald 400
                  Icons.arrow_upward_rounded,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildMiniStat(
                  'Expense',
                  formatMoney(expenseTotal),
                  const Color(0xFFF87171), // Red 400
                  Icons.arrow_downward_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniStat(
    String label,
    String value,
    Color color,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, TransactionFilter filter) {
    final isSelected = selectedFilter == filter;
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: isSelected
            ? primaryColor
            : (isDark ? theme.cardColor : Colors.white),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isSelected
              ? primaryColor
              : (isDark ? Colors.grey.shade800 : Colors.grey.shade300),
          width: 1.5,
        ),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: primaryColor.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() => selectedFilter = filter);
          },
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Text(
              label,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 14,
                color: isSelected
                    ? Colors.white
                    : (isDark ? Colors.grey.shade300 : Colors.grey.shade700),
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransactionSheet({
    required String title,
    required String buttonText,
    required Future<bool> Function() onSubmit,
  }) {
    return StatefulBuilder(
      builder: (context, setModalState) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 24),
              // Transaction Type
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withValues(alpha: 0.1),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      label: Text('Income'),
                      icon: Icon(Icons.arrow_upward),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      label: Text('Expense'),
                      icon: Icon(Icons.arrow_downward),
                    ),
                  ],
                  selected: {isExpense},
                  onSelectionChanged: (values) {
                    setModalState(() {
                      isExpense = values.first;
                      selectedCategory = isExpense
                          ? expenseCategories.first
                          : incomeCategories.first;
                    });
                  },
                ),
              ),
              const SizedBox(height: 20),
              // Transaction Title
              TextField(
                controller: titleController,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Title',
                  labelStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  prefixIcon: const Icon(Icons.label),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Amount
              TextField(
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Amount',
                  labelStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  prefixIcon: const Icon(Icons.currency_rupee),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF0066AA),
                      width: 2,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Category with management button
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: selectedCategory,
                      style: TextStyle(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black87,
                        fontSize: 16,
                      ),
                      items: (isExpense ? expenseCategories : incomeCategories)
                          .map(
                            (cat) => DropdownMenuItem(
                              value: cat,
                              child: Text(
                                cat,
                                style: TextStyle(
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setModalState(
                          () => selectedCategory =
                              value ??
                              (isExpense
                                  ? expenseCategories.first
                                  : incomeCategories.first),
                        );
                      },
                      decoration: InputDecoration(
                        labelText: 'Category',
                        labelStyle: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey[300]
                              : Colors.grey[800],
                          fontSize: 15,
                        ),
                        prefixIcon: Icon(
                          Icons.category,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey[300]
                              : Colors.grey[700],
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Color(0xFF0066AA),
                            width: 2,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Date picker
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2050),
                  );
                  if (picked != null) {
                    setModalState(() => selectedDate = picked);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[400]!),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatDate(selectedDate.toString()),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const Icon(Icons.calendar_today),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // EMI Fields - only show for EMI category
              if (selectedCategory == 'EMI') ...[
                Divider(height: 24),
                const Text(
                  '💳 EMI Details',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 12),
                // Interest Rate
                TextField(
                  controller: emiInterestRateController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Interest Rate (%)',
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[800],
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    suffixText: '%',
                    suffixStyle: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700],
                    ),
                  ),
                  onChanged: (value) {
                    setModalState(() {
                      emiInterestRate = double.tryParse(value) ?? 0.0;
                    });
                  },
                ),
                const SizedBox(height: 12),
                // Due Date
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate:
                          emiDueDate ??
                          DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime(2050),
                    );
                    if (picked != null) {
                      setModalState(() => emiDueDate = picked);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.purple, width: 2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          emiDueDate != null
                              ? 'Due Date: ${formatDate(emiDueDate.toString())}'
                              : 'Due Date: Select date',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const Icon(Icons.calendar_today, color: Colors.purple),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Last Payment Date
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: emiLastPaymentDate ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2050),
                    );
                    if (picked != null) {
                      setModalState(() => emiLastPaymentDate = picked);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.orange, width: 2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          emiLastPaymentDate != null
                              ? 'Last Payment: ${formatDate(emiLastPaymentDate.toString())}'
                              : 'Last Payment: Select date',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const Icon(Icons.calendar_today, color: Colors.orange),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  onPressed: () async {
                    final success = await onSubmit();
                    if (!mounted) {
                      return;
                    }
                    if (success) {
                      Navigator.pop(context);
                    }
                  },
                  icon: const Icon(Icons.check, size: 20),
                  label: Text(
                    buttonText,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Info chip helper ──
  Widget _infoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  // ── Edit Profile Sheet ──
  void _openEditProfileSheet() {
    final nameCtrl = TextEditingController(
      text:
          (_userProfile['name'] as String?) ??
          (AuthService.instance.currentUserDisplayName ?? ''),
    );
    final phoneCtrl = TextEditingController(
      text: (_userProfile['phone'] as String?) ?? '',
    );
    DateTime? dobDate;
    final dobStr = (_userProfile['dob'] as String?) ?? '';
    if (dobStr.isNotEmpty) {
      try {
        dobDate = DateTime.parse(dobStr);
      } catch (_) {}
    }
    int selectedColorIdx = (_userProfile['avatar_color_index'] as int?) ?? 0;
    final avatarColors = [
      const Color(0xFF6366F1),
      const Color(0xFF8B5CF6),
      const Color(0xFFEC4899),
      const Color(0xFF14B8A6),
      const Color(0xFFF59E0B),
      const Color(0xFF10B981),
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 24,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 32,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Edit Profile',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Avatar color picker
                    const Text(
                      'Avatar Color',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: List.generate(avatarColors.length, (i) {
                        return GestureDetector(
                          onTap: () =>
                              setSheetState(() => selectedColorIdx = i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.only(right: 10),
                            width: selectedColorIdx == i ? 44 : 36,
                            height: selectedColorIdx == i ? 44 : 36,
                            decoration: BoxDecoration(
                              color: avatarColors[i],
                              shape: BoxShape.circle,
                              border: selectedColorIdx == i
                                  ? Border.all(color: Colors.black26, width: 3)
                                  : null,
                            ),
                            child: selectedColorIdx == i
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 20,
                                  )
                                : null,
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 20),

                    // Name
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(
                        labelText: 'Full Name',
                        prefixIcon: const Icon(Icons.person_outline),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Phone
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: 'Phone Number',
                        prefixIcon: const Icon(Icons.phone_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Date of Birth
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: dobDate ?? DateTime(1995, 1, 1),
                          firstDate: DateTime(1920),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) {
                          setSheetState(() => dobDate = picked);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.cake_outlined, color: Colors.grey),
                            const SizedBox(width: 12),
                            Text(
                              dobDate != null
                                  ? '${dobDate!.day}/${dobDate!.month}/${dobDate!.year}'
                                  : 'Date of Birth',
                              style: TextStyle(
                                fontSize: 16,
                                color: dobDate != null
                                    ? Theme.of(
                                        context,
                                      ).textTheme.bodyLarge?.color
                                    : Colors.grey,
                              ),
                            ),
                            const Spacer(),
                            const Icon(
                              Icons.calendar_today,
                              size: 18,
                              color: Colors.grey,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Save button
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () async {
                          final profile = {
                            'name': nameCtrl.text.trim(),
                            'phone': phoneCtrl.text.trim(),
                            'dob':
                                dobDate?.toIso8601String().split('T')[0] ?? '',
                            'avatar_color_index': selectedColorIdx,
                          };
                          await DatabaseHelper.instance.saveUserProfile(
                            profile,
                          );
                          if (mounted) {
                            setState(() => _userProfile = profile);
                            Navigator.pop(ctx);
                            _showMessage('Profile saved!');
                          }
                        },
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save Profile'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ── AI Analyst Tab ──
  Widget _buildAIAnalystTab() {
    final insights = _cachedInsights;
    final allAnomalies = _cachedAnomalies;
    final anomalies = allAnomalies
        .where(
          (a) => !_dismissedAnomalyIds.contains(
            a.transaction != null ? a.transaction!['id'] as int? ?? -1 : -1,
          ),
        )
        .toList();
    final suggestions = _cachedSuggestions;

    return RefreshIndicator(
      onRefresh: () async {
        await loadTransactions();
      },
      child: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.auto_awesome,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'AI Analyst',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'Smart insights from your data',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          _aiStatPill('${insights.length}', 'Insights'),
                          const SizedBox(width: 10),
                          _aiStatPill('${anomalies.length}', 'Alerts'),
                          const SizedBox(width: 10),
                          _aiStatPill('${suggestions.length}', 'Suggestions'),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_aiDataLoading)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: LinearProgressIndicator(
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        const Color(0xFF6366F1).withOpacity(0.5),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),

                // ── Pro Features: Health & Forecast ──
                Row(
                  children: [
                    Expanded(
                      child: _buildProMetricCard(
                        title: 'Health Score',
                        value: '$_cachedHealthScore',
                        subtitle: _getHealthLabel(_cachedHealthScore),
                        icon: Icons.favorite,
                        color: _getHealthColor(_cachedHealthScore),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildProMetricCard(
                        title: 'Forecast',
                        value: formatMoney(_cachedForecast),
                        subtitle: 'Est. this month',
                        icon: Icons.query_stats,
                        color: const Color(0xFF6366F1),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // ── Section 1: Spending Insights ──
                _sectionHeader(
                  '🧠',
                  'Spending Insights',
                  'Patterns detected from your history',
                ),
                const SizedBox(height: 12),
                if (insights.isEmpty && !_aiDataLoading)
                  _emptyCard(
                    icon: Icons.insights_outlined,
                    msg: 'Add more transactions to unlock spending insights.',
                  )
                else
                  ...insights.map((insight) => _insightCard(insight)),

                const SizedBox(height: 28),

                // ── Section 2: Anomaly Detection ──
                _sectionHeader(
                  '🚨',
                  'Anomaly Alerts',
                  'Unusual activity flagged automatically',
                ),
                const SizedBox(height: 12),
                if (anomalies.isEmpty && !_aiDataLoading)
                  _emptyCard(
                    icon: Icons.verified_outlined,
                    msg:
                        'No anomalies detected. Your transactions look normal!',
                    isGood: true,
                  )
                else
                  ...anomalies.map((flag) => _anomalyCard(flag)),

                const SizedBox(height: 28),

                // ── Section 3: Merchant Intelligence ──
                _sectionHeader(
                  '🏪',
                  'Merchant Intelligence',
                  'Smart category suggestions from transaction names',
                ),
                const SizedBox(height: 12),
                if (suggestions.isEmpty && !_aiDataLoading)
                  _emptyCard(
                    icon: Icons.storefront_outlined,
                    msg: 'All your transactions are already well-categorized!',
                    isGood: true,
                  )
                else ...[
                  if (suggestions.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF423306) // Dark amber
                            : Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.amber.shade400
                              : Colors.amber.shade200,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline,
                            color: Colors.amber.shade700,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${suggestions.length} transaction(s) may have better categories.',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Colors.amber.shade800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  ...suggestions
                      .take(10)
                      .map((s) => _merchantSuggestionCard(s)),
                  if (suggestions.length > 1) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF6366F1),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: () => _applySmartCategories(suggestions),
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text(
                          'Apply All Smart Categories',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _aiStatPill(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildProMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: isDark ? Colors.white70 : Colors.black54,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black87,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            subtitle,
            style: TextStyle(
              color: color.withOpacity(0.8),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _getHealthLabel(int score) {
    if (score >= 80) return 'Excellent';
    if (score >= 60) return 'Good';
    if (score >= 40) return 'Fair';
    return 'Action Needed';
  }

  Color _getHealthColor(int score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.blue;
    if (score >= 40) return Colors.orange;
    return Colors.red;
  }

  Widget _sectionHeader(String emoji, String title, String subtitle) {
    return Row(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 24)),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
      ],
    );
  }

  Widget _emptyCard({
    required IconData icon,
    required String msg,
    bool isGood = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isGood
            ? (isDark ? Colors.green.withOpacity(0.15) : Colors.green.shade50)
            : (isDark ? Colors.grey.withOpacity(0.15) : Colors.grey.shade50),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isGood
              ? (isDark ? Colors.green.shade700 : Colors.green.shade200)
              : (isDark ? Colors.grey.shade700 : Colors.grey.shade200),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 32,
            color: isGood ? Colors.green.shade400 : Colors.grey.shade400,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                color: isGood ? Colors.green.shade700 : Colors.grey.shade600,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _insightCard(SpendingInsight insight) {
    final colors = {
      InsightType.pattern: [const Color(0xFF6366F1), const Color(0xFF8B5CF6)],
      InsightType.warning: [const Color(0xFFEF4444), const Color(0xFFF97316)],
      InsightType.tip: [const Color(0xFF10B981), const Color(0xFF059669)],
      InsightType.info: [const Color(0xFF0EA5E9), const Color(0xFF6366F1)],
    };
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gradColors =
        colors[insight.type] ??
        [const Color(0xFF6366F1), const Color(0xFF8B5CF6)];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            gradColors[0].withOpacity(0.08),
            gradColors[1].withOpacity(0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: gradColors[0].withOpacity(0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: gradColors),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(insight.emoji, style: const TextStyle(fontSize: 18)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  insight.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  insight.description,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _anomalyCard(AnomalyFlag flag) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAlert = flag.severity == AnomalySeverity.alert;
    final color = isAlert ? const Color(0xFFEF4444) : const Color(0xFFF97316);
    final bgColor = isAlert
        ? (isDark ? const Color(0xFF442726) : Colors.red.shade50)
        : (isDark ? const Color(0xFF423306) : Colors.orange.shade50);
    final borderColor = isAlert
        ? (isDark ? Colors.red.shade900 : Colors.red.shade200)
        : (isDark ? Colors.orange.shade900 : Colors.orange.shade200);
    final txId = flag.transaction?['id'] as int? ?? -1;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(flag.emoji, style: const TextStyle(fontSize: 20)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        flag.title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: color,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        isAlert ? 'ALERT' : 'WARNING',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  flag.description,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _dismissedAnomalyIds.add(txId));
                  },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Dismiss', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _merchantSuggestionCard(MerchantSuggestion suggestion) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (suggestion.transaction['title'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        (suggestion.transaction['category'] ?? 'General')
                            .toString(),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(
                        Icons.arrow_forward,
                        size: 12,
                        color: Colors.grey,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6366F1).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        suggestion.inferredCategory,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF6366F1),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              final id = suggestion.transaction['id'];
              if (id == null) return;
              final updated = {
                ...suggestion.transaction,
                'category': suggestion.inferredCategory,
              };
              await DatabaseHelper.instance.updateTransaction(updated);
              await loadTransactions();
              if (mounted)
                _showMessage(
                  'Category updated to ${suggestion.inferredCategory}',
                );
            },
            child: const Text(
              'Apply',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applySmartCategories(
    List<MerchantSuggestion> suggestions,
  ) async {
    int updated = 0;
    for (final s in suggestions) {
      final id = s.transaction['id'];
      if (id == null) continue;
      final u = {...s.transaction, 'category': s.inferredCategory};
      await DatabaseHelper.instance.updateTransaction(u);
      updated++;
    }
    await loadTransactions();
    if (mounted) {
      _showMessage('Updated $updated transaction(s) with smart categories!');
    }
  }

  void _showCurrencyPicker() {
    const symbols = ['₹', '\$', '€', '£', '¥', '₩', '฿', '₪'];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Currency Symbol'),
        content: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: symbols.map((sym) {
            return InkWell(
              onTap: () {
                setState(() => _currencySymbol = sym);
                Navigator.pop(context);
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _currencySymbol == sym
                        ? const Color(0xFF6366F1)
                        : Colors.grey.shade300,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  color: _currencySymbol == sym
                      ? const Color(0xFF6366F1).withOpacity(0.1)
                      : null,
                ),
                child: Text(sym, style: const TextStyle(fontSize: 24)),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _exportToCSV() async {
    try {
      if (transactions.isEmpty) {
        _showMessage('No transactions to export.');
        return;
      }
      final header = 'Date,Title,Category,Amount\n';
      final rows = transactions
          .map((t) {
            final date = t['date'] ?? '';
            final title = (t['title'] ?? '').toString().replaceAll('"', '""');
            final category = (t['category'] ?? '').toString().replaceAll(
              '"',
              '""',
            );
            final amount = t['amount'] ?? 0;
            return '$date,"$title","$category",$amount';
          })
          .join('\n');

      final csvData = header + rows;

      // Get temporary directory
      final directory = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${directory.path}/smartmoney_export_$timestamp.csv');

      // Write data to the file
      await file.writeAsString(csvData);

      // Share the file
      if (mounted) {
        final box = context.findRenderObject() as RenderBox?;
        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'SmartMoney Transactions Export',
          text: 'Here is your exported transaction history.',
          sharePositionOrigin: box!.localToGlobal(Offset.zero) & box.size,
        );
      }
    } catch (e) {
      if (mounted) {
        _showMessage('Export failed: $e');
      }
    }
  }
}

// ─── Money-Themed Loading Screen ─────────────────────────────────────────────

class _MoneyLoadingScreen extends StatefulWidget {
  const _MoneyLoadingScreen();

  @override
  State<_MoneyLoadingScreen> createState() => _MoneyLoadingScreenState();
}

class _MoneyLoadingScreenState extends State<_MoneyLoadingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _bounceController;
  late final AnimationController _pulseController;

  // Three staggered bounce animations for 3 coin icons
  late final Animation<double> _coin1;
  late final Animation<double> _coin2;
  late final Animation<double> _coin3;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();

    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    // Staggered bounces using intervals
    _coin1 = _buildBounce(0.0, 0.5);
    _coin2 = _buildBounce(0.15, 0.65);
    _coin3 = _buildBounce(0.30, 0.80);

    _pulse = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Animation<double> _buildBounce(double begin, double end) {
    return TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: -28.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: -28.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.bounceOut)),
        weight: 60,
      ),
    ]).animate(
      CurvedAnimation(
        parent: _bounceController,
        curve: Interval(begin, end, curve: Curves.linear),
      ),
    );
  }

  @override
  void dispose() {
    _bounceController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Widget _buildCoin(Animation<double> bounce, String symbol, Color color) {
    return AnimatedBuilder(
      animation: bounce,
      builder: (_, __) => Transform.translate(
        offset: Offset(0, bounce.value),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color.withOpacity(0.9), color],
              center: const Alignment(-0.3, -0.3),
            ),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.5),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: Text(
              symbol,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Matches Splash & Intro
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App name
            const Text(
              'SmartBudget',
              style: TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Loading your finances...',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 15,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
              ),
            ),
            const SizedBox(height: 56),

            // Bouncing coin row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildCoin(_coin1, '₹', const Color(0xFFF59E0B)), // Amber 500
                const SizedBox(width: 20),
                _buildCoin(
                  _coin2,
                  '💰',
                  const Color(0xFF10B981),
                ), // Emerald 500
                const SizedBox(width: 20),
                _buildCoin(_coin3, '₹', const Color(0xFF6366F1)), // Indigo 500
              ],
            ),
            const SizedBox(height: 52),

            // Pulsing dots
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Opacity(
                opacity: _pulse.value,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(3, (i) {
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFFCBD5E1), // Slate 300
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
