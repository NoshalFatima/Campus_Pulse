import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
class LoginActivity extends StatefulWidget {
  const LoginActivity({super.key});

  @override
  State<LoginActivity> createState() => _LoginActivityState();
}

class _LoginActivityState extends State<LoginActivity> {
  // Controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // Firebase instances
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  bool _obscurePassword = true;
  bool _isLoading = false;

  Future<void> _handleLogin() async {
    String email = _emailController.text.trim();
    String password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showToast("Please fill all fields");
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Sign In
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      User? user = userCredential.user;

      if (user != null) {
        // 2. Reload user for latest verification status
        await user.reload();
        user = _auth.currentUser;

        if (user != null && !user.emailVerified) {
          _showToast("Please verify your email first.");
          await _auth.signOut();
          setState(() => _isLoading = false);
        } else {
          // 3. Check Role in Firestore
          _checkUserRoleAndRedirect(user!.uid);
        }
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _isLoading = false);
      _showToast("Error: ${e.message}");
    }
  }

  Future<void> _checkUserRoleAndRedirect(String uid) async {
    try {
      DocumentSnapshot doc = await _db.collection("Users").doc(uid).get();

      setState(() => _isLoading = false);

     if (doc.exists) {
  String? oneSignalId;

  // ✅ CHECK IF RUNNING ON WEB OR MOBILE
  if (!kIsWeb) {
    try {
      // Mobile logic: SDK se ID nikalne ki koshish karein
      await OneSignal.login(uid); 
      oneSignalId = OneSignal.User.pushSubscription.id;

      // Retry logic for Mobile (Wait for ID)
      int retryCount = 0;
      while ((oneSignalId == null || oneSignalId.isEmpty) && retryCount < 3) {
        await Future.delayed(const Duration(seconds: 1));
        oneSignalId = OneSignal.User.pushSubscription.id;
        retryCount++;
      }
    } catch (e) {
      print("OneSignal Mobile error: $e");
    }
  } else {
    // ✅ WEB LOGIC: SDK ko skip karein taaki crash na ho
    oneSignalId = "WEB_USER"; // Ya aap khali chorna chahen to "" rakh den
    print("ℹ️ Web detected: OneSignal ID set to $oneSignalId");
  }
// ✅ SAVE TO FIRESTORE
await _db.collection("Users").doc(uid).update({
  "oneSignalId": oneSignalId ?? "",
});
        String? role = doc.get("role");
        String routeName = "";

        if (role?.toLowerCase() == "teacher") {
          // CNIC check for Teacher
          if (doc.data().toString().contains('cnic') && doc.get('cnic') != null) {
            routeName = '/faculty_dashboard';
          } else {
            routeName = '/faculty_signup';
          }
        } else if (role?.toLowerCase() == "student") {
          // regNo check for Student
          if (doc.data().toString().contains('regNo') && doc.get('regNo') != null) {
            routeName = '/student_dashboard';
          } else {
            routeName = '/student_signup';
          }
        }

        if (routeName.isNotEmpty) {
          Navigator.pushNamedAndRemoveUntil(context, routeName, (route) => false);
        } else {
          _showToast("Role not recognized.");
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showToast("Database Error: $e");
    }
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF2F3), // XML Background
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 48),
              // App Logo
              Image.asset(
                'assets/logo1.jpeg',
                width: 120,
                height: 120,
              ),
              const SizedBox(height: 32),
              // Login Text
              const Text(
                "Login",
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF8B0A1A), // Maroon
                ),
              ),
              const SizedBox(height: 32),

              // Email Input
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: "Email",
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
                ),
              ),
              const SizedBox(height: 16),

              // Password Input
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  hintText: "Password",
                  filled: true,
                  fillColor: Colors.white,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off : Icons.visibility,
                      color: const Color(0xFF8B0A1A),
                    ),
                    onPressed: () {
                      setState(() => _obscurePassword = !_obscurePassword);
                    },
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF8B0A1A)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF8B0A1A), width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Login Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B0A1A),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                      "Login",
                      style: TextStyle(fontSize: 18, color: Colors.white)
                  ),
                ),
              ),

              const SizedBox(height: 24),
              // Register Link
              GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/register'),
                child: const Text(
                  "Don't have an account? Register",
                  style: TextStyle(
                    color: Color(0xFF8B0A1A),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(height: 24),
              // Reset Password Link
              GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/reset_password'),
                child: const Text(
                  "Forget Password🙁",
                  style: TextStyle(
                    color: Color(0xFF8B0A1A),
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