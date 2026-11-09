// lib/screens/verify_email_screen.dart
//
// Shown to a logged-in user whose email address is not verified yet.
// They open the link we emailed them, come back, and continue to the app.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:newproject/services/auth_service.dart';

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen>
    with WidgetsBindingObserver {
  /// Wait between "Resend" taps so Firebase does not block us for sending
  /// too many emails.
  static const int _cooldownSeconds = 30;

  Timer? _timer;
  int _cooldown = _cooldownSeconds; // an email was just sent
  bool _checking = false;
  bool _resending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCooldown();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// When the user comes back to the app after opening the email, check
  /// automatically so they do not have to tap anything.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check(silent: true);
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = _cooldownSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_cooldown <= 1) {
        t.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown--);
      }
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _check({bool silent = false}) async {
    if (_checking) return;
    if (!silent) setState(() => _checking = true);
    try {
      final verified = await AuthService.refreshVerificationStatus();
      if (!mounted) return;
      if (verified) {
        Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false);
      } else if (!silent) {
        _snack('Not verified yet. Open the link in the email, then try again.');
      }
    } catch (e) {
      if (!silent) _snack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted && !silent) setState(() => _checking = false);
    }
  }

  Future<void> _resend() async {
    setState(() => _resending = true);
    try {
      await AuthService.sendVerificationEmail();
      _snack('Verification email sent. Check your inbox and spam folder.');
      _startCooldown();
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  Future<void> _logout() async {
    await AuthService.logout();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = FirebaseAuth.instance.currentUser?.email ?? 'your email';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your email'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.mark_email_unread_outlined,
                  size: 72,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Check your email',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  'We sent a verification link to',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  email,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  'Open the link in that email, then come back here. '
                      'If you do not see it, check your spam folder.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _checking ? null : () => _check(),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _checking
                      ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Text(
                    "I've verified my email",
                    style: TextStyle(fontSize: 16),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed:
                  (_cooldown > 0 || _resending) ? null : _resend,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(
                    _resending
                        ? 'Sending...'
                        : _cooldown > 0
                        ? 'Resend email (${_cooldown}s)'
                        : 'Resend email',
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Wrong email address? Log out and register again with the '
                      'correct one.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                TextButton(
                  onPressed: _logout,
                  child: const Text('Log out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}