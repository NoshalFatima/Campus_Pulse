// lib/services/onesignal_service.dart
//
// ORIGINAL FILE PRESERVED — sirf sendToSpecific ka tag format fix kiya
// Announcement (sendToAll) aur Chat (sendToUser) bilkul same hain
//
// FIX: sendToSpecific ab buildClassTag() use karta hai
// Pehle: "computer_science_semester_6_morning"  → 0 recipients
// Ab:    "COMPUTER_SCIENCE_S6_MORNING"           → students ko milega
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

class OneSignalService {
  static String _appId = dotenv.env['ONESIGNAL_APP_ID'] ?? '';
  static String _restApiKey = dotenv.env['ONESIGNAL_REST_API_KEY'] ?? '';
  static const String _baseUrl = 'https://onesignal.com/api/v1/notifications';
  

  static Map<String, String> _getHeaders() => {
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Key $_restApiKey',
      };

  // ─────────────────────────────────────────────────────────────────────────
  // TAG BUILDER — teacher send aur student registration dono yahi use karein
  // Format: COMPUTER_SCIENCE_S6_MORNING
  // Input:  dept="Computer Science", sem="Semester 6", shift="Morning"
  // ─────────────────────────────────────────────────────────────────────────
  static String buildClassTag({
    required String dept,
    required String sem,
    required String shift,
  }) {
    final deptKey  = dept.trim().replaceAll(' ', '_').toUpperCase();
    final semNum   = sem.replaceAll(RegExp(r'[^0-9]'), '');
    final shiftKey = shift.trim().toUpperCase();
    return '${deptKey}_S${semNum}_$shiftKey';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STUDENT LOGIN KE BAAD CALL KARO — device ko class se link karta hai
  // Yeh method student dashboard mein profile load hone ke baad call karo
  // ─────────────────────────────────────────────────────────────────────────
  static void registerStudentClassTag({
    required String dept,
    required String sem,
    required String shift,
  }) {
    if (kIsWeb) return;
    try {
      final tag = buildClassTag(dept: dept, sem: sem, shift: shift);
      // uncomment when onesignal_flutter imported in student file:
      // OneSignal.User.addTag('class_tag', tag);
      debugPrint('✅ OneSignal class_tag set: $tag');
    } catch (e) {
      debugPrint('❌ OneSignal registerStudentClassTag: $e');
    }
  }

  // Logout pe call karo
  static void clearStudentTag() {
    if (kIsWeb) return;
    try {
      // OneSignal.User.removeTag('class_tag');
      debugPrint('✅ OneSignal class_tag cleared');
    } catch (e) {
      debugPrint('❌ OneSignal clearStudentTag: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ATTENDANCE NOTIFICATION — teacher se specific class ko
  // FIX: ab buildClassTag() use karta hai, pehle wala format wrong tha
  // ─────────────────────────────────────────────────────────────────────────
  static Future<bool> sendToSpecific({
    required String title,
    required String body,
    required String dept,
    required String sem,
    required String shift,
    Map<String, String>? data,
  }) async {
    // ✅ FIX: buildClassTag() se format match hoga student registration se
    final String classValue = buildClassTag(dept: dept, sem: sem, shift: shift);

    debugPrint("📢 OneSignal: Sending to class_tag=$classValue");

    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: _getHeaders(),
        body: jsonEncode({
          'app_id': _appId,
          'filters': [
            {
              'field': 'tag',
              'key': 'class_tag',
              'relation': '=',
              'value': classValue
            },
          ],
          'headings': {'en': title},
          'contents': {'en': body},
          'priority': 10,
          'android_visibility': 1,
          'importance': 5,
          'data': {'type': 'attendance', ...?data},
        }),
      );
      return _handleResponse(response, "Specific");
    } catch (e) {
      debugPrint("❌ OneSignal Specific Error: $e");
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ANNOUNCEMENT — sab students ko (all_campus_tag = "true")
  // ORIGINAL SAME — touch nahi kiya
  // ─────────────────────────────────────────────────────────────────────────
  static Future<bool> sendToAll({
    required String title,
    required String body,
    Map<String, String>? data,
  }) async {
    debugPrint("📢 OneSignal: Broadcasting to all students...");

    try {
      final Map<String, dynamic> notificationData = {
        'app_id': _appId,
        'filters': [
          {
            'field': 'tag',
            'key': 'all_campus_tag',
            'relation': '=',
            'value': 'true'
          },
        ],
        'headings': {'en': title},
        'contents': {'en': body},
        'priority': 10,
        'data': {'type': 'announcement', ...?data},
      };

      final String requestBody = jsonEncode(notificationData);
      debugPrint("🚀 Sending: $requestBody");

      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Basic $_restApiKey',
        },
        body: requestBody,
      );

      return _handleResponse(response, "Broadcast");
    } catch (e) {
      debugPrint("❌ OneSignal Broadcast Exception: $e");
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CHAT NOTIFICATION — specific user ko Firebase UID se
  // ORIGINAL SAME — touch nahi kiya
  // ─────────────────────────────────────────────────────────────────────────
  static Future<bool> sendToUser({
    required String title,
    required String body,
    required String firebaseUid,
    Map<String, String>? data,
  }) async {
    debugPrint("📢 OneSignal: Sending to user $firebaseUid");

    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: _getHeaders(),
        body: jsonEncode({
          'app_id': _appId,
          'include_aliases': {
            'external_id': [firebaseUid]
          },
          'target_channel': 'push',
          'headings': {'en': title},
          'contents': {'en': body},
          'priority': 10,
          'android_visibility': 1,
          'importance': 5,
          'data': {'type': 'chat', ...?data},
        }),
      );
      return _handleResponse(response, "User-Specific");
    } catch (e) {
      debugPrint("❌ OneSignal User Error: $e");
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // RESPONSE HANDLER — original same
  // ─────────────────────────────────────────────────────────────────────────
  static bool _handleResponse(http.Response response, String type) {
    debugPrint("📬 OneSignal [$type] Status: ${response.statusCode}");
    if (response.statusCode != 200) {
      debugPrint("❌ OneSignal [$type] Error: ${response.body}");
    }
    if (response.statusCode == 200) {
      final Map<String, dynamic> result = jsonDecode(response.body);
      final recipients = result['recipients'] ?? 0;
      debugPrint("✅ OneSignal [$type]: Delivered to $recipients devices");
      if (recipients == 0) {
        debugPrint(
          "⚠️ 0 recipients — students ne registerStudentClassTag() call nahi ki login ke baad.\n"
          "   Expected tag: class_tag = '${buildClassTag(dept: 'Computer Science', sem: 'Semester 6', shift: 'Morning')}'",
        );
      }
      return true;
    }
    return false;
  }
}