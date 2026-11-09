// lib/services/auth_service.dart
//
// Replaces the placeholder AuthService with real Firebase Authentication.
// Before using: in Firebase Console > Authentication > Sign-in method,
// enable "Email/Password".

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Signs the user in. Throws an Exception with a readable message on failure
  /// (your login screen already shows e.toString() in a snackbar).
  static Future<void> login(String email, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw Exception(_message(e));
    }
  }

  /// Creates a new account and signs the user in automatically.
  static Future<void> register({
    required String name,
    required String email,
    required String phone,
    required String password,
  }) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      await cred.user?.updateDisplayName(name.trim());

      // Ask the user to confirm their email address. A failure here must not
      // undo the registration: the user can request another email later.
      try {
        await cred.user?.sendEmailVerification();
      } catch (e) {
        debugPrint('Verification email failed: $e');
      }

      // Save the extra profile details. Not awaited so a slow or offline
      // connection never makes a successful registration look like a failure.
      final uid = cred.user?.uid;
      if (uid != null) {
        _db.collection('users').doc(uid).set({
          'name': name.trim(),
          'email': email.trim(),
          'phone': phone.trim(),
          'createdAt': FieldValue.serverTimestamp(),
        }).catchError((Object e) {
          debugPrint('Profile save failed: $e');
        });
      }
    } on FirebaseAuthException catch (e) {
      throw Exception(_message(e));
    }
  }

  /// Sends a password-reset email. Needs an internet connection.
  ///
  /// For privacy, an unknown email address is treated like a success, so the
  /// app never reveals which emails have accounts.
  static Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') return;
      throw Exception(_message(e));
    }
  }

  // ---------------------------------------------------------------------------
  // Email verification
  // ---------------------------------------------------------------------------

  /// Where the app should open for the current login state:
  ///   no user                  -> '/login'
  ///   user, email not verified -> '/verify'
  ///   user, email verified     -> '/home'
  /// The verified flag is stored on the device, so this works offline.
  static String get startRoute {
    final user = _auth.currentUser;
    if (user == null) return '/login';
    return user.emailVerified ? '/home' : '/verify';
  }

  /// Sends (or re-sends) the verification email to the logged-in user.
  static Future<void> sendVerificationEmail() async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Please log in first');
    try {
      await user.sendEmailVerification();
    } on FirebaseAuthException catch (e) {
      throw Exception(_message(e));
    }
  }

  /// Asks Firebase whether the user has opened the link yet. Returns true
  /// once the email is verified. Needs an internet connection.
  static Future<bool> refreshVerificationStatus() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
      final fresh = _auth.currentUser;
      if (fresh != null && fresh.emailVerified) {
        // Refresh the login token so server-side rules see the verified flag.
        await fresh.getIdToken(true);
        return true;
      }
      return false;
    } on FirebaseAuthException catch (e) {
      throw Exception(_message(e));
    }
  }

  /// Signs the current user out of Firebase.
  static Future<void> logout() => _auth.signOut();

  static String _message(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'Invalid email or password';
      case 'invalid-email':
        return 'Please enter a valid email address';
      case 'user-disabled':
        return 'This account has been disabled';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later';
      case 'network-request-failed':
        return 'No internet connection. Please try again';
      case 'email-already-in-use':
        return 'An account with this email already exists';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters';
      case 'operation-not-allowed':
        return 'Email/password sign-in is not enabled in Firebase';
      default:
        return e.message ?? 'Something went wrong. Please try again';
    }
  }
}