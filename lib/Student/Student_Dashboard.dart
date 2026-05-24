import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

// Fragments
import 'student_home_fragment.dart';
import '../chat/users_list_fragment.dart';
import '../Student/student_announcement_screen.dart';
import '../Student/student_attendance_module.dart';
import '../Student/student_profile_screen.dart';
import '../settings/setting_screen.dart';
import '../services/onesignal_service.dart';

class StudentDashboard extends StatefulWidget {
  const StudentDashboard({super.key});

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  final PageController _pageController = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedIndex = 0;

  // ── Student profile ────────────────────────────────────────────────────────
  String _studentName    = "Student";
  String _studentEmail   = "";
  String _studentDept    = "";
  String _studentSem     = "";
  String _studentShift   = "";
  String _studentRollNo  = "";
  String? _studentPhotoUrl;

  // ── Unread counts ──────────────────────────────────────────────────────────
  int _unreadAnnouncements = 0;
  int _unreadChat          = 0;

  // ── OneSignal bell notifications ───────────────────────────────────────────
  final List<Map<String, dynamic>> _osNotifications = [];

  // ── Subscriptions ──────────────────────────────────────────────────────────
  StreamSubscription<QuerySnapshot>? _announcementSub;
  StreamSubscription?                _chatSub;

  final List<String> _titles = [
    "Campus Pulse",
    "Announcements",
    "Events",
    "Attendance",
    "Messages",
    "Profile",
  ];

  @override
  void initState() {
    super.initState();
    _fetchStudentProfile();
    _listenOneSignalNotifications();
  }

  @override
  void dispose() {
    _announcementSub?.cancel();
    _chatSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FETCH STUDENT PROFILE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _fetchStudentProfile() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final doc = await FirebaseFirestore.instance
          .collection('Users')
          .doc(user.uid)
          .get();

      if (!doc.exists || !mounted) return;

      final data = doc.data()!;
      debugPrint("🔍 Firestore fields: ${data.keys.toList()}");

      String field(List<String> keys) {
        for (final k in keys) {
          final v = data[k];
          if (v != null && v.toString().trim().isNotEmpty) {
            return v.toString().trim();
          }
        }
        return '';
      }

      final rawName  = field(['name', 'fullName', 'displayName']);
      final rawEmail = field(['email']);
      final rawDept  = field(['dept', 'department']);
      final rawSem   = field(['semester', 'sem']);
      final rawShift = field(['shift']);
      final rawRegNo = field(['regNo', 'rollNo', 'registrationNo']);
      final rawPhoto = field(['profilePic', 'photoUrl', 'photoURL', 'profileImage']);

      setState(() {
        _studentName     = rawName.isNotEmpty ? rawName : (user.displayName?.trim() ?? '');
        _studentEmail    = rawEmail.isNotEmpty ? rawEmail : (user.email ?? '');
        _studentDept     = rawDept;
        _studentSem      = rawSem;
        _studentShift    = rawShift;
        _studentRollNo   = rawRegNo;
        _studentPhotoUrl = rawPhoto.isNotEmpty ? rawPhoto : null;
      });

      debugPrint("✅ Profile: name='$_studentName' dept='$_studentDept' sem='$_studentSem'");

      // ✅ Register class tag AFTER profile data is available
      // Note: loginUser() is NOT called here — it must be called in login_activity
      // right after Firebase sign-in. Here we only set class tags.
      await _registerClassTagOnly();

      _listenAnnouncementUnread(user.uid);
      if (!kIsWeb) _listenChatUnread(user.uid);
    } catch (e) {
      debugPrint("❌ Profile fetch error: $e");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REGISTER CLASS TAG ONLY
  // loginUser() should already be called from login_activity after sign-in.
  // This just sets the class/role tags so targeted notifications work.
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _registerClassTagOnly() async {
    if (_studentDept.isEmpty || _studentSem.isEmpty) {
      debugPrint("⚠️ OneSignal: dept/sem empty — tags not set");
      return;
    }

    try {
      await OneSignalService.registerStudentClassTag(
        dept  : _studentDept,
        sem   : _studentSem,
        shift : _studentShift,
      );
    } catch (e) {
      debugPrint("❌ OneSignal class tag error: $e");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UNREAD ANNOUNCEMENTS
  // ─────────────────────────────────────────────────────────────────────────

  bool _lifecycleListenerAdded = false;

  void _listenAnnouncementUnread(String uid) {
    _announcementSub = FirebaseFirestore.instance
        .collection('Announcements')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen((snapshot) async {
      if (!mounted) return;
      await _recalcUnread(uid, snapshot.docs.map((d) => d.id).toList());
    });

    if (!_lifecycleListenerAdded) {
      _lifecycleListenerAdded = true;
      WidgetsBinding.instance.addObserver(_AppLifecycleObserver(
        onResume: () async {
          final user = FirebaseAuth.instance.currentUser;
          if (user == null || !mounted) return;
          final snap = await FirebaseFirestore.instance
              .collection('Announcements')
              .get();
          await _recalcUnread(user.uid, snap.docs.map((d) => d.id).toList());
        },
      ));
    }
  }

  Future<void> _recalcUnread(String uid, List<String> allIds) async {
    final prefs            = await SharedPreferences.getInstance();
    final firstLoginKey    = 'first_login_done_$uid';
    final bool firstDone   = prefs.getBool(firstLoginKey) ?? false;

    if (!firstDone) {
      await prefs.setStringList('read_announcements_$uid', allIds);
      await prefs.setBool(firstLoginKey, true);
      if (mounted) setState(() => _unreadAnnouncements = 0);
      return;
    }

    final readIds = (prefs.getStringList('read_announcements_$uid') ?? []).toSet();
    final count   = allIds.where((id) => !readIds.contains(id)).length;
    if (mounted) setState(() => _unreadAnnouncements = count);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UNREAD CHAT
  // ─────────────────────────────────────────────────────────────────────────

  void _listenChatUnread(String uid) {
    _chatSub = FirebaseDatabase.instance
        .ref('Chats')
        .onValue
        .listen((event) {
      if (!mounted || event.snapshot.value == null) return;

      int total = 0;
      try {
        final raw = event.snapshot.value;
        if (raw is! Map) return;

        raw.forEach((chatId, chatData) {
          if (chatId == null) return;
          if (!chatId.toString().contains(uid)) return;
          if (chatData == null || chatData is! Map) return;

          chatData.forEach((msgKey, msgVal) {
            if (msgVal == null || msgVal is! Map) return;
            try {
              final isRead    = msgVal['isRead'];
              final senderId  = msgVal['senderId']?.toString();
              final isDeleted = msgVal['isDeleted'];
              if (isRead == false && senderId != uid && isDeleted != true) {
                total++;
              }
            } catch (_) {}
          });
        });
      } catch (e) {
        debugPrint("❌ Chat unread parse: $e");
      }

      if (mounted) setState(() => _unreadChat = total);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ONESIGNAL FOREGROUND LISTENER (bell icon)
  // ─────────────────────────────────────────────────────────────────────────

  static const String _bellKey = 'bell_notifications';

  Future<void> _loadPersistedNotifications() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString('${_bellKey}_${user.uid}');
      if (raw == null || raw.isEmpty) return;

      final List list = jsonDecode(raw) as List;
      if (mounted) {
        setState(() {
          _osNotifications.clear();
          for (final item in list) {
            _osNotifications.add({
              'title': item['title'] ?? '',
              'body' : item['body']  ?? '',
              'time' : DateTime.fromMillisecondsSinceEpoch(item['time'] as int),
              'read' : item['read']  ?? true,
            });
          }
        });
      }
    } catch (e) {
      debugPrint("❌ Load bell notifications: $e");
    }
  }

  Future<void> _persistNotifications() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final prefs = await SharedPreferences.getInstance();
      final list  = _osNotifications.map((n) => {
        'title': n['title'],
        'body' : n['body'],
        'time' : (n['time'] as DateTime).millisecondsSinceEpoch,
        'read' : n['read'],
      }).toList();
      final trimmed = list.length > 30 ? list.sublist(0, 30) : list;
      await prefs.setString('${_bellKey}_${user.uid}', jsonEncode(trimmed));
    } catch (e) {
      debugPrint("❌ Persist bell notifications: $e");
    }
  }

  void _listenOneSignalNotifications() {
    _loadPersistedNotifications();
    if (kIsWeb) return;

    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      if (!mounted) return;
      final notif = event.notification;
      event.preventDefault();
      notif.display();
      setState(() {
        _osNotifications.insert(0, {
          'title': notif.title ?? 'Notification',
          'body' : notif.body  ?? '',
          'time' : DateTime.now(),
          'read' : false,
        });
      });
      _persistNotifications();
    });

    OneSignal.Notifications.addClickListener((event) {
      if (!mounted) return;
      final type = event.notification.additionalData?['type'];
      if (type == 'announcement') _onItemTapped(1);
      else if (type == 'chat')    _onItemTapped(4);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // NOTIFICATION BELL PANEL
  // ─────────────────────────────────────────────────────────────────────────

  void _showNotificationsPanel(BuildContext context) {
    final unreadOsCount =
        _osNotifications.where((n) => n['read'] == false).length;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setModal) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.65,
            decoration: const BoxDecoration(
              color: Color(0xFFFDF2F3),
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              children: [
                Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_active_rounded,
                          color: Color(0xFF8B0A1A), size: 22),
                      const SizedBox(width: 8),
                      const Text(
                        "Recent Notifications",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF8B0A1A),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.settings_outlined,
                            color: Color(0xFF8B0A1A), size: 20),
                        onPressed: () {
                          Navigator.pop(ctx);
                          Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const SettingsScreen()));
                        },
                      ),
                      if (unreadOsCount > 0)
                        TextButton(
                          onPressed: () {
                            setModal(() {
                              for (final n in _osNotifications) n['read'] = true;
                            });
                            setState(() {});
                          },
                          child: const Text("Mark all read",
                              style: TextStyle(color: Color(0xFF8B0A1A), fontSize: 12)),
                        ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Expanded(
                  child: _osNotifications.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.notifications_none,
                                  size: 52, color: Colors.grey.shade300),
                              const SizedBox(height: 10),
                              Text("No notifications yet",
                                  style: TextStyle(
                                      color: Colors.grey.shade400, fontSize: 14)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _osNotifications.length,
                          itemBuilder: (_, i) {
                            final n      = _osNotifications[i];
                            final isRead = n['read'] == true;
                            return InkWell(
                              onTap: () {
                                setModal(() => n['read'] = true);
                                setState(() {});
                              },
                              child: Container(
                                margin: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                                padding: const EdgeInsets.all(13),
                                decoration: BoxDecoration(
                                  color: isRead
                                      ? Colors.white
                                      : const Color(0xFF8B0A1A).withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isRead
                                        ? Colors.grey.shade200
                                        : const Color(0xFF8B0A1A).withOpacity(0.25),
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(7),
                                      decoration: BoxDecoration(
                                        color: isRead
                                            ? Colors.grey.shade100
                                            : const Color(0xFF8B0A1A).withOpacity(0.1),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(Icons.campaign_rounded,
                                          size: 16,
                                          color: isRead
                                              ? Colors.grey
                                              : const Color(0xFF8B0A1A)),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            n['title'],
                                            style: TextStyle(
                                              fontWeight: isRead
                                                  ? FontWeight.w500
                                                  : FontWeight.bold,
                                              fontSize: 13.5,
                                              color: const Color(0xFF1A1A1A),
                                            ),
                                          ),
                                          if ((n['body'] as String).isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 3),
                                              child: Text(
                                                n['body'],
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey.shade600),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          const SizedBox(height: 4),
                                          Text(_formatTime(n['time']),
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.grey.shade400)),
                                        ],
                                      ),
                                    ),
                                    if (!isRead)
                                      Container(
                                        width: 8, height: 8,
                                        margin: const EdgeInsets.only(top: 4),
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF8B0A1A),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1)  return "Just now";
    if (diff.inMinutes < 60) return "${diff.inMinutes}m ago";
    if (diff.inHours   < 24) return "${diff.inHours}h ago";
    return "${diff.inDays}d ago";
  }

  // ─────────────────────────────────────────────────────────────────────────
  // NAVIGATION
  // ─────────────────────────────────────────────────────────────────────────

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final int bellUnread =
        _osNotifications.where((n) => n['read'] == false).length;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFFDF7F7),
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          Positioned(
            top: 0, left: 0, right: 0,
            child: CustomPaint(
              size: Size(MediaQuery.of(context).size.width, 130),
              painter: HeaderCurvedPainter(),
            ),
          ),
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
                        fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Stack(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.notifications_none,
                            color: Colors.white, size: 28),
                        onPressed: () => _showNotificationsPanel(context),
                      ),
                      if (bellUnread > 0)
                        Positioned(
                          right: 6, top: 6,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFBC02D),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            constraints:
                                const BoxConstraints(minWidth: 16, minHeight: 16),
                            child: Text(
                              bellUnread > 99 ? '99+' : '$bellUnread',
                              style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 90),
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) async {
                setState(() => _selectedIndex = index);
                final user = FirebaseAuth.instance.currentUser;
                if (user == null) return;
                final prefs = await SharedPreferences.getInstance();
                final readIds =
                    (prefs.getStringList('read_announcements_${user.uid}') ?? [])
                        .toSet();
                final snap = await FirebaseFirestore.instance
                    .collection('Announcements')
                    .get();
                final allIds = snap.docs.map((d) => d.id).toList();
                final count =
                    allIds.where((id) => !readIds.contains(id)).length;
                if (mounted) setState(() => _unreadAnnouncements = count);
              },
              children: [
                StudentHomeFragment(parentPageController: _pageController),
                const StudentAnnouncementFragment(),
                const Center(child: Text("Events")),
                const StudentAttendanceFragment(),
                const UsersListFragment(),
                const StudentProfileScreen(),
              ],
            ),
          ),
          _buildFloatingBottomMenu(),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BOTTOM MENU
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildFloatingBottomMenu() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.fromLTRB(15, 0, 15, 5),
        height: 70,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(25),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 15, offset: Offset(0, 5))
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _menuIcon(Icons.home_filled,       "Home",       0),
            _menuIconBadge(Icons.notifications,"Alerts",     1, _unreadAnnouncements),
            _menuIcon(Icons.event_available,   "Events",     2),
            _menuIcon(Icons.qr_code_scanner,   "Scan",       3),
            _menuIconBadge(Icons.chat_bubble,  "Chat",       4, _unreadChat),
            _menuIcon(Icons.person,            "Profile",    5),
          ],
        ),
      ),
    );
  }

  Widget _menuIcon(IconData icon, String label, int index) {
    final bool isSel = _selectedIndex == index;
    return InkWell(
      onTap: () => _onItemTapped(index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              color: isSel ? const Color(0xFF8B0A1A) : Colors.grey, size: 26),
          if (isSel)
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF8B0A1A),
                    fontSize: 10,
                    fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _menuIconBadge(IconData icon, String label, int index, int count) {
    final bool isSel = _selectedIndex == index;
    return InkWell(
      onTap: () => _onItemTapped(index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon,
                  color: isSel ? const Color(0xFF8B0A1A) : Colors.grey, size: 26),
              if (count > 0)
                Positioned(
                  right: -6, top: -6,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBC02D),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints:
                        const BoxConstraints(minWidth: 15, minHeight: 15),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 8,
                          fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          if (isSel)
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF8B0A1A),
                    fontSize: 10,
                    fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DRAWER
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            UserAccountsDrawerHeader(
              margin: EdgeInsets.zero,
              decoration: const BoxDecoration(color: Color(0xFF8B0A1A)),
              accountName: _studentName.isEmpty
                  ? Container(
                      height: 14, width: 120,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    )
                  : Text(_studentName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
              accountEmail: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_studentEmail,
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis),
                  if (_studentDept.isNotEmpty || _studentSem.isNotEmpty)
                    Text(
                      [
                        if (_studentDept.isNotEmpty)  _studentDept,
                        if (_studentSem.isNotEmpty)   "Sem $_studentSem",
                        if (_studentShift.isNotEmpty) _studentShift,
                      ].join(" · "),
                      style: const TextStyle(fontSize: 10, color: Colors.white70),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
              currentAccountPicture: CircleAvatar(
                backgroundColor: Colors.white,
                backgroundImage: _studentPhotoUrl != null
                    ? NetworkImage(_studentPhotoUrl!) : null,
                child: _studentPhotoUrl == null
                    ? Text(
                        _studentName.isNotEmpty
                            ? _studentName[0].toUpperCase() : 'S',
                        style: const TextStyle(
                            color: Color(0xFF8B0A1A),
                            fontSize: 28,
                            fontWeight: FontWeight.bold),
                      )
                    : null,
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    _drawerItem(Icons.home_outlined, "Home", () {
                      Navigator.pop(context); _onItemTapped(0);
                    }),
                    _drawerItem(Icons.notifications_outlined, "Announcements", () {
                      Navigator.pop(context); _onItemTapped(1);
                    }),
                    _drawerItem(Icons.event_outlined, "Events", () {
                      Navigator.pop(context); _onItemTapped(2);
                    }),
                    _drawerItem(Icons.fact_check_outlined, "Attendance", () {
                      Navigator.pop(context); _onItemTapped(3);
                    }),
                    _drawerItem(Icons.chat_bubble_outline, "Messages", () {
                      Navigator.pop(context); _onItemTapped(4);
                    }),
                    _drawerItem(Icons.person_outline, "My Profile", () {
                      Navigator.pop(context); _onItemTapped(5);
                    }),
                    const Divider(height: 1),
                    _drawerItem(Icons.settings_outlined, "Settings", () {
                      Navigator.pop(context);
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const SettingsScreen()));
                    }),
                    _drawerItem(Icons.help_outline, "Help & Support", () {
                      Navigator.pop(context);
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          title: const Row(children: [
                            Icon(Icons.help_outline, color: Color(0xFF8B0A1A)),
                            SizedBox(width: 8),
                            Text("Help & Support",
                                style: TextStyle(
                                    color: Color(0xFF8B0A1A),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                          ]),
                          content: const Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("For any issues or queries, contact:"),
                              SizedBox(height: 10),
                              Text("📧  support@campuspulse.edu",
                                  style: TextStyle(fontSize: 13)),
                              SizedBox(height: 6),
                              Text("📞  +92-XXX-XXXXXXX",
                                  style: TextStyle(fontSize: 13)),
                              SizedBox(height: 10),
                              Text(
                                "You can also visit your department office for assistance.",
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                          actions: [
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF8B0A1A),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10))),
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text("OK",
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      );
                    }),
                    _drawerItem(Icons.info_outline, "About App", () {
                      Navigator.pop(context);
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          title: const Row(children: [
                            Icon(Icons.school, color: Color(0xFF8B0A1A), size: 26),
                            SizedBox(width: 8),
                            Text("About App",
                                style: TextStyle(
                                    color: Color(0xFF8B0A1A),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                          ]),
                          content: const Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Campus Pulse",
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF8B0A1A))),
                              SizedBox(height: 4),
                              Text("Version 1.0.0",
                                  style: TextStyle(color: Colors.grey, fontSize: 13)),
                              SizedBox(height: 12),
                              Text(
                                "A smart campus management app — stay updated with announcements, attendance, events, and more.",
                                style: TextStyle(fontSize: 13, height: 1.5),
                              ),
                              SizedBox(height: 12),
                              Text("Developed as Final Year Project.",
                                  style: TextStyle(fontSize: 12, color: Colors.grey)),
                            ],
                          ),
                          actions: [
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF8B0A1A),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10))),
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text("OK",
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text("Logout",
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    title: const Text("Logout",
                        style: TextStyle(color: Color(0xFF8B0A1A))),
                    content: const Text("Are you sure you want to logout?"),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text("Cancel")),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text("Logout",
                            style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await OneSignalService.clearStudentTags();
                  await OneSignalService.logoutUser();
                  await FirebaseAuth.instance.signOut();
                  if (mounted) Navigator.pushReplacementNamed(context, '/login');
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF8B0A1A), size: 22),
      title: Text(label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      onTap: onTap,
      dense: true,
      horizontalTitleGap: 4,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// APP LIFECYCLE OBSERVER
// ─────────────────────────────────────────────────────────────────────────

class _AppLifecycleObserver extends WidgetsBindingObserver {
  final VoidCallback onResume;
  _AppLifecycleObserver({required this.onResume});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// CURVED HEADER PAINTER
// ─────────────────────────────────────────────────────────────────────────

class HeaderCurvedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    double w = size.width;
    double h = size.height;
    final paint = Paint()..style = PaintingStyle.fill;

    paint.color = const Color(0xFF5A060D);
    Path p1 = Path();
    p1.moveTo(0, 0);
    p1.lineTo(w, 0);
    p1.lineTo(w, h * (210 / 230));
    p1.cubicTo(w * (300 / 412), h * (260 / 230),
        w * (112 / 412), h * (200 / 230), 0, h);
    p1.close();
    canvas.drawPath(p1, paint);

    paint.color = const Color(0xFF8B0A1A);
    Path p2 = Path();
    p2.moveTo(0, 0);
    p2.lineTo(w, 0);
    p2.lineTo(w, h * (170 / 230));
    p2.cubicTo(w * (300 / 412), h * (220 / 230),
        w * (112 / 412), h * (160 / 230), 0, h * (190 / 230));
    p2.close();
    canvas.drawPath(p2, paint);

    paint.color = const Color(0xFFA11321).withOpacity(0.15);
    Path p3 = Path();
    p3.moveTo(0, 0);
    p3.lineTo(w, 0);
    p3.lineTo(w, h * (130 / 230));
    p3.cubicTo(w * (300 / 412), h * (180 / 230),
        w * (112 / 412), h * (120 / 230), 0, h * (150 / 230));
    p3.close();
    canvas.drawPath(p3, paint);

    final strokePaint = Paint()
      ..color       = const Color(0xFFFBC02D)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap   = StrokeCap.round;

    Path strokePath = Path();
    strokePath.moveTo(0, h * (182 / 230));
    strokePath.cubicTo(w * (112 / 412), h * (152 / 230),
        w * (300 / 412), h * (212 / 230), w, h * (162 / 230));
    canvas.drawPath(strokePath, strokePaint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}