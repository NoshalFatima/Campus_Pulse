import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// ✅ Only OneSignalService — no direct onesignal_flutter import needed here
import '../services/onesignal_service.dart';

class LoginActivity extends StatefulWidget {
  const LoginActivity({super.key});

  @override
  State<LoginActivity> createState() => _LoginActivityState();
}

class _LoginActivityState extends State<LoginActivity> {
  final TextEditingController _emailController    = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final FirebaseAuth      _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db   = FirebaseFirestore.instance;

  bool _obscurePassword = true;
  bool _isLoading       = false;

  // ─────────────────────────────────────────────────────────────────────────
  // HANDLE LOGIN
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _handleLogin() async {
    final email    = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showToast("Please fill all fields");
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Firebase sign-in
      final userCredential = await _auth.signInWithEmailAndPassword(
        email   : email,
        password: password,
      );

      User? user = userCredential.user;
      if (user == null) {
        setState(() => _isLoading = false);
        return;
      }

      // 2. Reload for latest email verification status
      await user.reload();
      user = _auth.currentUser;

      if (user == null) {
        setState(() => _isLoading = false);
        return;
      }

      if (!user.emailVerified) {
        _showToast("Please verify your email first.");
        await _auth.signOut();
        setState(() => _isLoading = false);
        return;
      }

      // 3. ✅ OneSignal login — right after Firebase sign-in, before navigation
      //    Mobile: links device to Firebase UID → sub ID saves to Firestore via observer
      //    Web:    early return inside service (REST API handles everything)
      await OneSignalService.loginUser(user.uid);

      // 4. Check role and navigate
      await _checkUserRoleAndRedirect(user.uid);

    } on FirebaseAuthException catch (e) {
      setState(() => _isLoading = false);
      _showToast("Error: ${e.message}");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ROLE CHECK + REDIRECT
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _checkUserRoleAndRedirect(String uid) async {
    try {
      final doc = await _db.collection("Users").doc(uid).get();

      setState(() => _isLoading = false);

      if (!doc.exists) {
        _showToast("User data not found.");
        return;
      }

      final data = doc.data() ?? {};
      final role = (data['role'] as String?)?.toLowerCase() ?? '';

      String routeName = '';

      if (role == 'teacher') {
        routeName = (data['cnic'] != null && data['cnic'].toString().isNotEmpty)
            ? '/faculty_dashboard'
            : '/faculty_signup';
      } else if (role == 'student') {
        routeName = (data['regNo'] != null && data['regNo'].toString().isNotEmpty)
            ? '/student_dashboard'
            : '/studentsignupactivity';
      }

      if (routeName.isNotEmpty) {
        if (!mounted) return;
        Navigator.pushNamedAndRemoveUntil(context, routeName, (route) => false);
      } else {
        _showToast("Role not recognized.");
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showToast("Database Error: $e");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────

  void _showToast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF2F3),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 48),

              Image.asset('assets/logo1.jpeg', width: 120, height: 120),

              const SizedBox(height: 32),

              const Text(
                "Login",
                style: TextStyle(
                  fontSize      : 32,
                  fontWeight    : FontWeight.bold,
                  color         : Color(0xFF8B0A1A),
                ),
              ),

              const SizedBox(height: 32),

              // Email
              TextField(
                controller  : _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration  : _inputDecoration("Email"),
              ),

              const SizedBox(height: 16),

              // Password
              TextField(
                controller : _passwordController,
                obscureText: _obscurePassword,
                decoration : _inputDecoration("Password").copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off : Icons.visibility,
                      color: const Color(0xFF8B0A1A),
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Login button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B0A1A),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Login",
                          style: TextStyle(fontSize: 18, color: Colors.white)),
                ),
              ),

              const SizedBox(height: 24),

              GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/register'),
                child: const Text(
                  "Don't have an account? Register",
                  style: TextStyle(
                    color     : Color(0xFF8B0A1A),
                    fontSize  : 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/reset_password'),
                child: const Text(
                  "Forget Password🙁",
                  style: TextStyle(
                    color     : Color(0xFF8B0A1A),
                    fontSize  : 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText  : hint,
      filled    : true,
      fillColor : Colors.white,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide  : const BorderSide(color: Color(0xFF8B0A1A)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide  : const BorderSide(color: Color(0xFF8B0A1A), width: 2),
      ),
    );
  }
}