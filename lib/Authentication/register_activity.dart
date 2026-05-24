import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class RegisterActivity extends StatefulWidget {
  const RegisterActivity({super.key});

  @override
  State<RegisterActivity> createState() => _RegisterActivityState();
}

class _RegisterActivityState extends State<RegisterActivity> {
  // Controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // State variables
  String _selectedRole = "Select Role";
  bool _isLoading = false;
  final List<String> _roles = ["Select Role", "Student", "Teacher"];

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── Validation & Register Logic ───────────────────────────
  Future<void> _handleRegister() async {
    String email = _emailController.text.trim();
    String password = _passwordController.text.trim();

    // 1. Basic Validation
    if (email.isEmpty) {
      _showSnackBar("Email required!");
      return;
    }
    if (password.isEmpty) {
      _showSnackBar("Password required!");
      return;
    }
    if (_selectedRole == "Select Role") {
      _showSnackBar("Please select a role");
      return;
    }

    // 2. Strong Password Validation (Same as your Java logic)
    if (password.length < 6 ||
        !password.contains(RegExp(r'[A-Z]')) ||
        !password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'))) {
      _showSnackBar("Password: 6+ chars, 1 Uppercase & 1 Special char.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 3. Create User in Firebase Auth
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      User? user = userCredential.user;

      if (user != null) {
        // 4. Save User Data in Firestore
        await _db.collection("Users").doc(user.uid).set({
          "email": email,
          "role": _selectedRole, // "Student" or "Teacher"
        });

        // 5. Send Verification Email
        await user.sendEmailVerification();

        _showSnackBar("Verification email sent. Check inbox.");

        // 6. Sign out and go to Login
        await _auth.signOut();
        if (mounted) {
          Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
        }
      }
    } on FirebaseAuthException catch (e) {
      _showSnackBar("Error: ${e.message}");
    } catch (e) {
      _showSnackBar("Firestore Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
              Image.asset('assets/logo1.jpeg', width: 120, height: 120),
              const SizedBox(height: 32),

              const Text(
                "Register",
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: maroonColor,
                ),
              ),
              const SizedBox(height: 32),

              // Email Field
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: _inputDecoration("Email"),
              ),
              const SizedBox(height: 16),

              // Password Field
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: _inputDecoration("Password"),
              ),
              const SizedBox(height: 24),

              // Role Spinner (Dropdown in Flutter)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: maroonColor),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedRole,
                    isExpanded: true,
                    items: _roles.map((String role) {
                      return DropdownMenuItem(value: role, child: Text(role));
                    }).toList(),
                    onChanged: (value) {
                      setState(() => _selectedRole = value!);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Register Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleRegister,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: maroonColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Register", style: TextStyle(fontSize: 18, color: Colors.white)),
                ),
              ),

              // Login Link
              const SizedBox(height: 24),
              GestureDetector(
                onTap: () => Navigator.pop(context), // Wapis login par
                child: const Text(
                  "Already have an account? Login",
                  style: TextStyle(color: maroonColor, fontSize: 16, fontWeight: FontWeight.bold),
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
      hintText: hint,
      filled: true,
      fillColor: Colors.white,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF8B0A1A)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF8B0A1A), width: 2),
      ),
    );
  }
}