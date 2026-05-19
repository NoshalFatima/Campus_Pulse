import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
// Apne fragments yahan import karein
import 'student_home_fragment.dart';
import '../chat/users_list_fragment.dart';
import '../Student/student_announcement_screen.dart';
import '../Student/student_attendance_module.dart';
import '../Student/student_profile_screen.dart';
String name = "Student"; 
String email = "...";
class StudentDashboard extends StatefulWidget {
  const StudentDashboard({super.key});

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  final PageController _pageController = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedIndex = 0;

  // Titles for Toolbar
  final List<String> _titles = [
    "Campus Pulse",
    "Notifications",
    "Events",
    "Scanner",
    "Messages",
    "Profile"
  ];

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFFDF7F7),
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          // 1. EXACT XML CURVE HEADER
          Positioned(
            top: 0, left: 0, right: 0,
            child: CustomPaint(
              size: Size(MediaQuery.of(context).size.width, 130),
              painter: HeaderCurvedPainter(),
            ),
          ),

          // 2. CUSTOM TOOLBAR
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.menu, color: Colors.white, size: 28),
                    onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _titles[_selectedIndex],
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold
                    ),
                  ),
                  const Spacer(),
                  _buildNotificationIcon(),
                ],
              ),
            ),
          ),

          // 3. PAGEVIEW (FRAGMENTS)
          Padding(
            padding: const EdgeInsets.only(top: 90),
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) => setState(() => _selectedIndex = index),
              children: [
                // Home Fragment
                StudentHomeFragment(parentPageController: _pageController),

                // Placeholder Screens (Inko alag files mein banayein)
               
                const StudentAnnouncementFragment(),
                const Center(child: Text("Notifications Center")),
                const StudentAttendanceFragment(),
                const UsersListFragment(),
                const StudentProfileScreen(),
              ],
            ),
          ),

          // 4. FLOATING BOTTOM MENU
          _buildFloatingBottomMenu(),
        ],
      ),
    );
  }

  // --- UI COMPONENTS ---

  Widget _buildNotificationIcon() {
    return Stack(
      children: [
        IconButton(
          icon: const Icon(Icons.notifications_none, color: Colors.white, size: 28),
          onPressed: () => _onItemTapped(1),
        ),
        Positioned(
          right: 8, top: 8,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: const Color(0xFFFBC02D), borderRadius: BorderRadius.circular(10)),
            constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
            child: const Text('2', style: TextStyle(color: Colors.black, fontSize: 8, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          ),
        )
      ],
    );
  }

  Widget _buildFloatingBottomMenu() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.fromLTRB(15, 0, 15, 5),
        height: 70,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(25),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 15, offset: Offset(0, 5))],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _menuIcon(Icons.home_filled, "Home", 0),
            _menuIcon(Icons.notifications, "Alerts", 1),
            _menuIcon(Icons.event_available, "Events", 2),
            _menuIcon(Icons.qr_code_scanner, "Scan", 3),
            _menuIcon(Icons.chat_bubble, "Chat", 4),
            _menuIcon(Icons.person, "Profile", 5),
          ],
        ),
      ),
    );
  }

  Widget _menuIcon(IconData icon, String label, int index) {
    bool isSel = _selectedIndex == index;
    return InkWell(
      onTap: () => _onItemTapped(index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isSel ? const Color(0xFF8B0A1A) : Colors.grey, size: 26),
          if (isSel)
            Text(label, style: const TextStyle(color: Color(0xFF8B0A1A), fontSize: 10, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: Column(
        children: [
          const UserAccountsDrawerHeader(
            decoration: BoxDecoration(color: Color(0xFF8B0A1A)),
            accountName: Text("Student Name", style: TextStyle(fontWeight: FontWeight.bold)),
            accountEmail: Text("student@campus.edu"),
            currentAccountPicture: CircleAvatar(backgroundColor: Colors.white, child: Icon(Icons.person, color: Color(0xFF8B0A1A))),
          ),
          ListTile(leading: const Icon(Icons.settings), title: const Text("Settings"), onTap: () {}),
          const Spacer(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text("Logout"),
            onTap: () async {
              await FirebaseAuth.instance.signOut();
              Navigator.pushReplacementNamed(context, '/login');
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

// --- EXACT VECTOR XML TO CUSTOM PAINTER ---

class HeaderCurvedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    double w = size.width;
    double h = size.height;
    Paint paint = Paint()..style = PaintingStyle.fill;

    // Layer 1: Dark Maroon (#5A060D)
    paint.color = const Color(0xFF5A060D);
    Path p1 = Path();
    p1.moveTo(0, 0);
    p1.lineTo(w, 0);
    p1.lineTo(w, h * (210 / 230));
    p1.cubicTo(w * (300 / 412), h * (260 / 230), w * (112 / 412), h * (200 / 230), 0, h);
    p1.close();
    canvas.drawPath(p1, paint);

    // Layer 2: Main Maroon (#8B0A1A)
    paint.color = const Color(0xFF8B0A1A);
    Path p2 = Path();
    p2.moveTo(0, 0);
    p2.lineTo(w, 0);
    p2.lineTo(w, h * (170 / 230));
    p2.cubicTo(w * (300 / 412), h * (220 / 230), w * (112 / 412), h * (160 / 230), 0, h * (190 / 230));
    p2.close();
    canvas.drawPath(p2, paint);

    // Layer 3: Alpha Layer (#A11321)
    paint.color = const Color(0xFFA11321).withOpacity(0.15);
    Path p3 = Path();
    p3.moveTo(0, 0);
    p3.lineTo(w, 0);
    p3.lineTo(w, h * (130 / 230));
    p3.cubicTo(w * (300 / 412), h * (180 / 230), w * (112 / 412), h * (120 / 230), 0, h * (150 / 230));
    p3.close();
    canvas.drawPath(p3, paint);

    // Layer 4: Yellow Stroke Line (#FBC02D)
    Paint strokePaint = Paint()
      ..color = const Color(0xFFFBC02D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    Path strokePath = Path();
    strokePath.moveTo(0, h * (182 / 230));
    strokePath.cubicTo(w * (112 / 412), h * (152 / 230), w * (300 / 412), h * (212 / 230), w, h * (162 / 230));
    canvas.drawPath(strokePath, strokePaint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}