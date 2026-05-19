import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async'; // StreamSubscription ke liye

class LauncherActivity extends StatefulWidget {
  const LauncherActivity({super.key});

  @override
  State<LauncherActivity> createState() => _LauncherActivityState();
}

class _LauncherActivityState extends State<LauncherActivity> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  StreamSubscription<User?>? _authListener;

  @override
  void initState() {
    super.initState();
    _setupFirestore();

    // ⭐ Refresh handle karne ke liye Stream use karein
    _checkAuthStatus();
  }

  void _setupFirestore() {
    _db.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
  }

  void _checkAuthStatus() {
    // Web par currentUser foran nahi milta, isliye listener lagaya hai
    _authListener = _auth.authStateChanges().listen((User? user) {
      if (!mounted) return;

      if (user == null) {
        // User waqai login nahi hai
        _goToLogin();
      } else {
        // User mil gaya (Cache se), ab profile check karo
        _fetchUserProfileAndRoute(user.uid);
      }
    });
  }

 Future<void> _fetchUserProfileAndRoute(String uid) async {
  try {
    // ✅ FIX: Explicitly tell Firestore to use Cache + Server
    // This prevents the 'catch' block from triggering just because there's no net.
    DocumentSnapshot doc = await _db.collection("Users").doc(uid).get(
      const GetOptions(source: Source.serverAndCache) 
    );

    if (doc.exists) {
      _routeUserByRole(doc);
    } else {
      // User doesn't exist in DB at all
      await _auth.signOut();
      _goToLogin();
    }
  } catch (e) {
    debugPrint("Firestore Error: $e");
    
    // ❌ OLD LOGIC: _goToLogin(); // This was kicking offline users out!
    
    // ✅ NEW LOGIC: Try to get data strictly from Cache before giving up
    try {
      DocumentSnapshot cacheDoc = await _db.collection("Users").doc(uid).get(const GetOptions(source: Source.cache));
      if (cacheDoc.exists) {
        _routeUserByRole(cacheDoc);
      } else {
        _goToLogin();
      }
    } catch (cacheError) {
      // If even cache fails, then they must login
      _goToLogin();
    }
  }
}

  void _routeUserByRole(DocumentSnapshot doc) {
    String? role = doc.get("role");

    if (role == null) {
      _goToLogin();
      return;
    }

    String lowerRole = role.toLowerCase();

    if (lowerRole == "student") {
      if (_isStudentProfileComplete(doc)) {
        _navigateTo('/student_dashboard');
      } else {
        _sendToProfileSetup('/student_signup', "Complete your student profile.");
      }
    } else if (lowerRole == "teacher" || lowerRole == "faculty") {
      if (_isFacultyProfileComplete(doc)) {
        _navigateTo('/faculty_dashboard');
      } else {
        _sendToProfileSetup('/faculty_signup', "Complete your faculty profile.");
      }
    }
  }

  // Java logic matching
  bool _isStudentProfileComplete(DocumentSnapshot snapshot) {
    var data = snapshot.data() as Map<String, dynamic>;
    return data.containsKey("registrationNo") || data.containsKey("regNo");
  }

  bool _isFacultyProfileComplete(DocumentSnapshot snapshot) {
    var data = snapshot.data() as Map<String, dynamic>;
    // Faculty ke liye CNIC ya Dept zaroori hai
    return data.containsKey("cnic") || data.containsKey("dept");
  }

  // --- Navigation Helpers ---
  void _navigateTo(String routeName) {
    if (mounted) {
      // Listener cancel karna zaroori hai taake loop na bany
      _authListener?.cancel();
      Navigator.pushNamedAndRemoveUntil(context, routeName, (route) => false);
    }
  }

  void _goToLogin() {
    _navigateTo('/login');
  }

  void _sendToProfileSetup(String routeName, String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      _navigateTo(routeName);
    }
  }

  @override
  void dispose() {
    _authListener?.cancel(); // Memory leak se bachne ke liye
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF2F3),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/logo1.jpeg',
              width: 200, height: 200,
              errorBuilder: (context, error, stackTrace) =>
              const Icon(Icons.school, size: 100, color: Color(0xFF8B0A1A)),
            ),
            const SizedBox(height: 20),
            const CircularProgressIndicator(color: Color(0xFF8B0A1A)),
          ],
        ),
      ),
    );
  }
}