import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
// Import lazmi karein taake dashboard load ho
import '../Faculty/Faculty_HomeDashboard.dart';
import '../chat/users_list_fragment.dart';
import '/Faculty/AnnouncementScreen.dart';
import 'faculty_attendance_module.dart';
import 'faculty_profile_screen.dart';
class FacultyDashBoard extends StatefulWidget {
  const FacultyDashBoard({super.key});

  @override
  State<FacultyDashBoard> createState() => _FacultyDashBoardState();
}

class _FacultyDashBoardState extends State<FacultyDashBoard> {
  final PageController _pageController = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedIndex = 0;

  final List<String> _titles = [
  "Dashboard", "Events", "Alerts", "Scan", "Chats", "Profile"
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
          // 1. FIXED VECTOR HEADER
          Positioned(
            top: 0, left: 0, right: 0,
            child: CustomPaint(
              size: Size(MediaQuery.of(context).size.width, 130),
              painter: HeaderCurvedPainter(),
            ),
          ),

          // 2. HEADER TOOLBAR
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
                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.power_settings_new, color: Colors.white),
                    onPressed: _showLogoutDialog,
                  ),
                ],
              ),
            ),
          ),

          // 3. FRAGMENTS (PageView)
          Padding(
            padding: const EdgeInsets.only(top: 80, bottom: 0),
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) => setState(() => _selectedIndex = index),
              children: [
                // Yahan by default ab FacultyHomeDashboard aayega
                FacultyHomeDashboard(parentPageController: _pageController),
                const Center(child: Text("Events/Announcements")),
                const AnnouncementFragment(),
                const TeacherAttendanceFragment(),
                const UsersListFragment(),
                const FacultyProfileScreen(),
              ],
            ),
          ),

          // 4. FLOATING BOTTOM BAR
          _buildFloatingBottomMenu(),
        ],
      ),
    );
  }

  // --- DRAWER & MENU UI (Same as before) ---
  Widget _buildDrawer() {
    return Drawer(
      child: Column(
        children: [
          const UserAccountsDrawerHeader(
            decoration: BoxDecoration(color: Color(0xFF8B0A1A)),
            accountName: Text("Faculty Member", style: TextStyle(fontSize: 18)),
            accountEmail: Text("Campus Pulse Pro"),
            currentAccountPicture: CircleAvatar(backgroundColor: Colors.white, child: Icon(Icons.person, color: Color(0xFF8B0A1A), size: 40)),
          ),
          ListTile(leading: const Icon(Icons.home), title: const Text("Home Dashboard"), onTap: () { Navigator.pop(context); _onItemTapped(0); }),
          ListTile(leading: const Icon(Icons.person), title: const Text("My Profile"), onTap: () { Navigator.pop(context); _onItemTapped(5); }),
          const Divider(),
          ListTile(leading: const Icon(Icons.logout, color: Colors.red), title: const Text("Logout"), onTap: () { Navigator.pop(context); _showLogoutDialog(); }),
        ],
      ),
    );
  }

  Widget _buildFloatingBottomMenu() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.fromLTRB(15, 0, 15, 5),
        height: 50,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 20, offset: const Offset(0, 10))],
          border: Border.all(color: const Color(0xFFF0F0F0)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _menuIcon(Icons.home, "Home", 0),
            _menuIcon(Icons.event, "Events", 1),
            _menuIcon(Icons.notifications, "Alerts", 2),
            _menuIcon(Icons.qr_code_scanner, "Scan", 3),
            _menuIcon(Icons.chat, "Chat", 4),
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
          Icon(icon, color: isSel ? const Color(0xFF8B0A1A) : Colors.grey, size: 24),
          Text(label, style: TextStyle(color: isSel ? const Color(0xFF8B0A1A) : Colors.grey, fontSize: 10)),
        ],
      ),
    );
  }

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Logout"),
        content: const Text("Are you Sure?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("No")),
          TextButton(onPressed: () async {
            await FirebaseAuth.instance.signOut();
            Navigator.pushReplacementNamed(context, '/login');
          }, child: const Text("Yes")),
        ],
      ),
    );
  }
}

// --- FIXED HEADER PAINTER (Match your XML exactly) ---
class HeaderCurvedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint();

    // Layer 1: Dark Maroon (#5A060D)
    paint.color = const Color(0xFF5A060D);
    Path p1 = Path();
    p1.lineTo(0, 0);
    p1.lineTo(size.width, 0);
    p1.lineTo(size.width, size.height * 0.85);
    // Is quadraticBezierTo ko aapke XML ke "C300,260 112,200 0,230" ke mutabiq set kiya hai
    p1.cubicTo(size.width * 0.75, size.height * 1.1, size.width * 0.25, size.height * 0.85, 0, size.height);
    p1.close();
    canvas.drawPath(p1, paint);

    // Layer 2: Main Maroon (#8B0A1A)
    paint.color = const Color(0xFF8B0A1A);
    Path p2 = Path();
    p2.lineTo(0, 0);
    p2.lineTo(size.width, 0);
    p2.lineTo(size.width, size.height * 0.7);
    p2.cubicTo(size.width * 0.75, size.height * 0.95, size.width * 0.25, size.height * 0.7, 0, size.height * 0.85);
    p2.close();
    canvas.drawPath(p2, paint);

    // Layer 3: Alpha Layer (#A11321, 0.3 Alpha)
    paint.color = const Color(0xFFA11321).withOpacity(0.3);
    Path p3 = Path();
    p3.lineTo(0, 0);
    p3.lineTo(size.width, 0);
    p3.lineTo(size.width, size.height * 0.55);
    p3.cubicTo(size.width * 0.75, size.height * 0.8, size.width * 0.25, size.height * 0.55, 0, size.height * 0.7);
    p3.close();
    canvas.drawPath(p3, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}