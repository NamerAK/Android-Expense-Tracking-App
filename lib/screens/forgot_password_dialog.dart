// lib/screens/forgot_password_dialog.dart
//
// "Forgot password?" dialog: asks for the email address and sends a Firebase
// password-reset email.

import 'package:flutter/material.dart';
import 'package:newproject/models/validators.dart';
import 'package:newproject/services/auth_service.dart';

/// Shows the dialog. [initialEmail] pre-fills the field (e.g. whatever the
/// user already typed on the login screen).
Future<void> showForgotPasswordDialog(
    BuildContext context, {
      String initialEmail = '',
    }) async {
  final sent = await showDialog<bool>(
    context: context,
    builder: (_) => _ForgotPasswordDialog(initialEmail: initialEmail),
  );

  if (sent == true && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'If an account exists for this email, a reset link has been sent. '
                'Check your inbox and spam folder.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
  }
}

class _ForgotPasswordDialog extends StatefulWidget {
  const _ForgotPasswordDialog({required this.initialEmail});

  final String initialEmail;

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailController;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await AuthService.sendPasswordReset(_emailController.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reset password'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your account email and we will send you a link to '
                  'choose a new password.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _emailController,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              enabled: !_sending,
              onFieldSubmitted: (_) => _send(),
              decoration: InputDecoration(
                labelText: 'Email',
                prefixIcon: const Icon(Icons.email_outlined),
                errorText: _error,
              ),
              validator: Validators.email,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: _sending
              ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
              : const Text('Send link'),
        ),
      ],
    );
  }
}