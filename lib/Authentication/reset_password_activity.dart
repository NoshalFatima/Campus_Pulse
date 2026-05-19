import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ResetPasswordActivity extends StatefulWidget {
  const ResetPasswordActivity({super.key});

  @override
  State<ResetPasswordActivity> createState() => _ResetPasswordActivityState();
}

class _ResetPasswordActivityState extends State<ResetPasswordActivity> {
  final TextEditingController _emailController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _isLoading = false;

  // ── Reset Password Logic ───────────────────────────
  Future<void> _handleResetPassword() async {
    String email = _emailController.text.trim();

    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter your registered email")),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _auth.sendPasswordResetEmail(email: email);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Reset link sent to your email!")),
        );
        Navigator.pop(context); // Wapas Login screen par jane ke liye (Jaise Java mein finish() tha)
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? "Error occurred")),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const maroonColor = Color(0xFF8B0A1A);

    return Scaffold(
      backgroundColor: const Color(0xFFFDF2F3), // XML Background
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            children: [
              const SizedBox(height: 48),
              // App Logo
              Image.asset('assets/logo1.png', width: 120, height: 120),
              const SizedBox(height: 32),

              const Text(
                "Forgot Password?",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: maroonColor,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "Enter your email to receive reset link",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 32),

              // Email Input with Card Elevation (Jaise XML mein MaterialCardView tha)
              Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFFFBC02D), width: 2), // Yellow stroke
                ),
                child: TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    hintText: "Email Address",
                    filled: true,
                    fillColor: const Color(0xFFFDF2F3),
                    contentPadding: const EdgeInsets.all(16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none, // Card ka border use ho raha hai
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Loader (ProgressBar)
              if (_isLoading)
                const CircularProgressIndicator(color: maroonColor),

              const SizedBox(height: 12),

              // Send Reset Link Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleResetPassword,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: maroonColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    "Send Reset Link",
                    style: TextStyle(fontSize: 18, color: Colors.white),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Back to Login Link
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Text(
                  "Back to Login",
                  style: TextStyle(
                    color: maroonColor,
                    fontSize: 16,
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
}