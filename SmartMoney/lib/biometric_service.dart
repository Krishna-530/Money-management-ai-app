import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

class BiometricService {
  static final BiometricService instance = BiometricService._init();
  final LocalAuthentication _auth = LocalAuthentication();
  static const String _lockKey = 'biometric_lock_enabled';

  BiometricService._init();

  /// Check if the device has biometric hardware and it's enrolled
  Future<bool> get isBiometricAvailable async {
    try {
      final bool canAuthenticateWithBiometrics = await _auth.canCheckBiometrics;
      final bool canAuthenticate = canAuthenticateWithBiometrics || await _auth.isDeviceSupported();
      return canAuthenticate;
    } catch (e) {
      debugPrint('Error checking biometric availability: $e');
      return false;
    }
  }

  /// Get the list of available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e) {
      debugPrint('Error getting available biometrics: $e');
      return [];
    }
  }

  /// Get a user-friendly string describing the primary biometric type
  Future<String> getBiometricTypeLabel() async {
    final available = await getAvailableBiometrics();
    if (available.contains(BiometricType.face)) {
      if (available.contains(BiometricType.fingerprint)) {
        return 'Fingerprint / Face';
      }
      return 'Face ID / Facial Recognition';
    } else if (available.contains(BiometricType.fingerprint)) {
      return 'Fingerprint';
    } else if (available.contains(BiometricType.iris)) {
      return 'Iris Recognition';
    }
    return 'Biometric';
  }

  /// Get the current enabled state from SharedPreferences
  Future<bool> isLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_lockKey) ?? false;
  }

  /// Toggle the lock state
  Future<void> setLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lockKey, enabled);
  }

  /// Attempt to authenticate the user
  Future<bool> authenticate() async {
    try {
      final bool didAuthenticate = await _auth.authenticate(
        localizedReason: 'Please authenticate to access SmartBudget',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // Fallback to PIN/Passcode if biometrics fail
        ),
      );
      return didAuthenticate;
    } catch (e) {
      debugPrint('Biometric authentication error: $e');
      return false;
    }
  }
}
