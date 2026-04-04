import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  factory NotificationService() {
    return _instance;
  }

  NotificationService._internal();

  Future<void> initialize() async {
    tz.initializeTimeZones();

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    // Request permissions on Android 13+
    await requestPermission();

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // Handle notification tap
      },
    );

    debugPrint('System-level notification service initialized');
  }

  Future<void> requestPermission() async {
    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> showBudgetLowNotification({
    required String category,
    required double spent,
    required double limit,
    required double percentage,
  }) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'budget_alerts',
          'Budget Alerts',
          channelDescription:
              'Notifications for budget warnings and exceedances',
          importance: Importance.high,
          priority: Priority.high,
          color: Colors.orange,
        );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notificationsPlugin.show(
      category.hashCode,
      '💡 Budget Warning: $category',
      'You have spent ${(percentage).toStringAsFixed(0)}% of your budget (${_formatMoney(spent)} / ${_formatMoney(limit)})',
      platformDetails,
    );
  }

  Future<void> showBudgetExceededNotification({
    required String category,
    required double spent,
    required double limit,
  }) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'budget_alerts',
          'Budget Alerts',
          channelDescription:
              'Notifications for budget warnings and exceedances',
          importance: Importance.max,
          priority: Priority.high,
          color: Colors.red,
        );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
    );

    await _notificationsPlugin.show(
      category.hashCode + 1000,
      '⚠️ Budget Exceeded: $category',
      'You exceeded your budget by ${_formatMoney(spent - limit)}!',
      platformDetails,
    );
  }

  Future<void> scheduleEMIReminder({
    required String emiTitle,
    required DateTime dueDate,
    required double amount,
    required int daysBeforeReminder,
  }) async {
    final scheduledDate = dueDate.subtract(Duration(days: daysBeforeReminder));
    if (scheduledDate.isBefore(DateTime.now())) return;

    await _notificationsPlugin.zonedSchedule(
      emiTitle.hashCode,
      '📅 EMI Reminder: $emiTitle',
      'Your EMI of ${_formatMoney(amount)} is due in $daysBeforeReminder days',
      tz.TZDateTime.from(scheduledDate, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'emi_reminders',
          'EMI Reminders',
          channelDescription: 'Notifications for upcoming EMI payments',
          importance: Importance.high,
          priority: Priority.high,
          color: Colors.blue,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> scheduleEMIDueNotification({
    required String emiTitle,
    required DateTime dueDate,
    required double amount,
  }) async {
    if (dueDate.isBefore(DateTime.now())) return;

    await _notificationsPlugin.zonedSchedule(
      emiTitle.hashCode + 1,
      '🚨 EMI Due Today: $emiTitle',
      'Your EMI of ${_formatMoney(amount)} is due today!',
      tz.TZDateTime.from(dueDate, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'emi_reminders',
          'EMI Reminders',
          channelDescription: 'Notifications for upcoming EMI payments',
          importance: Importance.max,
          priority: Priority.high,
          color: Colors.red,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> showAnomalyNotification({
    required String title,
    required String body,
    bool isAlert = false,
  }) async {
    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'ai_anomalies',
      'AI Anomalies',
      channelDescription: 'Notifications for spending anomalies and duplicates',
      importance: Importance.max,
      priority: Priority.high,
      color: isAlert ? Colors.red : Colors.orange,
      playSound: true,
      ticker: 'AI Anomaly Detected',
    );

    await _notificationsPlugin.show(
      DateTime.now().millisecond,
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
  }

  Future<void> cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id);
  }

  Future<void> cancelAllNotifications() async {
    await _notificationsPlugin.cancelAll();
  }

  String _formatMoney(double amount) {
    return '\u20B9${amount.toStringAsFixed(2)}';
  }
}
