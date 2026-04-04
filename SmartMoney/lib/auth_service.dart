import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';

class LocalUser {
  final String email;
  final String? displayName;

  LocalUser({required this.email, this.displayName});
}

class AuthService {
  static final AuthService instance = AuthService._init();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  LocalUser? _localUser;
  bool _isOfflineMode = false;
  bool _isFirebaseInitialized = false;
  bool _isInitializing = true;

  // Unified auth state stream that handles both online and offline users
  final StreamController<bool> _authStateController =
      StreamController<bool>.broadcast();

  AuthService._init() {
    // Forward Firebase auth changes to our unified stream
    _auth.authStateChanges().listen((user) {
      if (!_isOfflineMode) {
        // During cold-start initialization, Firebase may briefly emit null
        // before restoring the persisted session. Only suppress that initial
        // false if we are still initializing AND a user IS already present
        // (i.e. Firebase hasn't finished loading yet).
        if (_isInitializing && user == null) {
          // Suppress: Firebase hasn't restored session yet — wait for initialize()
          return;
        }
        _authStateController.add(user != null);
        debugPrint('AuthService: Firebase authState -> ${user != null}');
      }
    });
  }


  // Unified auth state stream: emits true when logged in, false when logged out
  Stream<bool> get authStateChanges async* {
    yield isLoggedIn;
    yield* _authStateController.stream;
  }

  void _notifyListeners(bool loggedIn) {
    debugPrint('AuthService: Notifying listeners: isLoggedIn = $loggedIn');
    _authStateController.add(loggedIn);
  }


  // Initialize service and load user data on app start
  Future<void> initialize() async {
    try {
      // Check if Firebase is actually available
      if (Firebase.apps.isNotEmpty) {
        _isFirebaseInitialized = true;
        final firebaseUser = _auth.currentUser;
        if (firebaseUser != null) {
          // Firebase user is already logged in
          _isOfflineMode = false;
          await DatabaseHelper.instance.setCurrentUser(firebaseUser.uid);
        }
      } else {
        debugPrint('AuthService: Firebase not initialized (no apps found)');
        _isFirebaseInitialized = false;
      }
    } catch (e) {
      debugPrint('AuthService initialize error: $e');
      _isFirebaseInitialized = false;
    } finally {
      // CRITICAL: Always mark initialization as complete so listeners are not ignored
      _isInitializing = false;
      _notifyListeners(isLoggedIn);
    }
  }

  // Get current user
  User? get currentFirebaseUser => _auth.currentUser;

  // Get local user (if in offline mode)
  LocalUser? get currentLocalUser => _localUser;

  // Check if in offline mode
  bool get isOfflineMode => _isOfflineMode;

  // Get current user email
  String? get currentUserEmail {
    if (!_isOfflineMode && _auth.currentUser != null) {
      return _auth.currentUser?.email;
    }
    return _localUser?.email;
  }

  // Get current user display name
  String? get currentUserDisplayName {
    if (!_isOfflineMode && _auth.currentUser != null) {
      return _auth.currentUser?.displayName;
    }
    return _localUser?.displayName;
  }

  // Check if user is logged in (locally or via Firebase)
  bool get isLoggedIn {
    return (_auth.currentUser != null) || (_localUser != null);
  }


  // Sign up with email and password strictly via Firebase
  Future<dynamic> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      await userCredential.user?.updateDisplayName(displayName);
      _isOfflineMode = false;

      // Migrate any offline data if it exists (for backward compatibility)
      await DatabaseHelper.instance.migrateOfflineData(
        email,
        userCredential.user!.uid,
      );

      await DatabaseHelper.instance.setCurrentUser(userCredential.user!.uid);
      // Firebase's authStateChanges listener will fire and update the stream.
      // Emit explicitly too so navigation happens immediately.
      _notifyListeners(true);

      return userCredential;
    } on FirebaseAuthException catch (e) {
      String message = 'Signup failed';
      switch (e.code) {
        case 'email-already-in-use':
          message = 'This email is already in use.';
          break;
        case 'invalid-email':
          message = 'The email address is invalid.';
          break;
        case 'weak-password':
          message = 'The password is too weak.';
          break;
        default:
          message = e.message ?? 'An unknown error occurred.';
      }
      throw Exception(message);
    } catch (e) {
      throw Exception('An error occurred during signup: $e');
    }
  }

  // Login with email and password strictly via Firebase
  Future<dynamic> login({
    required String email,
    required String password,
  }) async {
    try {
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      _isOfflineMode = false;

      // Ensure local data is associated with the Firebase UID
      await DatabaseHelper.instance.migrateOfflineData(
        email,
        userCredential.user!.uid,
      );

      await DatabaseHelper.instance.setCurrentUser(userCredential.user!.uid);
      // Firebase's authStateChanges listener will fire and update the stream.
      // Emit explicitly too so navigation happens immediately.
      _notifyListeners(true);

      return userCredential;
    } on FirebaseAuthException catch (e) {
      String message = 'Login failed';
      switch (e.code) {
        case 'user-not-found':
          message = 'No account found with this email.';
          break;
        case 'wrong-password':
          message = 'Incorrect password.';
          break;
        case 'invalid-credential':
          // Newer Firebase SDK combines wrong-password + user-not-found
          message = 'Incorrect email or password. Please try again.';
          break;
        case 'invalid-email':
          message = 'Invalid email address.';
          break;
        case 'user-disabled':
          message = 'This account has been disabled.';
          break;
        case 'too-many-requests':
          message = 'Too many attempts. Please try again later.';
          break;
        case 'network-request-failed':
          message = 'No internet connection. Please check your network.';
          break;
        default:
          message = e.message ?? 'An unknown error occurred.';
      }
      throw Exception(message);
    } catch (e) {
      throw Exception('An error occurred during login: $e');
    }
  }

  // Logout (handles both Firebase and local)
  Future<void> logout() async {
    // Save any pending data before logging out
    await DatabaseHelper.instance.clearUserData();

    if (!_isOfflineMode) {
      try {
        await _auth.signOut().timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('Firebase signout timeout/error: $e');
        // We continue anyway to clear local state
      }
    }

    // Explicitly clear any legacy offline session data from SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('sm_offline_user_email');
      await prefs.remove('sm_offline_user_display_name');
    } catch (e) {
      debugPrint('Error clearing offline preferences: $e');
    }

    _localUser = null;
    _isOfflineMode = false;

    // Notify listeners that the user has logged out
    _notifyListeners(false);
  }

  // Reset password (tries Firebase, falls back to message)
  Future<void> resetPassword(String email) async {
    debugPrint('AuthService: Requesting password reset for $email');
    
    if (!_isFirebaseInitialized) {
      debugPrint('AuthService: Cannot reset password - Firebase not initialized');
      throw 'Authentication service is currently unavailable. Please check your internet connection and try again.';
    }

    try {
      debugPrint('AuthService: Attempting standard password reset email for $email');
      
      // Using the most basic call to ensure delivery without ActionCodeSettings issues
      await _auth.sendPasswordResetEmail(email: email);
      
      debugPrint('AuthService: Firebase successfully accepted the reset request for $email');
    } on FirebaseAuthException catch (e) {
      debugPrint('AuthService: FirebaseAuthException during reset: ${e.code} - ${e.message}');
      if (e.code == 'user-not-found') {
        throw 'No account found with this email. Please check the address and try again.';
      } else if (e.code == 'network-request-failed') {
        throw 'Network error. Please check your internet connection.';
      } else if (e.code == 'too-many-requests') {
        throw 'Too many attempts. Please try again later.';
      } else {
        throw 'Error resetting password: ${e.message}';
      }
    } catch (e) {
      debugPrint('AuthService: Unexpected error during reset: $e');
      throw 'An unexpected error occurred while resetting your password. Please try again later.';
    }
  }
}
