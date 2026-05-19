import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
// Is package ko install karlein: flutter pub add cached_network_image
import 'package:cached_network_image/cached_network_image.dart';

class FacultyHomeDashboard extends StatefulWidget {
  final PageController parentPageController;

  const FacultyHomeDashboard({super.key, required this.parentPageController});

  @override
  State<FacultyHomeDashboard> createState() => _FacultyHomeDashboardState();
}

class _FacultyHomeDashboardState extends State<FacultyHomeDashboard> {
  String name = "Loading...";
  String dept = "Loading...";
  String profileUrl = ""; // Cloudinary URL yahan store hoga
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTeacherData();
  }

  // Cloudinary URL fetch karne ka logic
  void _loadTeacherData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection("Users")
            .doc(user.uid)
            .get();

        if (doc.exists) {
          setState(() {
            name = doc.data()?['name'] ?? "Faculty Member";
            dept = doc.data()?['dept'] ?? "Department";
            // Signup code mein humne "profilePic" key use ki thi
            profileUrl = doc.data()?['profilePic'] ?? "";
            isLoading = false;
          });
        }
      } catch (e) {
        print("Error loading data: $e");
        setState(() => isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // 1. TOP PROFILE CARD
          _buildProfileCard(),

          // 2. SCROLLABLE MENU
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Main Dashboard",
                    style: TextStyle(
                        color: Color(0xFF8B0A1A),
                        fontSize: 17,
                        fontWeight: FontWeight.bold
                    ),
                  ),
                  const SizedBox(height: 16),

                  _buildMenuCard(0, Icons.home, "Home Dashboard", "Overview of your activities"),
                  _buildMenuCard(1, Icons.event, "Campus Events", "Upcoming news and functions"),
                  _buildMenuCard(2, Icons.notifications, "Notifications & Alerts", "Stay updated with university notices"),
                  _buildMenuCard(3, Icons.qr_code_scanner, "Attendance Scanner", "Scan QR for student presence"),
                  _buildMenuCard(4, Icons.chat, "Messages", "Discussion with students & staff"),
                  _buildMenuCard(5, Icons.person, "My Profile", "Edit and manage your account"),

                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      height: 140,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF8B0A1A), Color(0xFF5A060D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFFBC02D), width: 2.5),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 4)
          )
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 20),

          // CLOUDINARY IMAGE LOGIC
          Container(
            width: 75,
            height: 75,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFFBC02D), width: 2),
            ),
            child: ClipOval(
              child: profileUrl.isNotEmpty
                  ? CachedNetworkImage(
                imageUrl: profileUrl,
                placeholder: (context, url) => const CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                errorWidget: (context, url, error) => const Icon(Icons.person, size: 40, color: Colors.white),
                fit: BoxFit.cover,
              )
                  : Image.asset("assets/profile.png", fit: BoxFit.cover), // Default image
            ),
          ),

          const SizedBox(width: 15),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                Text(dept, style: const TextStyle(color: Color(0xFFFFCDD2), fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuCard(int index, IconData icon, String title, String subtitle) {
    return GestureDetector(
      onTap: () => widget.parentPageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        height: 85,
        decoration: BoxDecoration(
          color: const Color(0xFFFFF5F6),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFFBC02D), width: 1.5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF8B0A1A).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: const Color(0xFF8B0A1A), size: 30),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Color(0xFF2C2C2C), fontSize: 15, fontWeight: FontWeight.bold)),
                  Text(subtitle, style: const TextStyle(color: Color(0xFF8C8C8C), fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 14, color: Color(0xFF8B0A1A)),
          ],
        ),
      ),
    );
  }
}