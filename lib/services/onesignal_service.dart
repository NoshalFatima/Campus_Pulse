
// lib/services/onesignal_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:onesignal_flutter/onesignal_flutter.dart';

class OneSignalService {
  static String get _appId      => dotenv.env['ONESIGNAL_APP_ID']       ?? '';
  static String get _restApiKey => dotenv.env['ONESIGNAL_REST_API_KEY'] ?? '';
  static const  String _baseUrl = 'https://onesignal.com/api/v1/notifications';

  static Map<String, String> get _headers => {
    'Content-Type' : 'application/json; charset=utf-8',
    'Authorization': 'Key $_restApiKey',
  };

  // Completer resolves when observer fires with a valid sub ID
  static Completer<String>? _subIdCompleter;

  // ─── TAG BUILDER ──────────────────────────────────────────────────────────
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

  // ─── INITIALIZE ───────────────────────────────────────────────────────────
  // Call once in main.dart after runApp()
  static Future<void> initialize() async {
    if (kIsWeb) {
      debugPrint('ℹ️ OneSignal: Web — REST API only');
      return;
    }
    try {
      OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
      OneSignal.initialize(_appId);

      await OneSignal.Notifications.requestPermission(true)
          .timeout(const Duration(seconds: 10));

      OneSignal.User.pushSubscription.optIn();

      // ✅ Single observer — handles ALL sub ID assignments
      // Fires when: app first launches, after login(), after user switch
      OneSignal.User.pushSubscription.addObserver((state) {
        final subId = state.current.id;
        debugPrint('🔔 Observer fired — subId: ${subId ?? "null"}');

        if (subId != null && subId.isNotEmpty) {
          // Complete the completer if loginUser() is waiting
          if (_subIdCompleter != null && !_subIdCompleter!.isCompleted) {
            _subIdCompleter!.complete(subId);
          }
          // Always save to Firestore when ID is available
          _saveSubIdToFirestore(subId);
        }
      });

      debugPrint('✅ OneSignal initialized (mobile)');
    } catch (e) {
      debugPrint('❌ OneSignal initialize: $e');
    }
  }

  // ─── LOGIN ────────────────────────────────────────────────────────────────
  // Call right after Firebase sign-in — before navigation
  static Future<void> loginUser(String firebaseUid) async {
    if (kIsWeb) {
      debugPrint('ℹ️ OneSignal Web: login skipped — REST API targets uid directly');
      return;
    }
    try {
      // Set up completer BEFORE login() so observer can resolve it
      _subIdCompleter = Completer<String>();

      await OneSignal.login(firebaseUid);
      debugPrint('✅ OneSignal login called: uid=$firebaseUid');

      // Check if sub ID is already available (cached from previous session)
      final existingId = OneSignal.User.pushSubscription.id;
      if (existingId != null && existingId.isNotEmpty) {
        debugPrint('✅ Sub ID already available: $existingId');
        if (!_subIdCompleter!.isCompleted) {
          _subIdCompleter!.complete(existingId);
        }
      }

      // Wait for observer to fire with sub ID — max 15 seconds
      // Observer fires when OneSignal server assigns the ID after login()
      final subId = await _subIdCompleter!.future
          .timeout(const Duration(seconds: 15), onTimeout: () {
        debugPrint('⚠️ Sub ID timeout after 15s — will save via observer later');
        return '';
      });

      if (subId.isNotEmpty) {
        await _saveSubIdToFirestore(subId);
      } else {
        debugPrint('ℹ️ Sub ID not received in time — observer will save when ready');
      }
    } catch (e) {
      debugPrint('⚠️ OneSignal loginUser: $e');
    } finally {
      _subIdCompleter = null;
    }
  }

  // ─── SAVE TO FIRESTORE ────────────────────────────────────────────────────
  static Future<void> _saveSubIdToFirestore(String subId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('Users')
            .doc(user.uid)
            .set({
          'oneSignalSubId': subId,
          'updatedAt'     : FieldValue.serverTimestamp(),
        }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 10));
        debugPrint('✅ Sub ID saved → Firestore: $subId');
      } else {
        debugPrint('ℹ️ No Firebase user yet — observer will retry on next event');
      }
    } catch (e) {
      debugPrint('❌ _saveSubIdToFirestore: $e');
    }
  }

  // ─── LOGOUT ───────────────────────────────────────────────────────────────
  static Future<void> logoutUser() async {
    if (kIsWeb) return;
    try {
      await clearStudentTags();
      await OneSignal.logout();
      _subIdCompleter = null;
      debugPrint('✅ OneSignal logout');
    } catch (e) {
      debugPrint('⚠️ OneSignal logout: $e');
    }
  }

  // ─── REGISTER CLASS TAG ───────────────────────────────────────────────────
  static Future<void> registerStudentClassTag({
    required String dept,
    required String sem,
    required String shift,
  }) async {
    if (kIsWeb) return;
    if (dept.isEmpty || sem.isEmpty) return;
    try {
      final tag = buildClassTag(dept: dept, sem: sem, shift: shift);
      await OneSignal.User.addTags({
        'class_tag'      : tag,
        'all_campus_tag' : 'true',
        'role'           : 'student',
      });
      debugPrint('✅ Tags set → class_tag=$tag');
    } catch (e) {
      debugPrint('❌ registerStudentClassTag: $e');
    }
  }

  // ─── CLEAR TAGS ───────────────────────────────────────────────────────────
  static Future<void> clearStudentTags() async {
    if (kIsWeb) return;
    try {
      await OneSignal.User.removeTags(['class_tag', 'all_campus_tag', 'role']);
      debugPrint('✅ Tags cleared');
    } catch (e) {
      debugPrint('❌ clearStudentTags: $e');
    }
  }

  // ─── SEND TO CLASS ────────────────────────────────────────────────────────
  static Future<bool> sendToSpecific({
    required String title,
    required String body,
    required String dept,
    required String sem,
    required String shift,
    String? imageUrl,
    Map<String, String>? data,
  }) async {
    final classValue = buildClassTag(dept: dept, sem: sem, shift: shift);
    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: _headers,
        body: jsonEncode({
          'app_id'             : _appId,
          'filters'            : [
            {'field': 'tag', 'key': 'class_tag', 'relation': '=', 'value': classValue},
          ],
          'headings'           : {'en': title},
          'contents'           : {'en': body},
          'small_icon'         : 'logo1',
          'priority'           : 10,
          'android_visibility' : 1,
          'android_accent_color': 'FF8B0A1A',
          if (imageUrl != null) 'large_icon' : imageUrl,
          if (imageUrl != null) 'big_picture': imageUrl,
          'data': {'type': 'attendance', ...?data},
        }),
      );
      return _handleResponse(response, 'Class-Specific');
    } catch (e) {
      debugPrint('❌ sendToSpecific: $e');
      return false;
    }
  }

  // ─── BROADCAST ALL ────────────────────────────────────────────────────────
  static Future<bool> sendToAll({
    required String title,
    required String body,
    Map<String, String>? data,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: _headers,
        body: jsonEncode({
          'app_id'  : _appId,
          'filters' : [
            {'field': 'tag', 'key': 'all_campus_tag', 'relation': '=', 'value': 'true'},
          ],
          'headings': {'en': title},
          'contents': {'en': body},
          'small_icon': 'logo1',
          'priority': 10,
          'data'    : {'type': 'announcement', ...?data},
        }),
      );
      return _handleResponse(response, 'Broadcast');
    } catch (e) {
      debugPrint('❌ sendToAll: $e');
      return false;
    }
  }

  // ─── SEND TO USER (Chat) ──────────────────────────────────────────────────
  static Future<bool> sendToUser({
    required String title,
    required String body,
    required String firebaseUid,
    Map<String, String>? data,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: _headers,
        body: jsonEncode({
          'app_id'          : _appId,
          'include_aliases' : {'external_id': [firebaseUid]},
          'target_channel'  : 'push',
          'headings'        : {'en': title},
          'contents'        : {'en': body},
          'small_icon'      : 'logo1',
          'priority'        : 10,
          'android_visibility': 1,
          'data'            : {'type': 'chat', ...?data},
        }),
      );
      return _handleResponse(response, 'User-Specific');
    } catch (e) {
      debugPrint('❌ sendToUser: $e');
      return false;
    }
  }

  // ─── RESPONSE HANDLER ─────────────────────────────────────────────────────
  static bool _handleResponse(http.Response response, String type) {
    debugPrint('📬 [$type] Status: ${response.statusCode}');
    if (response.statusCode == 200) {
      final result     = jsonDecode(response.body) as Map<String, dynamic>;
      final recipients = result['recipients'] ?? 0;
      debugPrint('✅ [$type] Delivered to $recipients devices');
      if (recipients == 0) {
        debugPrint('⚠️ 0 recipients — check tags are set after loginUser()');
      }
      return true;
    }
    debugPrint('❌ [$type] Error: ${response.body}');
    return false;
  }
}
