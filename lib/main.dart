// lib/main.dart
//
// CHANGES FROM PREVIOUS VERSION:
//   ✅ Removed _saveOneSignalIdToFirestore() — now handled inside OneSignalService
//   ✅ _initNetworkServices() is clean — no Firestore calls here
//   ✅ OneSignalService.initialize() called on mobile only (already guarded inside)
//   ✅ Web FCM permission + onMessage listener kept as-is (was already working)
//   ✅ runApp() still fires immediately — no blocking on network

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_database/firebase_database.dart';
import 'models/announcement_model.dart';
import 'services/notification_service.dart';
import 'services/onesignal_service.dart';
import 'Faculty/FacultyDashboard.dart';
import 'launcher_activity.dart';
import 'Authentication/login_activity.dart';
import 'Authentication/register_activity.dart';
import 'Authentication/reset_password_activity.dart';
import 'Student/Student_Dashboard.dart';
import '../chat/users_list_fragment.dart';
import 'Faculty/AnnouncementScreen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../Student/studentsignupactivity.dart';
import '../Faculty/FacultyDashboard.dart';
import 'Faculty/FacultySignupActivity.dart';
import 'Student/student_view_attendance.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BACKGROUND FCM HANDLER — must be top-level function
// ─────────────────────────────────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("📩 Background FCM: ${message.messageId}");
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 1. HIVE — local, no network ───────────────────────────────────────────
  await Hive.initFlutter();
  Hive.registerAdapter(AnnouncementAdapter());
  await Hive.openBox('dashboard_cache');
  await Hive.openBox('auth_cache');
  await Hive.openBox('settings');
  await dotenv.load(fileName: ".env");

  // ── 2. FIREBASE CORE ──────────────────────────────────────────────────────
  await Firebase.initializeApp(
    options: kIsWeb
        ? FirebaseOptions(
            apiKey           : dotenv.env['FIREBASE_WEB_API_KEY']            ?? '',
            authDomain       : dotenv.env['FIREBASE_WEB_AUTH_DOMAIN']        ?? '',
            databaseURL      : dotenv.env['FIREBASE_WEB_DATABASE_URL']       ?? '',
            projectId        : dotenv.env['FIREBASE_WEB_PROJECT_ID']         ?? '',
            storageBucket    : dotenv.env['FIREBASE_WEB_STORAGE_BUCKET']     ?? '',
            messagingSenderId: dotenv.env['FIREBASE_WEB_MESSAGING_SENDER_ID'] ?? '',
            appId            : dotenv.env['FIREBASE_WEB_APP_ID']             ?? '',
            measurementId    : dotenv.env['FIREBASE_WEB_MEASUREMENT_ID']     ?? '',
          )
        : null,
  );

  // ── 3. OFFLINE PERSISTENCE ────────────────────────────────────────────────
  if (!kIsWeb) {
    FirebaseDatabase.instance.setPersistenceEnabled(true);
    FirebaseDatabase.instance.setLoggingEnabled(false);
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled : true,
      cacheSizeBytes     : Settings.CACHE_SIZE_UNLIMITED,
    );
  }

  // ── 4. SHOW UI IMMEDIATELY ────────────────────────────────────────────────
  runApp(const MyApp());

  // ── 5. NETWORK SERVICES — deferred so UI is never blocked ─────────────────
  Future.microtask(() => _initNetworkServices());
}

// ─────────────────────────────────────────────────────────────────────────────
// NETWORK SERVICES INIT
// ─────────────────────────────────────────────────────────────────────────────
Future<void> _initNetworkServices() async {

  if (!kIsWeb) {
    // ── MOBILE ──────────────────────────────────────────────────────────────

    // FCM background handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Local notification service (shows banner inside app)
    try {
      await NotificationService.init();
      debugPrint("✅ NotificationService initialized");
    } catch (e) {
      debugPrint("❌ NotificationService init error: $e");
    }

    // FCM permission
    try {
      final settings = await FirebaseMessaging.instance
          .requestPermission(alert: true, badge: true, sound: true)
          .timeout(const Duration(seconds: 10));
      debugPrint("🔔 FCM Permission: ${settings.authorizationStatus}");
    } catch (e) {
      debugPrint("❌ FCM permission error (offline?): $e");
    }

    // FCM foreground listener — shows in-app notification banner
    try {
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint("📨 Foreground FCM: ${message.notification?.title}");
        if (message.notification != null) {
          NotificationService.show(message);
        }
      });
    } catch (e) {
      debugPrint("❌ FCM onMessage setup error: $e");
    }

    // FCM topic subscription
    try {
      await FirebaseMessaging.instance
          .subscribeToTopic("all_campus")
          .timeout(const Duration(seconds: 10));
      debugPrint("✅ FCM: Subscribed to all_campus");
    } catch (e) {
      debugPrint("❌ FCM topic error (offline?): $e");
    }

    // OneSignal — mobile SDK
    // Sub ID saving is now fully handled inside OneSignalService via observer
    try {
      await OneSignalService.initialize();
    } catch (e) {
      debugPrint("❌ OneSignal init error: $e");
    }

  } else {
    // ── WEB ─────────────────────────────────────────────────────────────────

    // FCM web — handles browser push notifications
    try {
      final settings = await FirebaseMessaging.instance
          .requestPermission(alert: true, badge: true, sound: true)
          .timeout(const Duration(seconds: 10));
      debugPrint("🔔 FCM Web Permission: ${settings.authorizationStatus}");

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint("📨 Foreground FCM (web): ${message.notification?.title}");
      });
    } catch (e) {
      debugPrint("❌ FCM web permission error (offline?): $e");
    }

    // OneSignal web — SDK not available, REST API used for all sends
    debugPrint("ℹ️ OneSignal Web: REST API active for sending notifications");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// APP
// ─────────────────────────────────────────────────────────────────────────────
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Campus Pulse',
      theme: ThemeData(
        primaryColor: const Color(0xFF8B0A1A),
        colorScheme: ColorScheme.fromSeed(
          seedColor : const Color(0xFF8B0A1A),
          primary   : const Color(0xFF8B0A1A),
        ),
        scaffoldBackgroundColor: const Color(0xFFFDF7F7),
      ),
      home: const LauncherActivity(),
      routes: {
        '/login'                  : (context) => const LoginActivity(),
        '/register'               : (context) => const RegisterActivity(),
        '/reset_password'         : (context) => const ResetPasswordActivity(),
        '/faculty_dashboard'      : (context) => const FacultyDashBoard(),
        '/student_dashboard'      : (context) => const StudentDashboard(),
        '/users_list_fragment'    : (context) => const UsersListFragment(),
        '/faculty_announcement'   : (context) => const AnnouncementFragment(),
        '/studentsignupactivity'  : (context) => const StudentSignupActivity(),
        '/faculty_signup'         : (context) => const FacultySignupActivity(),
        '/student_view_attendance': (context) => const StudentViewAttendance(),
      },
    );
  }
}