// ✅ lib/services/notification_service.dart — FINAL VERSION

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // ─────────────────────────────────────────────────────────────────────────
  // INIT — call once in main() with await
  // Creates Android channel + requests permission
  // ─────────────────────────────────────────────────────────────────────────
  static Future<void> init() async {
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

    // ✅ Create high importance channel — must match channel_id used in show()
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'high_importance_channel',
      'Campus Pulse Notifications',
      description: 'Announcements and chat message notifications',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // ✅ Request Android 13+ runtime permission
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SHOW — displays heads-up notification when app is in foreground
  // ─────────────────────────────────────────────────────────────────────────
  static Future<void> show(RemoteMessage message) async {
    if (message.notification == null) return;

    await _plugin.show(
      DateTime.now().millisecond, // unique id per notification
      message.notification!.title,
      message.notification!.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'high_importance_channel', // ✅ must match channel created above
          'Campus Pulse Notifications',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          showWhen: true,
          color: Color(0xFF8B0A1A),
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }
}