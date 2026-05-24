// lib/services/fcm_web_service.dart
// ─────────────────────────────────────────────────────────────────────────────
// Web pe FCM notifications handle karta hai
// Mobile pe OneSignalService kaam karta hai — ye sirf web ke liye hai
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FcmWebService {
  // ✅ Tumhari VAPID key
  static const String _vapidKey =
      'BDeFNlJj2vXVPQAOpAB29DIpfBLW_HcigLIIbp40bW0zwVJFjKH6kKlq4qrOqOKwtWSHtW8RdPqrfKdbKiudhg0';

  // ─────────────────────────────────────────────────────────────────────────
  // INITIALIZE — web pe call karo main.dart se
  // Permission maango → token lo → Firestore mein save karo
  // ─────────────────────────────────────────────────────────────────────────
  static Future<void> initialize() async {
    if (!kIsWeb) return; // Mobile pe kuch nahi karna

    try {
      // Step 1: Permission maango
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      ).timeout(const Duration(seconds: 10));

      debugPrint('🔔 FCM Web Permission: ${settings.authorizationStatus}');

      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        debugPrint('⚠️ FCM Web: Permission not granted');
        return;
      }

      // Step 2: VAPID key se web token lo
      final token = await FirebaseMessaging.instance
          .getToken(vapidKey: _vapidKey)
          .timeout(const Duration(seconds: 15));

      if (token == null) {
        debugPrint('⚠️ FCM Web: Token null — service worker registered?');
        return;
      }

      debugPrint('✅ FCM Web Token: $token');

      // Step 3: Firestore mein save karo
      await _saveTokenToFirestore(token);

      // Step 4: Token refresh listener
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        debugPrint('🔄 FCM Web Token refreshed');
        _saveTokenToFirestore(newToken);
      });

      // Step 5: Foreground message listener
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('📨 FCM Web Foreground: ${message.notification?.title}');
        // Flutter app open ho to bhi browser notification dikhao
        _showBrowserNotification(
          title: message.notification?.title ?? 'Campus Pulse',
          body: message.notification?.body ?? '',
        );
      });

      debugPrint('✅ FcmWebService initialized');
    } catch (e) {
      debugPrint('❌ FcmWebService initialize error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SAVE TOKEN TO FIRESTORE
  // Ye token FCM REST API call mein use hoga specific user ko target karne ke liye
  // ─────────────────────────────────────────────────────────────────────────
  static Future<void> _saveTokenToFirestore(String token) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('ℹ️ FCM Web: User not logged in — token will save on next login');
        return;
      }

      await FirebaseFirestore.instance
          .collection('Users')
          .doc(user.uid)
          .set({
        'fcmWebToken': token,
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));

      debugPrint('✅ FCM Web token saved to Firestore for uid=${user.uid}');
    } catch (e) {
      debugPrint('❌ FCM Web token save error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SAVE TOKEN AFTER LOGIN
  // Login ke baad call karo — tab user logged in hota hai
  // ─────────────────────────────────────────────────────────────────────────
  static Future<void> saveTokenAfterLogin() async {
    if (!kIsWeb) return;
    try {
      final token = await FirebaseMessaging.instance
          .getToken(vapidKey: _vapidKey)
          .timeout(const Duration(seconds: 15));
      if (token != null) {
        await _saveTokenToFirestore(token);
      }
    } catch (e) {
      debugPrint('❌ FCM Web saveTokenAfterLogin: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BROWSER NOTIFICATION (foreground mein bhi dikhao)
  // ─────────────────────────────────────────────────────────────────────────
  static void _showBrowserNotification({
    required String title,
    required String body,
  }) {
    // JS interop ke bina simple approach — FCM background handler
    // service worker mein already handle ho raha hai
    // Foreground ke liye Flutter UI bell icon update karo (dashboard mein)
    debugPrint('🔔 Browser Notification: $title — $body');
  }
}