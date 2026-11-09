import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:newproject/firebase_options.dart';
import 'package:newproject/screens/home_screen.dart';
import 'package:newproject/screens/login_screen.dart';
import 'package:newproject/screens/record_expense_screen.dart';
import 'package:newproject/screens/registration_screen.dart';
import 'package:newproject/screens/verify_email_screen.dart';
import 'package:newproject/services/auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Keep a copy of the user's data on the device so the app keeps working
  // without internet. Android already does this by default; this line makes
  // it explicit and also switches it on for the web (Chrome).
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
  );

  // Firebase remembers a logged-in user on the device. Wait for it to restore
  // that login (this works without internet), then open the right screen:
  // login, "verify your email", or home.
  await FirebaseAuth.instance.authStateChanges().first;

  runApp(MyApp(initialRoute: AuthService.startRoute));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.initialRoute});

  final String initialRoute;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
        ),
      ),
      initialRoute: initialRoute,
      routes: {
        '/login': (_) => const LoginScreen(),
        '/register': (_) => const RegisterScreen(),
        '/verify': (_) => const VerifyEmailScreen(),
        '/home': (_) => const HomeScreen(),
        '/record': (_) => const RecordExpenseScreen(),
      },
    );
  }
}