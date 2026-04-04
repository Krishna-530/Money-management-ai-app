// import 'package:sqflite/sqflite.dart';
// import 'package:path/path.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

class LocalAuthHelper {
  static final LocalAuthHelper instance = LocalAuthHelper._init();

  // In-memory user storage
  static final List<Map<String, dynamic>> _users = [];
  static bool _initialized = false;

  LocalAuthHelper._init() {
    _initializeTestUser();
  }

  static void _initializeTestUser() {
    if (_initialized) return;
    
    try {
      // Add a test user for debugging
      _users.add({
        'id': 1,
        'email': 'test@example.com',
        'password_hash': hashPassword('password123'),
        'display_name': 'Test User',
        'created_at': DateTime.now().toIso8601String(),
      });
      _initialized = true;
      print('DEBUG: Test user initialized. Total users: ${_users.length}');
    } catch (e) {
      print('DEBUG: Error initializing test user: $e');
    }
  }

  // Hash password using SHA256
  static String hashPassword(String password) {
    return sha256.convert(utf8.encode(password)).toString();
  }

  // Register a new local user
  Future<bool> registerUser({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      _initializeTestUser(); // Ensure test user exists
      
      // Check if email already exists
      if (_users.any((u) => u['email'] == email)) {
        throw Exception('Email already registered');
      }

      final passwordHash = hashPassword(password);

      _users.add({
        'id': _users.length + 1,
        'email': email,
        'password_hash': passwordHash,
        'display_name': displayName,
        'created_at': DateTime.now().toIso8601String(),
      });

      print('DEBUG: User registered: $email');
      return true;
    } catch (e) {
      throw Exception('Registration failed: $e');
    }
  }

  // Verify user login
  Future<Map<String, dynamic>?> loginUser({
    required String email,
    required String password,
  }) async {
    try {
      _initializeTestUser(); // Ensure test user exists
      
      final passwordHash = hashPassword(password);
      
      print('DEBUG: Attempting login for email: $email');
      print('DEBUG: Users in database: ${_users.length}');
      
      final user = _users.firstWhere(
        (u) => u['email'] == email && u['password_hash'] == passwordHash,
        orElse: () => {},
      );

      if (user.isEmpty) {
        // Check if email exists
        final emailUser = _users.firstWhere(
          (u) => u['email'] == email,
          orElse: () => {},
        );
        
        if (emailUser.isNotEmpty) {
          print('DEBUG: Email found but password mismatch');
          print('DEBUG: Expected hash: ${emailUser['password_hash']}');
          print('DEBUG: Got hash: $passwordHash');
          throw Exception('Invalid password');
        } else {
          print('DEBUG: Email not found in database');
          print('DEBUG: Available emails: ${_users.map((u) => u['email']).toList()}');
          throw Exception('Email not registered');
        }
      }

      print('DEBUG: Login successful for ${user['email']}');
      return user;
    } catch (e) {
      print('DEBUG: Login error: $e');
      throw Exception('Login failed: $e');
    }
  }

  // Get user by email
  Future<Map<String, dynamic>?> getUserByEmail(String email) async {
    try {
      final user = _users.firstWhere(
        (u) => u['email'] == email,
        orElse: () => {},
      );
      return user.isEmpty ? null : user;
    } catch (e) {
      throw Exception('Failed to get user: $e');
    }
  }

  // Get all users
  Future<List<Map<String, dynamic>>> getAllUsers() async {
    try {
      return List.from(_users);
    } catch (e) {
      throw Exception('Failed to get users: $e');
    }
  }

  // Update display name
  Future<bool> updateDisplayName(String email, String displayName) async {
    try {
      final index = _users.indexWhere((u) => u['email'] == email);
      if (index != -1) {
        _users[index]['display_name'] = displayName;
        return true;
      }
      return false;
    } catch (e) {
      throw Exception('Failed to update display name: $e');
    }
  }

  // Delete user
  Future<bool> deleteUser(String email) async {
    try {
      final initialLength = _users.length;
      _users.removeWhere((u) => u['email'] == email);
      return _users.length < initialLength;
    } catch (e) {
      throw Exception('Failed to delete user: $e');
    }
  }

  // Clear all users (for testing or reset)
  Future<void> clearAllUsers() async {
    try {
      _users.clear();
    } catch (e) {
      print('Error clearing users: $e');
    }
  }
}
