import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
// User list fragment ka link

class StudentHomeFragment extends StatefulWidget {
  final PageController parentPageController;

  const StudentHomeFragment({super.key, required this.parentPageController});

  @override
  State<StudentHomeFragment> createState() => _StudentHomeFragmentState();
}

class _StudentHomeFragmentState extends State<StudentHomeFragment> {
  String fullName = "Loading...";
  String deptInfo = "Department - Semester";
  String profileUrl = "";
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStudentData();
  }

 void _loadStudentData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        // ✅ STEP 1: Use GetOptions to check Cache FIRST, then Server
        final doc = await FirebaseFirestore.instance
            .collection("Users")
            .doc(user.uid)
            .get(const GetOptions(source: Source.serverAndCache));

        if (doc.exists && mounted) {
          setState(() {
            fullName = doc.data()?['name'] ?? "Student Name";
            String dept = doc.data()?['dept'] ?? "Dept";
            String sem = doc.data()?['semester'] ?? "Sem";
            deptInfo = "$dept - Semester $sem";
            profileUrl = doc.data()?['profilePic'] ?? "";
            isLoading = false;
          });
        }
      } catch (e) {
        debugPrint("Offline/Fetch Error: $e");
        
        // ✅ STEP 2: Fallback to STRICT Cache if ServerAndCache throws an error
        try {
          final cacheDoc = await FirebaseFirestore.instance
              .collection("Users")
              .doc(user.uid)
              .get(const GetOptions(source: Source.cache));
          
          if (cacheDoc.exists && mounted) {
            setState(() {
              fullName = cacheDoc.data()?['name'] ?? "Student Name";
              profileUrl = cacheDoc.data()?['profilePic'] ?? "";
              isLoading = false;
            });
          }
        } catch (cacheError) {
          setState(() => isLoading = false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {

    // Laptop check karne ke liye variable
    double screenWidth = MediaQuery.of(context).size.width;
    bool isLaptop = screenWidth > 800;

    return LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            children: [
              // 1. DYNAMIC PROFILE SECTION (Top Spacing adjusted for Laptop)
              SizedBox(height: isLaptop ? 60 : 20),
              _buildOverlappingProfile(isLaptop),

              const SizedBox(height: 10),

              // 2. SCROLLABLE GRID SECTION
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(horizontal: isLaptop ? 40 : 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          "Quick Access",
                          style: TextStyle(
                            color: Color(0xFF8B0A1A),
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),

                      // RESPONSIVE GRID
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: 6,
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: isLaptop ? 350 : 250,
                          mainAxisSpacing: 15,
                          crossAxisSpacing: 15,
                          childAspectRatio: isLaptop ? 1.8 : 1.4,
                        ),
                        itemBuilder: (context, index) {
                          List<Map<String, dynamic>> items = [
                            {"index": 0, "icon": Icons.home, "title": "Home"},
                            {"index": 2, "icon": Icons.event, "title": "Events"},
                            {"index": 5, "icon": Icons.person, "title": "Profile"},
                            {"index": 4, "icon": Icons.chat, "title": "Chat", "isChat": true},
                            {"index": 1, "icon": Icons.notifications, "title": "Alerts"},
                            {"index": 3, "icon": Icons.qr_code_scanner, "title": "Attendance"},
                          ];
                          return _buildGridCard(items[index]);
                        },
                      ),
                      const SizedBox(height: 110),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
    );
  }

  Widget _buildOverlappingProfile(bool isLaptop) {
    return Container(
     
      width: isLaptop ? 700 : double.infinity, // Laptop pe card ko boht phailne se bachaya
      height: 180,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // THE CURVED CARD (Exact Theme Match)
          Container(
            margin: const EdgeInsets.only(top: 45),
            width: double.infinity,
            height: 150,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                children: [
                  CustomPaint(
                    size: const Size(double.infinity, 170),
                    painter: ProfileCardPainter(),
                  ),
                  Positioned.fill(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 40),
                        Text(
                          fullName,
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          deptInfo,
                          style: const TextStyle(color: Color(0xFFFFCDD2), fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // PROFILE PICTURE (Cloudinary)
          Positioned(
            
            child: Container(
              width: 95,
              height: 95,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFFBC02D), width: 3),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)],
              ),
              child: ClipOval(
                child: profileUrl.isNotEmpty
                    ? CachedNetworkImage(
                  imageUrl: profileUrl,
                  placeholder: (context, url) => const Center(child: CircularProgressIndicator(color: Color(0xFF8B0A1A))),
                  errorWidget: (context, url, error) => const Icon(Icons.person, size: 50, color: Colors.grey),
                  fit: BoxFit.cover,
                )
                    : Container(color: Colors.white, child: const Icon(Icons.person, size: 50, color: Colors.grey)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridCard(Map<String, dynamic> item) {
    return GestureDetector(
      onTap: () {
        if (item["isChat"] == true) {
          // Navigating to User List (ChatListFragment) instead of direct chat
          widget.parentPageController.animateToPage(
              item["index"],
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut
          );
        } else {
          widget.parentPageController.animateToPage(
              item["index"],
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut
          );
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFF0F0F0), width: 1.5),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 5))
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF8B0A1A).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(item["icon"], color: const Color(0xFF8B0A1A), size: 28),
            ),
            const SizedBox(height: 10),
            Text(
              item["title"],
              style: const TextStyle(color: Color(0xFF8B0A1A), fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// --- EXACT CURVE DESIGN FOR PROFILE CARD ---

class ProfileCardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    double w = size.width;
    double h = size.height;
    Paint paint = Paint()..style = PaintingStyle.fill;

    // Layer 1: Dark Maroon (Matching Main Header)
    paint.color = const Color(0xFF5A060D);
    Path p1 = Path();
    p1.lineTo(w, 0); p1.lineTo(w, h * 0.9);
    p1.cubicTo(w * 0.75, h * 1.15, w * 0.25, h * 0.85, 0, h);
    p1.close();
    canvas.drawPath(p1, paint);

    // Layer 2: Main Maroon
    paint.color = const Color(0xFF8B0A1A);
    Path p2 = Path();
    p2.lineTo(w, 0); p2.lineTo(w, h * 0.7);
    p2.cubicTo(w * 0.75, h * 0.95, w * 0.25, h * 0.7, 0, h * 0.85);
    p2.close();
    canvas.drawPath(p2, paint);

    // Layer 3: Yellow Line (Exact XML Match)
    Paint sPaint = Paint()
      ..color = const Color(0xFFFBC02D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    Path sPath = Path();
    sPath.moveTo(0, h * 0.8);
    sPath.cubicTo(w * 0.25, h * 0.65, w * 0.75, h * 0.95, w, h * 0.7);
    canvas.drawPath(sPath, sPaint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}