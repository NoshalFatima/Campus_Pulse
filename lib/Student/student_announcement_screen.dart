// ✅ lib/Student/StudentAnnouncementFragment.dart — HIVE OFFLINE CACHE VERSION
//
// ✅ FIX 1: App closed → notification via OneSignal (works when net is on)
// ✅ FIX 2: Beautiful announcement cards — fixed height, "Read More" expand
// ✅ FIX 3: Mark as Read — stored in SharedPreferences locally (USER-SCOPED)
// ✅ FIX 4: All toasts in professional English (SnackBar style)
// ✅ FIX 5: Unread dot badge on each card
// ✅ FIX 6: Read state is scoped per user — survives logout/login
// ✅ FIX 7: Clear Notifications button — resets all read/unread state
// ✅ NEW : Hive offline cache — loads cached announcements immediately,
//          syncs from Firestore in background when online.
//          Works fully offline after first load.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/announcement_model.dart';
import '../services/notification_service.dart';
import '../services/announcement_listener_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// ── Hive box name ──────────────────────────────────────────────────────────
const String _kAnnouncementsBox = 'announcements_cache';

class StudentAnnouncementFragment extends StatefulWidget {
  const StudentAnnouncementFragment({super.key});

  @override
  State<StudentAnnouncementFragment> createState() =>
      _StudentAnnouncementFragmentState();
}

class _StudentAnnouncementFragmentState
    extends State<StudentAnnouncementFragment> {
  // ── Filter ─────────────────────────────────────────────────────────────────
  String selectedFilter = "All Categories";
  final List<String> filters = [
    "All Categories",
    "📢 General",
    "📚 Academic",
    "⚠️ Important",
    "📅 Event",
    "📝 Assignment",
    "🎉 Achievement",
  ];

  // ── Student Profile ────────────────────────────────────────────────────────
  String myDept = "";
  String mySem = "";
  String myShift = "";
  bool isLoadingProfile = true;

  // ── Read state ─────────────────────────────────────────────────────────────
  Set<String> _readIds = {};

  // ── Expanded cards (Read More) ─────────────────────────────────────────────
  final Set<String> _expandedIds = {};

  // ── Hive + announcements state ─────────────────────────────────────────────
  late Box<Announcement> _hiveBox;
  List<Announcement> _cachedAnnouncements = [];
  List<Announcement> _liveAnnouncements = [];
  bool _isOnline = true;
  StreamSubscription<QuerySnapshot>? _firestoreSubscription;

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Returns a user-scoped SharedPreferences key so read state is
  /// never shared between different accounts on the same device.
  String get _readIdsKey {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
    return 'read_announcements_$uid';
  }

  /// Key to persist which announcement IDs were cleared
  String get _clearedIdsKey {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
    return 'cleared_announcements_$uid';
  }

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  @override
  void dispose() {
    _firestoreSubscription?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // INIT
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _initializeData() async {
    await _openHiveBox();
    await _loadFromHive();
    await _loadReadIds();           // ← now user-scoped
    await _fetchStudentProfile();
    await _setOneSignalTags();
    await _setupFCMListener();
    _startFirestoreSync();

    if (!kIsWeb && myDept.isNotEmpty) {
      await AnnouncementListenerService.init();
      AnnouncementListenerService.startListening(
        dept: myDept,
        sem: mySem,
        shift: myShift,
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HIVE — OPEN BOX
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _openHiveBox() async {
    try {
      if (!Hive.isAdapterRegistered(0)) {
        Hive.registerAdapter(AnnouncementAdapter());
      }
      _hiveBox = await Hive.openBox<Announcement>(_kAnnouncementsBox);
      debugPrint("✅ Hive box opened: ${_hiveBox.length} cached items");
    } catch (e) {
      debugPrint("❌ Hive open error: $e");
      await Hive.deleteBoxFromDisk(_kAnnouncementsBox);
      _hiveBox = await Hive.openBox<Announcement>(_kAnnouncementsBox);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HIVE — LOAD CACHED ANNOUNCEMENTS
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadFromHive() async {
    try {
      final cached = _hiveBox.values.toList();
      cached.sort((a, b) => b.date.compareTo(a.date));
      if (mounted) {
        setState(() {
          _cachedAnnouncements = cached;
          isLoadingProfile = cached.isNotEmpty ? false : isLoadingProfile;
        });
      }
      debugPrint("✅ Hive: Loaded ${cached.length} cached announcements");
    } catch (e) {
      debugPrint("❌ Hive load error: $e");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HIVE — SAVE ALL TO CACHE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _saveToHive(List<Announcement> announcements) async {
    try {
      await _hiveBox.clear();
      final Map<String, Announcement> entries = {
        for (final a in announcements) a.id: a,
      };
      await _hiveBox.putAll(entries);
      debugPrint("✅ Hive: Saved ${announcements.length} announcements");
    } catch (e) {
      debugPrint("❌ Hive save error: $e");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FIRESTORE LIVE SYNC
  // ─────────────────────────────────────────────────────────────────────────

  void _startFirestoreSync() {
    _firestoreSubscription = FirebaseFirestore.instance
        .collection("Announcements")
        .orderBy("timestamp", descending: true)
        .snapshots()
        .listen(
      (snapshot) async {
        if (!mounted) return;

        final all = snapshot.docs
            .map((doc) => Announcement.fromMap(doc.data()))
            .toList();

        // Filter out permanently cleared announcements
        // Only show ones that are NOT in _clearedIds
        final visible = _clearedIds.isEmpty
            ? all
            : all.where((a) => !_clearedIds.contains(a.id)).toList();

        await _saveToHive(visible);
        if (mounted) {
          setState(() {
            _liveAnnouncements = visible;
            _isOnline = true;
          });
        }
      },
      onError: (e) {
        debugPrint("⚠️ Firestore stream error (offline?): $e");
        if (mounted) setState(() => _isOnline = false);
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  List<Announcement> get _activeAnnouncements =>
      _liveAnnouncements.isNotEmpty ? _liveAnnouncements : _cachedAnnouncements;

  List<Announcement> _applyFilter(List<Announcement> all) {
    return all.where((a) {
      final String annDept = a.dept.trim().toLowerCase();
      final String annSem = a.sem.trim().toLowerCase();
      final String annShift = a.shift.trim().toLowerCase();

      final bool isForAll = annDept == 'all' || annDept.isEmpty;
      final bool isForMe = annDept == myDept.toLowerCase() &&
          annSem == mySem.toLowerCase() &&
          annShift == myShift.toLowerCase();
      final bool catMatch = selectedFilter == "All Categories" ||
          a.category == selectedFilter;

      return (isForAll || isForMe) && catMatch;
    }).toList();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // READ STATE  (user-scoped — FIX for login persistence)
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadReadIds() async {
    final prefs = await SharedPreferences.getInstance();
    // Key includes the UID so different users on the same device
    // never share or override each other's read state.
    final List<String> ids = prefs.getStringList(_readIdsKey) ?? [];
    if (mounted) setState(() => _readIds = ids.toSet());
  }

  Future<void> _loadClearedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_clearedIdsKey) ?? [];
    if (mounted) setState(() => _clearedIds = ids.toSet());
  }

  Future<void> _markAsRead(String id) async {
    if (_readIds.contains(id)) return;
    setState(() => _readIds.add(id));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_readIdsKey, _readIds.toList());
  }

  Future<void> _markAllAsRead(List<Announcement> list) async {
    final prefs = await SharedPreferences.getInstance();
    for (final a in list) {
      _readIds.add(a.id);
    }
    await prefs.setStringList(_readIdsKey, _readIds.toList());
    if (mounted) setState(() {});
    _showSnack("All announcements marked as read.");
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CLEAR NOTIFICATIONS  (resets all read state for this user)
  // ─────────────────────────────────────────────────────────────────────────

  // ── Cleared IDs — persisted in SharedPreferences so they survive navigation ──
  Set<String> _clearedIds = {};

  Future<void> _clearNotifications() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "Clear Notifications",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Color(0xFF8B0A1A),
          ),
        ),
        content: const Text(
          "All announcements will be removed from this screen. They will reappear when new ones are posted.",
          style: TextStyle(fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel",
                style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B0A1A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Clear",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Mark all current IDs as "read" so they won't reappear as unread
    final allIds = _activeAnnouncements.map((a) => a.id).toList();
    final prefs = await SharedPreferences.getInstance();
    for (final id in allIds) _readIds.add(id);
    await prefs.setStringList(_readIdsKey, _readIds.toList());

    // Wipe Hive cache
    await _hiveBox.clear();

    // Persist cleared IDs so they survive navigation and app restarts
    final prefs2 = await SharedPreferences.getInstance();
    for (final id in allIds) _clearedIds.add(id);
    await prefs2.setStringList(_clearedIdsKey, _clearedIds.toList());

    if (mounted) {
      setState(() {
        _cachedAnnouncements = [];
        _liveAnnouncements = [];
        _expandedIds.clear();
      });
    }
    _showSnack("Notifications cleared.");
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FETCH STUDENT PROFILE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _fetchStudentProfile() async {
    try {
      final User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) setState(() => isLoadingProfile = false);
        return;
      }

      final doc = await FirebaseFirestore.instance
          .collection('Users')
          .doc(user.uid)
          .get();

      if (doc.exists && mounted) {
        final data = doc.data() as Map<String, dynamic>;
        setState(() {
          myDept = (data['dept'] ?? '').toString().trim();
          mySem = (data['semester'] ?? data['sem'] ?? '').toString().trim();
          myShift = (data['shift'] ?? '').toString().trim();
          isLoadingProfile = false;
        });
        debugPrint(
            "✅ Profile loaded: dept='$myDept' sem='$mySem' shift='$myShift'");
      } else {
        if (mounted) setState(() => isLoadingProfile = false);
      }
    } catch (e) {
      debugPrint("⚠️ Profile fetch error (offline?): $e");
      if (mounted) setState(() => isLoadingProfile = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ONESIGNAL TAGS
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _setOneSignalTags() async {
    if (kIsWeb) return;
    try {
      if (myDept.isEmpty || mySem.isEmpty) {
        await Future.delayed(const Duration(seconds: 2));
        if (myDept.isEmpty) return;
      }

      final User? user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await OneSignal.login(user.uid);

      final String classTag = "${myDept}_${mySem}_$myShift"
          .toLowerCase()
          .replaceAll(' ', '_')
          .trim();

      await OneSignal.User.addTags({
        'class_tag': classTag,
        'all_campus_tag': 'true',
        'dept': myDept.toLowerCase().replaceAll(' ', '_'),
        'sem': mySem.toLowerCase(),
        'shift': myShift.toLowerCase(),
        'role': 'student',
      });

      await OneSignal.Notifications.requestPermission(true);
      debugPrint("✅ OneSignal Tags set: class_tag=$classTag");
    } catch (e) {
      debugPrint("❌ OneSignal tags error: $e");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FCM FOREGROUND LISTENER
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _setupFCMListener() async {
    if (kIsWeb) return;
    try {
      await FirebaseMessaging.instance
          .requestPermission(alert: true, badge: true, sound: true);

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        if (!mounted || message.notification == null) return;
        NotificationService.show(message);
      });
    } catch (e) {
      debugPrint("❌ FCM Listener error: $e");
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                msg,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor:
            isError ? Colors.red.shade700 : const Color(0xFF8B0A1A),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (isLoadingProfile && _cachedAnnouncements.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF8B0A1A)),
      );
    }

    final announcements = _applyFilter(_activeAnnouncements);
    final int unreadCount =
        announcements.where((a) => !_readIds.contains(a.id)).length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(15, 27, 15, 60),
        decoration: BoxDecoration(
          color: const Color(0xFFFDF2F3),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: const Color(0xFFFBC02D), width: 2),
        ),
        child: Column(
          children: [
            // ── Header ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.campaign_rounded,
                      size: 28, color: Color(0xFF8B0A1A)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      "CAMPUS UPDATES",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                        color: Color(0xFF8B0A1A),
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  // ── Clear Notifications button ─────────────────────────
                  Tooltip(
                    message: "Clear notification history",
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _clearNotifications,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: Colors.red.shade200, width: 1.5),
                          boxShadow: const [
                            BoxShadow(color: Colors.black12, blurRadius: 4)
                          ],
                        ),
                        child: Icon(Icons.notifications_off_outlined,
                            color: Colors.red.shade400, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Container(
              height: 2,
              width: 60,
              color: const Color(0xFFFBC02D),
              margin: const EdgeInsets.symmetric(vertical: 10),
            ),

            // ── Offline banner ────────────────────────────────────────────
            if (!_isOnline)
              Container(
                margin: const EdgeInsets.fromLTRB(15, 0, 15, 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.wifi_off_rounded,
                        size: 15, color: Colors.orange.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "You're offline — showing cached announcements",
                        style: TextStyle(
                            fontSize: 12, color: Colors.orange.shade800),
                      ),
                    ),
                  ],
                ),
              ),

            // ── Filter + Mark All Read ────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 8),
              child: Row(
                children: [
                  Expanded(child: _buildFilterDropdown()),
                  const SizedBox(width: 10),
                  Tooltip(
                    message: "Mark all as read",
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _markAllAsRead(announcements),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: const Color(0xFFFBC02D), width: 1.5),
                          boxShadow: const [
                            BoxShadow(color: Colors.black12, blurRadius: 4)
                          ],
                        ),
                        child: const Icon(Icons.done_all_rounded,
                            color: Color(0xFF8B0A1A), size: 20),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Unread summary bar ────────────────────────────────────────
            if (unreadCount > 0)
              GestureDetector(
                onTap: () => _markAllAsRead(announcements),
                child: Container(
                  margin: const EdgeInsets.fromLTRB(15, 0, 15, 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B0A1A).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: const Color(0xFF8B0A1A).withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF8B0A1A),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          "$unreadCount new",
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          "You have unread announcements",
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF8B0A1A)),
                        ),
                      ),
                      const Text(
                        "Mark all read",
                        style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8B0A1A),
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.underline),
                      ),
                    ],
                  ),
                ),
              ),

            // ── List ─────────────────────────────────────────────────────
            Expanded(
              child: announcements.isEmpty
                  ? _buildEmptyState(
                      myDept.isEmpty
                          ? "No announcements available yet."
                          : "No updates available for $myDept at the moment.",
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 20),
                      itemCount: announcements.length,
                      itemBuilder: (context, index) {
                        return _buildAnnouncementCard(announcements[index]);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FILTER DROPDOWN
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildFilterDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFBC02D), width: 1.5),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selectedFilter,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              color: Color(0xFF8B0A1A)),
          items: filters
              .map((f) => DropdownMenuItem(
                  value: f,
                  child: Text(f, style: const TextStyle(fontSize: 13))))
              .toList(),
          onChanged: (v) => setState(() => selectedFilter = v!),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ANNOUNCEMENT CARD
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildAnnouncementCard(Announcement a) {
    final bool isRead = _readIds.contains(a.id);
    final bool isExpanded = _expandedIds.contains(a.id);

    return GestureDetector(
      onTap: () {
        if (!isRead) _markAsRead(a.id);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.fromLTRB(15, 0, 15, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: a.isUrgent
                ? Colors.red.withOpacity(0.5)
                : isRead
                    ? const Color(0xFFE0E0E0)
                    : const Color(0xFF8B0A1A).withOpacity(0.4),
            width: isRead ? 1 : 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: a.isUrgent
                  ? Colors.red.withOpacity(0.08)
                  : Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Card Header ──────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              decoration: BoxDecoration(
                color: a.isUrgent
                    ? Colors.red.withOpacity(0.05)
                    : isRead
                        ? Colors.grey.withOpacity(0.03)
                        : const Color(0xFF8B0A1A).withOpacity(0.04),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: a.isUrgent
                          ? Colors.red.withOpacity(0.12)
                          : const Color(0xFF8B0A1A).withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      a.isUrgent
                          ? Icons.warning_amber_rounded
                          : Icons.campaign_rounded,
                      color: a.isUrgent
                          ? Colors.red
                          : const Color(0xFF8B0A1A),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                a.title,
                                style: TextStyle(
                                  fontWeight: isRead
                                      ? FontWeight.w600
                                      : FontWeight.bold,
                                  fontSize: 14.5,
                                  color: a.isUrgent
                                      ? Colors.red.shade700
                                      : const Color(0xFF1A1A1A),
                                ),
                              ),
                            ),
                            if (!isRead)
                              Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(left: 6),
                                decoration: BoxDecoration(
                                  color: a.isUrgent
                                      ? Colors.red
                                      : const Color(0xFF8B0A1A),
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "By ${a.teacherName}  ·  ${a.date}",
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Divider(height: 1, color: Colors.grey.shade100),

            // ── Description ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.desc,
                    maxLines: isExpanded ? null : 3,
                    overflow: isExpanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.grey.shade800,
                      fontSize: 13.5,
                      height: 1.5,
                    ),
                  ),
                  if (a.desc.length > 120)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (isExpanded) {
                            _expandedIds.remove(a.id);
                          } else {
                            _expandedIds.add(a.id);
                            _markAsRead(a.id);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          isExpanded ? "Show less" : "Read more",
                          style: const TextStyle(
                            color: Color(0xFF8B0A1A),
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // ── Footer ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBC02D).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: const Color(0xFFFBC02D).withOpacity(0.5)),
                    ),
                    child: Text(
                      a.category,
                      style: const TextStyle(
                        color: Color(0xFFB8860B),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (a.isUrgent) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        "🚨 URGENT",
                        style: TextStyle(
                          color: Colors.red,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (!isRead)
                    GestureDetector(
                      onTap: () {
                        _markAsRead(a.id);
                        _showSnack("Announcement marked as read.");
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF8B0A1A).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFF8B0A1A).withOpacity(0.3),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.done_rounded,
                                size: 12, color: Color(0xFF8B0A1A)),
                            SizedBox(width: 4),
                            Text(
                              "Mark as read",
                              style: TextStyle(
                                color: Color(0xFF8B0A1A),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.done_all_rounded,
                            size: 13, color: Colors.grey),
                        SizedBox(width: 4),
                        Text(
                          "Read",
                          style: TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // EMPTY STATE
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
          ),
        ],
      ),
    );
  }
}