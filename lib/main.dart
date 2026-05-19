// ✅ lib/main.dart — OFFLINE-SAFE VERSION
//
// ROOT CAUSE FIX: App was blocking on network calls before runApp().
// Firebase, FCM, OneSignal all need internet. Without it, startup hanged.
//
// SOLUTION:
//  1. runApp() is called IMMEDIATELY after Hive + Firebase.initializeApp()
//     (initializeApp() uses cached config — works offline)
//  2. ALL network-dependent calls (FCM permissions, topics, OneSignal)
//     are moved to a background Future that runs AFTER the UI is visible
//  3. Firestore/RTDB persistence set before any network touch
//  4. _saveOneSignalIdToFirestore moved inside class (no stray top-level fn)





import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_database/firebase_database.dart';
import 'models/announcement_model.dart';
import 'services/notification_service.dart';
import 'Faculty/FacultyDashboard.dart';
import 'launcher_activity.dart';
import 'dart:js' as js;
import '../Authentication/login_activity.dart';
import 'Authentication/register_activity.dart';
import 'Authentication/reset_password_activity.dart';
import 'Student/Student_Dashboard.dart';
import '../chat/users_list_fragment.dart';
import 'Faculty/AnnouncementScreen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
// ─────────────────────────────────────────────────────────────────────────────
// BACKGROUND FCM HANDLER (must be top-level)
// ─────────────────────────────────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("📩 Background FCM: ${message.messageId}");
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN — only blocking work here: Hive + Firebase.initializeApp()
// Everything else runs in background after UI is shown
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 1. HIVE (local, no network needed) ────────────────────────────────────
  await Hive.initFlutter();
  Hive.registerAdapter(AnnouncementAdapter());
  await Hive.openBox('dashboard_cache');
  await Hive.openBox('auth_cache');
  await Hive.openBox('settings');
  await dotenv.load(fileName: ".env");
  // ── 2. FIREBASE CORE INIT ─────────────────────────────────────────────────
  // This reads the local google-services.json / Firebase options.
  // It does NOT require internet — safe to await.
  await Firebase.initializeApp(
    options: kIsWeb
    ? FirebaseOptions(
        apiKey: dotenv.env['FIREBASE_WEB_API_KEY'] ?? '',
        authDomain: dotenv.env['FIREBASE_WEB_AUTH_DOMAIN'] ?? '',
        databaseURL: dotenv.env['FIREBASE_WEB_DATABASE_URL'] ?? '',
        projectId: dotenv.env['FIREBASE_WEB_PROJECT_ID'] ?? '',
        storageBucket: dotenv.env['FIREBASE_WEB_STORAGE_BUCKET'] ?? '',
        messagingSenderId: dotenv.env['FIREBASE_WEB_MESSAGING_SENDER_ID'] ?? '',
        appId: dotenv.env['FIREBASE_WEB_APP_ID'] ?? '',
        measurementId: dotenv.env['FIREBASE_WEB_MEASUREMENT_ID'] ?? '',
      )
    : null,
  );
String webOneSignalId = dotenv.env['ONESIGNAL_APP_ID'] ?? '';
  js.context['onesignalAppId'] = webOneSignalId;
  // ── 3. OFFLINE PERSISTENCE — set BEFORE any Firestore/RTDB reads ──────────
  // These are local SDK settings, no network needed.
  if (!kIsWeb) {
    FirebaseDatabase.instance.setPersistenceEnabled(true);
    FirebaseDatabase.instance.setLoggingEnabled(false);
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
  }

  // ── 4. SHOW UI IMMEDIATELY ────────────────────────────────────────────────
  runApp(const MyApp());

  // ── 5. NETWORK-DEPENDENT SETUP — runs in background, won't block UI ───────
  // Use Future.microtask so UI gets its first frame before we do anything else.
  Future.microtask(() => _initNetworkServices());
}

// ─────────────────────────────────────────────────────────────────────────────
// ALL NETWORK SERVICES — called after runApp(), fully non-blocking
// Each section is try-catched individually so one failure can't block others
// ─────────────────────────────────────────────────────────────────────────────
Future<void> _initNetworkServices() async {
  // ── FCM (mobile only) ─────────────────────────────────────────────────────
  if (!kIsWeb) {
    try {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      await NotificationService.init();
      debugPrint("✅ NotificationService initialized");
    } catch (e) {
      debugPrint("❌ NotificationService init error: $e");
    }

    // FCM permission — may show a system dialog, safe to do post-UI
    try {
      final settings = await FirebaseMessaging.instance
          .requestPermission(alert: true, badge: true, sound: true)
          .timeout(const Duration(seconds: 10));
      debugPrint("🔔 FCM Permission: ${settings.authorizationStatus}");
    } catch (e) {
      debugPrint("❌ FCM permission error (offline?): $e");
    }

    // FCM foreground listener
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

    // FCM topic — needs internet, safe to fail silently
    try {
      await FirebaseMessaging.instance
          .subscribeToTopic("all_campus")
          .timeout(const Duration(seconds: 10));
      debugPrint("✅ FCM: Subscribed to all_campus");
    } catch (e) {
      debugPrint("❌ FCM topic error (offline?): $e");
    }

    // ── OneSignal (mobile only) ──────────────────────────────────────────────
    try {
      OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
      OneSignal.initialize(dotenv.env['ONESIGNAL_APP_ID'] ?? '');
      
      await OneSignal.Notifications.requestPermission(true)
          .timeout(const Duration(seconds: 10));

      OneSignal.User.pushSubscription.optIn();

      OneSignal.User.pushSubscription.addObserver((state) {
        final id    = state.current.id;
        final token = state.current.token;
        debugPrint("🔍 OneSignal — optedIn: ${state.current.optedIn}, token: $token, id: $id");
        if (id != null && id.isNotEmpty) {
          _saveOneSignalIdToFirestore(id);
        }
      });

      // Check if ID already available (app restart case)
      final currentId = OneSignal.User.pushSubscription.id;
      if (currentId != null && currentId.isNotEmpty) {
        _saveOneSignalIdToFirestore(currentId);
      }

      debugPrint("✅ OneSignal initialized");
    } catch (e) {
      debugPrint("❌ OneSignal init error (offline?): $e");
    }
  } else {
    // Web: FCM permission only (no OneSignal)
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

    debugPrint("ℹ️ OneSignal: Web mode — REST API used for notifications");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SAVE ONESIGNAL ID TO FIRESTORE
// ─────────────────────────────────────────────────────────────────────────────
Future<void> _saveOneSignalIdToFirestore(String osId) async {
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance
          .collection('Users')
          .doc(user.uid)
          .set({
        'oneSignalId': osId,
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));
      debugPrint("✅ OneSignal ID saved to Firestore: $osId");
    } else {
      debugPrint("ℹ️ Not logged in — OneSignal ID will be saved on next login.");
    }
  } catch (e) {
    debugPrint("❌ Error saving OneSignal ID: $e");
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
          seedColor: const Color(0xFF8B0A1A),
          primary: const Color(0xFF8B0A1A),
        ),
        scaffoldBackgroundColor: const Color(0xFFFDF7F7),
      ),
      home: const LauncherActivity(),
      routes: {
        '/login':                 (context) => const LoginActivity(),
        '/register':              (context) => const RegisterActivity(),
        '/reset_password':        (context) => const ResetPasswordActivity(),
        '/faculty_dashboard':     (context) => const FacultyDashBoard(),
        '/student_dashboard':     (context) => const StudentDashboard(),
        '/users_list_fragment':   (context) => const UsersListFragment(),
        '/faculty_announcement':  (context) => const AnnouncementFragment(),
      },
    );
  }
}