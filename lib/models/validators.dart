
class Validators {
  static final RegExp _emailRegex =
  RegExp(r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$');

  static String? name(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Full name is required';
    if (value.length < 3) return 'Name must be at least 3 characters';
    if (!RegExp(r"^[\p{L}][\p{L}\p{M} .'\-]*$", unicode: true).hasMatch(value)) {
      return 'Name can only contain letters and spaces';
    }
    return null;
  }

  static String? email(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Email is required';
    if (!_emailRegex.hasMatch(value)) return 'Enter a valid email address';
    return null;
  }

  static String? phone(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Phone number is required';
    if (!RegExp(r'^\+?[0-9]{10,13}$').hasMatch(value)) {
      return 'Enter a valid phone number (10-13 digits)';
    }
    return null;
  }

  /// Login only checks presence/length; registration enforces strength.
  static String? loginPassword(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  static String? strongPassword(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < 8) return 'At least 8 characters required';
    if (!RegExp(r'[A-Z]').hasMatch(v)) return 'Add an uppercase letter';
    if (!RegExp(r'[a-z]').hasMatch(v)) return 'Add a lowercase letter';
    if (!RegExp(r'[0-9]').hasMatch(v)) return 'Add a number';
    if (!RegExp(r'[!@#$%^&*(),.?":{}|<>_\-]').hasMatch(v)) {
      return 'Add a special character';
    }
    return null;
  }

  static String? confirmPassword(String? v, String original) {
    if (v == null || v.isEmpty) return 'Please confirm your password';
    if (v != original) return 'Passwords do not match';
    return null;
  }
}
