import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'student_view_attendance.dart';

class StudentHomeFragment extends StatefulWidget {
  final PageController parentPageController;
  const StudentHomeFragment({super.key, required this.parentPageController});

  @override
  State<StudentHomeFragment> createState() => _StudentHomeFragmentState();
}

class _StudentHomeFragmentState extends State<StudentHomeFragment> {
  String fullName    = "Loading...";
  String deptInfo    = "Department - Semester";
  String profileUrl  = "";
  bool   isLoading   = true;

  // Attendance stats
  double _attPct      = 0;
  int    _attPresent  = 0;
  int    _attTotal    = 0;
  bool   _attLoading  = true;

  String _classPath = '';
  String _uid       = '';

  @override
  void initState() {
    super.initState();
    _loadStudentData();
  }

  void _loadStudentData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _uid = user.uid;
      try {
        final doc = await FirebaseFirestore.instance
            .collection("Users")
            .doc(user.uid)
            .get(const GetOptions(source: Source.serverAndCache));

        if (doc.exists && mounted) {
          final d    = doc.data()!;
          final dept  = d['dept']?.toString()     ?? '';
          final sem   = d['semester']?.toString() ?? d['sem']?.toString() ?? '';
          final shift = d['shift']?.toString()    ?? '';

          final dk = dept.trim().replaceAll(' ', '_').toUpperCase();
          final sn = sem.replaceAll(RegExp(r'[^0-9]'), '');
          final sk = shift.trim().toUpperCase();
          _classPath = '${dk}_S${sn}_$sk';

          setState(() {
            fullName   = d['name']     ?? "Student Name";
            deptInfo   = "$dept - Semester $sem";
            profileUrl = d['profilePic'] ?? "";
            isLoading  = false;
          });

          _loadAttendance();
        }
      } catch (e) {
        debugPrint("Fetch Error: $e");
        try {
          final cacheDoc = await FirebaseFirestore.instance
              .collection("Users")
              .doc(user.uid)
              .get(const GetOptions(source: Source.cache));
          if (cacheDoc.exists && mounted) {
            setState(() {
              fullName   = cacheDoc.data()?['name']       ?? "Student Name";
              profileUrl = cacheDoc.data()?['profilePic'] ?? "";
              isLoading  = false;
            });
          }
        } catch (_) {
          setState(() => isLoading = false);
        }
      }
    }
  }

  Future<void> _loadAttendance() async {
    if (_classPath.isEmpty || _uid.isEmpty) return;
    try {
      final snap = await rtdb.FirebaseDatabase.instance
          .ref('AttendanceRecords/$_classPath')
          .get();

      int present = 0, total = 0;

      if (snap.exists && snap.value != null) {
        final classData = Map<String, dynamic>.from(snap.value as Map);
        classData.forEach((subjectKey, subjectData) {
          if (subjectData is! Map) return;
          final dateMap = Map<String, dynamic>.from(subjectData);
          dateMap.forEach((date, dateData) {
            if (dateData is! Map) return;
            final dayMap = Map<String, dynamic>.from(dateData);
            if (dayMap.containsKey(_uid)) {
              total++;
              final status = (dayMap[_uid] is Map
                  ? dayMap[_uid]['status']
                  : dayMap[_uid])?.toString() ?? '';
              if (status == 'Present') present++;
            }
          });
        });
      }

      if (mounted) {
        setState(() {
          _attPresent = present;
          _attTotal   = total;
          _attPct     = total == 0 ? 0 : present / total * 100;
          _attLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Attendance load: $e');
      if (mounted) setState(() => _attLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isLaptop    = screenWidth > 800;

    return LayoutBuilder(builder: (context, constraints) {
      return Column(children: [
        SizedBox(height: isLaptop ? 60 : 20),
        _buildOverlappingProfile(isLaptop),
        const SizedBox(height: 10),
        Expanded(child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
              horizontal: isLaptop ? 40 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Attendance progress card ──────────────────
              _buildAttendanceCard(),
              const SizedBox(height: 6),

              // ── Quick Access ──────────────────────────────
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text("Quick Access",
                  style: TextStyle(color: Color(0xFF8B0A1A),
                      fontSize: 18, fontWeight: FontWeight.bold)),
              ),
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
                  final items = [
                    {"index": 0, "icon": Icons.home,               "title": "Home"},
                    {"index": 2, "icon": Icons.event,              "title": "Events"},
                    {"index": 5, "icon": Icons.person,             "title": "Profile"},
                    {"index": 4, "icon": Icons.chat,               "title": "Chat",       "isChat": true},
                    {"index": 1, "icon": Icons.notifications,      "title": "Alerts"},
                    {"index": 3, "icon": Icons.qr_code_scanner,    "title": "Attendance"},
                  ];
                  return _buildGridCard(items[index]);
                },
              ),
              const SizedBox(height: 110),
            ],
          ),
        )),
      ]);
    });
  }

  // ── Attendance progress card ──────────────────────────────────
  Widget _buildAttendanceCard() {
    final color = _attPct >= 75
        ? const Color(0xFF2E7D32)
        : _attPct >= 50
            ? const Color(0xFFE65100)
            : const Color(0xFFC62828);

    final bgColor = _attPct >= 75
        ? const Color(0xFFE8F5E9)
        : _attPct >= 50
            ? const Color(0xFFFFF3E0)
            : const Color(0xFFFFEBEE);

    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(
              builder: (_) => const StudentViewAttendance())),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
              color: const Color(0xFFFBC02D), width: 1.5),
          boxShadow: [BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: _attLoading
            ? const SizedBox(
                height: 60,
                child: Center(child: CircularProgressIndicator(
                    color: Color(0xFF8B0A1A), strokeWidth: 2)))
            : Column(children: [
                // Title row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF8B0A1A).withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.bar_chart_rounded,
                            color: Color(0xFF8B0A1A), size: 20),
                      ),
                      const SizedBox(width: 10),
                      const Text('Attendance Overview',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Color(0xFF8B0A1A))),
                    ]),
                    // Percentage badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: color.withOpacity(0.3)),
                      ),
                      child: Text(
                        '${_attPct.toStringAsFixed(0)}%',
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 15),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // Progress bar
                Stack(children: [
                  // Background
                  Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  // Fill
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeOutCubic,
                    height: 12,
                    width: (MediaQuery.of(context).size.width - 80) *
                        (_attPct / 100).clamp(0.0, 1.0),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [BoxShadow(
                          color: color.withOpacity(0.4),
                          blurRadius: 4)],
                    ),
                  ),
                ]),

                const SizedBox(height: 12),

                // Stats row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _attStat('Present', _attPresent.toString(),
                        Colors.green),
                    Container(width: 1, height: 30,
                        color: Colors.grey.shade200),
                    _attStat('Absent',
                        (_attTotal - _attPresent).toString(),
                        Colors.red),
                    Container(width: 1, height: 30,
                        color: Colors.grey.shade200),
                    _attStat('Total', _attTotal.toString(),
                        Colors.blue),
                    Container(width: 1, height: 30,
                        color: Colors.grey.shade200),
                    // Status label
                    Column(children: [
                      Icon(
                        _attPct >= 75
                            ? Icons.check_circle_rounded
                            : _attPct >= 50
                                ? Icons.warning_amber_rounded
                                : Icons.cancel_rounded,
                        color: color, size: 20),
                      const SizedBox(height: 2),
                      Text(
                        _attPct >= 75
                            ? 'Good'
                            : _attPct >= 50
                                ? 'At Risk'
                                : 'Critical',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: color)),
                    ]),
                  ],
                ),

                const SizedBox(height: 8),
                // Tap hint
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('View Details',
                        style: TextStyle(fontSize: 11,
                            color: Colors.grey[500])),
                    Icon(Icons.chevron_right_rounded,
                        size: 16, color: Colors.grey[400]),
                  ],
                ),
              ]),
      ),
    );
  }

  Widget _attStat(String label, String val, Color color) =>
      Column(children: [
        Text(val, style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16, color: color)),
        Text(label, style: TextStyle(
            fontSize: 10, color: Colors.grey[600])),
      ]);

  // ── Profile card (unchanged) ──────────────────────────────────
  Widget _buildOverlappingProfile(bool isLaptop) {
    return Container(
      width: isLaptop ? 700 : double.infinity,
      height: 180,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 45),
            width: double.infinity,
            height: 150,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(children: [
                CustomPaint(
                    size: const Size(double.infinity, 170),
                    painter: ProfileCardPainter()),
                Positioned.fill(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 40),
                    Text(fullName,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(deptInfo,
                        style: const TextStyle(
                            color: Color(0xFFFFCDD2), fontSize: 16)),
                  ],
                )),
              ]),
            ),
          ),
          Positioned(
            child: Container(
              width: 95, height: 95,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: const Color(0xFFFBC02D), width: 3),
                boxShadow: const [BoxShadow(
                    color: Colors.black26, blurRadius: 10)],
              ),
              child: ClipOval(child: profileUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: profileUrl,
                      placeholder: (_, __) => const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFF8B0A1A))),
                      errorWidget: (_, __, ___) => const Icon(
                          Icons.person, size: 50, color: Colors.grey),
                      fit: BoxFit.cover)
                  : Container(color: Colors.white,
                      child: const Icon(Icons.person,
                          size: 50, color: Colors.grey))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridCard(Map<String, dynamic> item) {
    return GestureDetector(
      onTap: () => widget.parentPageController.animateToPage(
          item["index"],
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
              color: const Color(0xFFF0F0F0), width: 1.5),
          boxShadow: [BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10, offset: const Offset(0, 5))],
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
              child: Icon(item["icon"],
                  color: const Color(0xFF8B0A1A), size: 28),
            ),
            const SizedBox(height: 10),
            Text(item["title"],
                style: const TextStyle(
                    color: Color(0xFF8B0A1A),
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class ProfileCardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    double w = size.width, h = size.height;
    final paint = Paint()..style = PaintingStyle.fill;

    paint.color = const Color(0xFF5A060D);
    final p1 = Path();
    p1.lineTo(w, 0); p1.lineTo(w, h * 0.9);
    p1.cubicTo(w * 0.75, h * 1.15, w * 0.25, h * 0.85, 0, h);
    p1.close();
    canvas.drawPath(p1, paint);

    paint.color = const Color(0xFF8B0A1A);
    final p2 = Path();
    p2.lineTo(w, 0); p2.lineTo(w, h * 0.7);
    p2.cubicTo(w * 0.75, h * 0.95, w * 0.25, h * 0.7, 0, h * 0.85);
    p2.close();
    canvas.drawPath(p2, paint);

    final sPaint = Paint()
      ..color = const Color(0xFFFBC02D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final sPath = Path();
    sPath.moveTo(0, h * 0.8);
    sPath.cubicTo(w * 0.25, h * 0.65, w * 0.75, h * 0.95, w, h * 0.7);
    canvas.drawPath(sPath, sPaint);
  }

  @override
  bool shouldRepaint(CustomPainter _) => false;
}