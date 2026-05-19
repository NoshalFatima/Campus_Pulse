// ✅ lib/services/announcement_listener_service.dart
//
// ✅ FREE SOLUTION — No FCM server needed, No cost
//
// Kaise kaam karta hai:
//   1. Student app Firestore "Announcements" collection ko sun'ta hai
//   2. Jab teacher Web se post kare → Firestore mein naya doc banta hai
//   3. Firestore onSnapshot mobile pe fire hota hai (app open/background mein)
//   4. Check karta hai: kya yeh NEW announcement hai? (app start ke baad ki)
//   5. Check karta hai: kya yeh IS student ke liye hai? (dept/sem/shift match)
//   6. flutter_local_notifications se heads-up notification dikhata hai
//
// Result:
//   Teacher Web se post kare → Mobile student ko notification milti hai ✅
//   App open ho ya background mein — dono cases mein kaam karta hai ✅

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Color;
class AnnouncementListenerService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // ✅ App start hone ka waqt — is se pehle ke announcements ignore karo
  static final DateTime _appStartTime = DateTime.now();

  // ✅ Already shown IDs — duplicate notifications avoid karne ke liye
  static final Set<String> _shownIds = {};

  static bool _isInitialized = false;

  // ─────────────────────────────────────────────────────────────────────────
  // INIT — main() ya login ke baad ek baar call karo
  // ─────────────────────────────────────────────────────────────────────────

  static Future<void> init() async {
    // Web pe local notifications nahi chalti
    if (kIsWeb) return;
    // Agar pehle se initialize ho chuka hai toh skip karo
    if (_isInitialized) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );

    // ✅ High importance channel banana zaroori hai Android pe
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'high_importance_channel',
      'Campus Pulse Notifications',
      description: 'Announcements and chat notifications',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _isInitialized = true;
    print("✅ AnnouncementListenerService initialized");
  }

  // ─────────────────────────────────────────────────────────────────────────
  // START LISTENING
  //
  // Student profile load hone ke BAAD call karo
  // dept, sem, shift — Firestore user doc se milte hain
  //
  // Example:
  //   AnnouncementListenerService.startListening(
  //     dept: "Computer Science",
  //     sem: "6th",
  //     shift: "Morning",
  //   );
  // ─────────────────────────────────────────────────────────────────────────

  static void startListening({
    required String dept,
    required String sem,
    required String shift,
  }) {
    // Web pe yeh nahi chalega
    if (kIsWeb) return;

    // Lowercase mein convert karo comparison ke liye
    final String myDept = dept.toLowerCase().trim();
    final String mySem = sem.toLowerCase().trim();
    final String myShift = shift.toLowerCase().trim();

    print("🔔 AnnouncementListenerService: Listening for "
        "dept='$myDept' sem='$mySem' shift='$myShift'");

    // ✅ Firestore mein naye announcements sun'o
    FirebaseFirestore.instance
        .collection("Announcements")
        .orderBy("timestamp", descending: true)
        .limit(20)
        .snapshots()
        .listen(
      (QuerySnapshot snapshot) {
        for (final DocumentChange change in snapshot.docChanges) {
          // ✅ Sirf NAYE docs process karo (modified/removed ignore karo)
          if (change.type != DocumentChangeType.added) continue;

          final Map<String, dynamic>? data =
              change.doc.data() as Map<String, dynamic>?;
          if (data == null) continue;

          final String id = change.doc.id;

          // ✅ Agar yeh notification pehle se dikha chuke hain toh skip karo
          if (_shownIds.contains(id)) continue;

          // ✅ Sirf naye announcements dikhao (app start ke baad wale)
          // 10 second ka buffer diya hai Firestore latency ke liye
          final Timestamp? ts = data['timestamp'] as Timestamp?;
          if (ts != null) {
            final DateTime announcementTime = ts.toDate();
            final DateTime cutoff =
                _appStartTime.subtract(const Duration(seconds: 10));
            if (announcementTime.isBefore(cutoff)) {
              // Purana announcement — skip karo, sirf _shownIds mein add karo
              _shownIds.add(id);
              continue;
            }
          }

          // ✅ Check karo: kya yeh announcement IS student ke liye hai?
          final String annDept =
              (data['dept'] ?? '').toString().toLowerCase().trim();
          final String annSem =
              (data['semester'] ?? data['sem'] ?? '')
                  .toString()
                  .toLowerCase()
                  .trim();
          final String annShift =
              (data['shift'] ?? '').toString().toLowerCase().trim();

          // Sabke liye hai? (all_campus broadcast)
          final bool isForAll = annDept == 'all' || annDept.isEmpty;

          // Specifically is student ke liye?
          final bool isForMe = annDept == myDept &&
              annSem == mySem &&
              annShift == myShift;

          // Na sabke liye na is student ke liye — skip karo
          if (!isForAll && !isForMe) {
            _shownIds.add(id); // Remember karo taake baar baar check na ho
            continue;
          }

          // ✅ Notification title banao
          final bool urgent = data['isUrgent'] == true;
          final String title = urgent
              ? "⚠️ URGENT: ${data['title'] ?? 'New Announcement'}"
              : (data['title'] ?? 'New Announcement');
          final String body = data['desc'] ?? '';
          final String teacher = data['teacherName'] ?? 'Faculty';

          // ✅ Notification dikhao
          _shownIds.add(id);
          _showNotification(
            // int ID ke liye hashCode use karo (unique hoga)
            id: id.hashCode.abs() % 2147483647,
            title: title,
            body: body.isNotEmpty ? "$body\n— $teacher" : "By: $teacher",
            isUrgent: urgent,
          );

          print("🔔 Notification shown for announcement: $id");
        }
      },
      onError: (error) {
        // Silently fail — app crash nahi honi chahiye
        print("❌ AnnouncementListenerService error: $error");
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SHOW LOCAL NOTIFICATION
  // ─────────────────────────────────────────────────────────────────────────

  static Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
    bool isUrgent = false,
  }) async {
    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'high_importance_channel',
            'Campus Pulse Notifications',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            showWhen: true,
            // ✅ Urgent announcements red color mein
            color: isUrgent
                ? const Color(0xFFFF0000)
                : const Color(0xFF8B0A1A),
            icon: '@mipmap/ic_launcher',
            // ✅ Long text ke liye BigText style
            styleInformation: BigTextStyleInformation(
              body,
              htmlFormatBigText: false,
              contentTitle: title,
              htmlFormatContentTitle: false,
            ),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
      );
    } catch (e) {
      // Silently fail
      print("❌ Show notification error: $e");
    }
  }
}

// Needed for Color
