// ✅ lib/chat/chat_screen.dart — UPDATED (Group features added)
//
// ORIGINAL FEATURES — untouched:
// ✅ Hive offline cache + offline banner
// ✅ OneSignal push notification (1-1)
// ✅ 3-state tick system (sent / delivered / read)
// ✅ Emoji reactions
// ✅ Reply threading (reply preview + scroll to original)
// ✅ Delete for me / delete for everyone
// ✅ Clear chat
// ✅ Forward message
// ✅ File upload via Cloudinary (image + PDF)
// ✅ Download file (Android + Web)
// ✅ Chat theme (background color, SharedPreferences)
// ✅ Date separators
// ✅ Scroll to replied message (GlobalKey)
// ✅ Mark delivered + read on open / app resume
//
// NEW — GROUP ADDITIONS ONLY:
// ✅ currentUserRole param → _isTeacher getter
// ✅ Group DP upload → Cloudinary → Firestore (teacher only)
// ✅ Announcement mode toggle (teacher only) → special bubble type
// ✅ Admin-only mode — _listenForPrivacyChanges now uses Firestore (was RTDB bug)
// ✅ _showPrivacyDialog now writes to Firestore Groups (fixed)
// ✅ OneSignal to ALL group members (_sendOneSignalToGroup)
// ✅ Members dialog
// ✅ AppBar: group DP tap (teacher), admin-only badge, members button
// ✅ Firestore lastMessage update on group send

import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:universal_html/html.dart' as html;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/chat_models.dart';
import 'chat_bubble.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
const String _kChatBoxPrefix = 'chat_cache_';

class ChatScreen extends StatefulWidget {
  final String partnerId;
  final String partnerName;
  final String partnerPic;
  final String partnerDept;
  final String? receiverId;
  final bool isGroup;
  // ── NEW: role for group-specific UI ──────────────────────────────────────
  final String currentUserRole;

  const ChatScreen({
    super.key,
    required this.partnerId,
    required this.partnerName,
    required this.partnerPic,
    required this.partnerDept,
    required this.receiverId,
    this.isGroup        = false,
    this.currentUserRole = 'student', // ← NEW (default safe for 1-1 use)
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver {
  // ── original fields (unchanged) ──────────────────────────────────────────
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController       = ScrollController();
  final String currentUserId = FirebaseAuth.instance.currentUser!.uid;
  final Map<String, GlobalKey> _messageKeys = {};

  static String _kOneSignalAppId = dotenv.env['ONESIGNAL_APP_ID'] ?? '';
  static String _kOneSignalRestKey = dotenv.env['ONESIGNAL_REST_API_KEY'] ?? '';
  String     currentUserName  = '';
  ChatMessage? replyingTo;
  Color      _currentBgColor  = const Color(0xFFF0EDE8);
  bool       isAdminOnly      = false;
  String     groupAdminId     = '';
  late DatabaseReference _chatDbRef;
  late String chatId;

  String _cloudName = dotenv.env['CLOUDINARY_CLOUD_NAME'] ?? '';
String _uploadPreset = dotenv.env['CLOUDINARY_UPLOAD_PRESET'] ?? '';

  bool _isAppInForeground = true;

  // Hive + offline
  Box<ChatMessage>? _hiveBox;
  List<ChatMessage> _cachedMessages = [];
  bool _isOnline = true;

  // ── NEW group state ───────────────────────────────────────────────────────
  bool   _isAnnouncement  = false; // teacher toggle
  bool   _isUploadingDp   = false; // group DP upload spinner
  String _currentGroupPic = '';    // live-updated from Firestore

  // Raw RTDB map for type lookup (announcement vs text/image/doc)
  // Key = messageId, value = raw Firebase map
  final Map<String, Map> _rawMsgMap = {};

  // ── NEW getters ───────────────────────────────────────────────────────────
  bool get _isTeacher => widget.currentUserRole.toLowerCase() == 'teacher';
  bool get _canSend   => !isAdminOnly || currentUserId == groupAdminId;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentGroupPic = widget.partnerPic; // init with passed pic
    _initChat();
    _loadSavedTheme();
    _loadCurrentUserProfile();
    if (widget.isGroup) _listenForPrivacyChanges();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
    if (_isAppInForeground) _markMessagesDeliveredAndRead();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HIVE (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _openHiveBox(String id) async {
    if (kIsWeb) return;
    try {
      final boxName =
          '$_kChatBoxPrefix${id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(ChatMessageAdapter());
      }
      _hiveBox = await Hive.openBox<ChatMessage>(boxName);
      _loadFromHive();
    } catch (e) {
      debugPrint('❌ Hive: $e');
    }
  }

  void _loadFromHive() {
    if (_hiveBox == null) return;
    final cached = _hiveBox!.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (mounted) setState(() => _cachedMessages = cached);
  }

  Future<void> _saveMessagesToHive(List<ChatMessage> messages) async {
    if (_hiveBox == null || kIsWeb) return;
    try {
      final toSave =
          messages.length > 200 ? messages.sublist(0, 200) : messages;
      await _hiveBox!.clear();
      await _hiveBox!.putAll({for (final m in toSave) m.messageId: m});
    } catch (e) {
      debugPrint('❌ Hive save: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // INIT CHAT (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  void _initChat() {
    chatId = widget.isGroup
        ? widget.partnerId
        : (currentUserId.compareTo(widget.partnerId) < 0
            ? '${currentUserId}_${widget.partnerId}'
            : '${widget.partnerId}_$currentUserId');

    _chatDbRef = FirebaseDatabase.instance
        .ref(widget.isGroup ? 'GroupMessages' : 'Chats')
        .child(chatId);

    _openHiveBox(chatId);
    _markMessagesDeliveredAndRead();

    _chatDbRef.onChildAdded
        .listen((e) => _markSingleMessageDeliveredAndRead(e.snapshot));
    _chatDbRef.onChildChanged
        .listen((e) => _markSingleMessageDeliveredAndRead(e.snapshot));
  }

  void _markSingleMessageDeliveredAndRead(DataSnapshot snapshot) {
    try {
      if (snapshot.value == null || snapshot.value is! Map) return;
      final Map msg = snapshot.value as Map;
      if (msg['senderId']?.toString() == currentUserId) return;
      if (msg['isDeleted'] == true) return;
      final Map<String, dynamic> updates = {};
      if (msg['isDelivered'] != true) updates['isDelivered'] = true;
      if (msg['isRead'] != true)      updates['isRead']      = true;
      if (updates.isNotEmpty) _chatDbRef.child(snapshot.key!).update(updates);
    } catch (e) {
      debugPrint('❌ markSingle: $e');
    }
  }

  void _loadCurrentUserProfile() async {
    final doc = await FirebaseFirestore.instance
        .collection('Users').doc(currentUserId).get();
    if (doc.exists && mounted) {
      setState(() => currentUserName = doc.data()?['name'] ?? 'User');
    }
  }

  void _loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final hex = prefs.getString('bg_color_$chatId');
    if (hex != null && mounted) {
      setState(() => _currentBgColor =
          Color(int.parse(hex.replaceFirst('#', '0xff'))));
    }
  }

  void _markMessagesDeliveredAndRead() {
    _chatDbRef.get().then((snap) {
      if (!snap.exists) return;
      for (final child in snap.children) {
        if (child.value == null || child.value is! Map) continue;
        final Map msg = child.value as Map;
        if (msg['senderId']?.toString() == currentUserId) continue;
        if (msg['isDeleted'] == true) continue;
        final Map<String, dynamic> updates = {};
        if (msg['isDelivered'] != true) updates['isDelivered'] = true;
        if (msg['isRead'] != true)      updates['isRead']      = true;
        if (updates.isNotEmpty) child.ref.update(updates);
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVACY — ✅ FIXED: now uses Firestore instead of RTDB
  // ─────────────────────────────────────────────────────────────────────────
  void _listenForPrivacyChanges() {
    FirebaseFirestore.instance
        .collection('Groups')
        .doc(chatId)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final d = snap.data()!;
      setState(() {
        isAdminOnly      = d['isAdminOnly'] ?? false;
        groupAdminId     = d['createdBy']   ?? '';
        _currentGroupPic = d['groupPic']    ?? widget.partnerPic;
      });
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SEND MESSAGE — original preserved + type field + group notification
  // ─────────────────────────────────────────────────────────────────────────
  void _sendMessage({String? manualText, String msgType = 'text'}) async {
    final text = manualText ?? _messageController.text.trim();
    if (text.isEmpty) return;

    if (currentUserName.isEmpty) {
      final doc = await FirebaseFirestore.instance
          .collection('Users').doc(currentUserId).get();
      if (doc.exists) currentUserName = doc.data()?['name'] ?? 'User';
    }

    final ref = _chatDbRef.push();

    // Determine final type
    final String finalType = manualText != null
        ? msgType
        : (widget.isGroup && _isAnnouncement ? 'announcement' : 'text');

    final Map<String, dynamic> messageData = {
      'messageId':  ref.key,
      'senderId':   currentUserId,
      'senderName': currentUserName,
      'text':       text,
      'timestamp':  DateTime.now().millisecondsSinceEpoch,
      'isRead':     false,
      'isDelivered': false,
      'isDeleted':  false,
      'isGroup':    widget.isGroup,
      'type':       finalType, // ← NEW
      'reactions':  {},
    };

    if (replyingTo != null) {
      messageData['replyToMessageId']  = replyingTo!.messageId;
      messageData['replyToText']       = replyingTo!.text;
      messageData['replyToSenderName'] = replyingTo!.senderId == currentUserId
          ? 'You'
          : replyingTo!.senderName;
    }

    await ref.set(messageData);
    _messageController.clear();
    if (mounted) setState(() => replyingTo = null);

    // Scroll to bottom
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });

    // ── Update Firestore group lastMessage ────────────────────────────────
    if (widget.isGroup) {
      final String preview = finalType == 'announcement'
          ? '📢 $text'
          : finalType == 'image'
              ? '🖼️ Photo'
              : finalType == 'document'
                  ? '📄 Document'
                  : text;
      FirebaseFirestore.instance
          .collection('Groups').doc(chatId)
          .update({
        'lastMessage':     preview,
        'lastMessageTime': FieldValue.serverTimestamp(),
      });
    }

    // ── Notification ──────────────────────────────────────────────────────
    await Future.delayed(const Duration(milliseconds: 300));
    if (widget.isGroup) {
      _sendOneSignalToGroup(text, finalType); // ← NEW
    } else if (widget.receiverId != null && widget.receiverId!.isNotEmpty) {
      _sendOneSignalNotification(text);       // ← original preserved
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ONESIGNAL — 1-1 (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _sendOneSignalNotification(String msgText) async {
    try {
      final receiverSnap = await FirebaseFirestore.instance
          .collection('Users').doc(widget.receiverId!.trim()).get();
      if (!receiverSnap.exists) return;

      final String? oneSignalId = receiverSnap.data()?['oneSignalId'];
      if (oneSignalId == null || oneSignalId.isEmpty) return;

      final String notifBody = msgText.startsWith('http')
          ? (msgText.contains('.pdf') ? '📄 Sent a document' : '🖼️ Sent an image')
          : msgText;

      await Dio().post(
        'https://onesignal.com/api/v1/notifications',
        data: jsonEncode({
          'app_id':              _kOneSignalAppId,
          'include_player_ids':  [oneSignalId],
          'headings':            {'en': currentUserName},
          'contents':            {'en': notifBody},
          'data': {
            'senderId':   currentUserId,
            'senderName': currentUserName,
            'chatId':     chatId,
          },
          'priority':           10,
          'android_visibility': 1,
        }),
        options: Options(headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Basic $_kOneSignalRestKey',
        }),
      );
      debugPrint('✅ OneSignal 1-1 sent');
    } on DioException catch (e) {
      debugPrint('❌ OneSignal: ${e.response?.data}');
    } catch (e) {
      debugPrint('❌ OneSignal: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ NEW — ONESIGNAL GROUP: notify all members except sender
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _sendOneSignalToGroup(String text, String msgType) async {
    try {
      final grpDoc = await FirebaseFirestore.instance
          .collection('Groups').doc(chatId).get();
      final List members = (grpDoc.data()?['members'] as List?) ?? [];

      final List<String> playerIds = [];
      for (final memberId in members) {
        if (memberId.toString() == currentUserId) continue;
        final uDoc = await FirebaseFirestore.instance
            .collection('Users').doc(memberId.toString()).get();
        if (!uDoc.exists) continue;
        final String? osId = uDoc.data()?['oneSignalId'];
        if (osId != null && osId.isNotEmpty) playerIds.add(osId);
      }

      if (playerIds.isEmpty) return;

      final String grpName =
          grpDoc.data()?['name']?.toString() ?? widget.partnerName;
      final String body = msgType == 'image'
          ? '🖼️ Sent an image'
          : msgType == 'document'
              ? '📄 Sent a document'
              : msgType == 'announcement'
                  ? '📢 $text'
                  : text;

      await Dio().post(
        'https://onesignal.com/api/v1/notifications',
        data: jsonEncode({
          'app_id':              _kOneSignalAppId,
          'include_player_ids':  playerIds,
          'headings':            {'en': '$currentUserName • $grpName'},
          'contents':            {'en': body},
          'data': {
            'groupId':    chatId,
            'groupName':  grpName,
            'senderId':   currentUserId,
            'senderName': currentUserName,
            'screen':     'group_chat',
          },
          'priority':           10,
          'android_visibility': 1,
        }),
        options: Options(headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Basic $_kOneSignalRestKey',
        }),
      );
      debugPrint('✅ OneSignal group: ${playerIds.length} members notified');
    } on DioException catch (e) {
      debugPrint('❌ OneSignal group: ${e.response?.data}');
    } catch (e) {
      debugPrint('❌ OneSignal group: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REACTIONS (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _toggleReaction(ChatMessage msg, String emoji) async {
    final ref = _chatDbRef
        .child(msg.messageId).child('reactions').child(emoji).child(currentUserId);
    final snap = await ref.get();
    if (snap.exists && snap.value == true) {
      await ref.remove();
    } else {
      await ref.set(true);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DELETE (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  void _deleteForMe(ChatMessage msg) {
    _chatDbRef.child(msg.messageId).child('hiddenBy').child(currentUserId).set(true);
  }

  void _deleteForEveryone(ChatMessage msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete for Everyone?'),
        content: const Text('This message will be removed for all users.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _chatDbRef.child(msg.messageId).set({
                'messageId':   msg.messageId,
                'senderId':    msg.senderId,
                'senderName':  msg.senderName,
                'timestamp':   msg.timestamp,
                'isDeleted':   true,
                'isDelivered': true,
                'isRead':      false,
                'text':        'This message was deleted',
              });
              _showSnack('Message deleted for everyone');
            },
            child: const Text('Delete',
                style: TextStyle(
                    color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _clearChat() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Clear Chat?',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text(
            'All messages will be permanently deleted for everyone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _chatDbRef.remove();
              await _hiveBox?.clear();
              _showSnack('Chat cleared');
            },
            child: const Text('Clear All',
                style: TextStyle(
                    color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FILE UPLOAD (original — minor: pass msgType to _sendMessage)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _openFilePicker() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Text('Send Attachment',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ListTile(
              leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: const Color(0xFF8B0A1A).withOpacity(0.1),
                      shape: BoxShape.circle),
                  child:
                      const Icon(Icons.image, color: Color(0xFF8B0A1A))),
              title: const Text('Photo from Gallery'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      shape: BoxShape.circle),
                  child: const Icon(Icons.picture_as_pdf, color: Colors.red)),
              title: const Text('Document / PDF'),
              onTap: () => Navigator.pop(ctx, 'pdf'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    _showSnack('Uploading…');
    try {
      final cloudinary =
          CloudinaryPublic(_cloudName, _uploadPreset, cache: false);
      final res = await cloudinary.uploadFile(
        CloudinaryFile.fromFile(picked.path,
            resourceType: CloudinaryResourceType.Auto),
      );
      // ← pass type so group lastMessage + announcement logic knows
      _sendMessage(
        manualText: res.secureUrl,
        msgType:    choice == 'pdf' ? 'document' : 'image',
      );
    } catch (_) {
      _showSnack('Upload failed. Please try again.');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ NEW — CHANGE GROUP DP (teacher only)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _changeGroupDp() async {
    if (!_isTeacher) return;
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return;
    setState(() => _isUploadingDp = true);
    try {
      final uri = Uri.parse(
          'https://api.cloudinary.com/v1_1/$_cloudName/image/upload');
      final req = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = _uploadPreset
        ..files.add(
            await http.MultipartFile.fromPath('file', picked.path));
      final res  = await req.send();
      final body = await res.stream.bytesToString();
      final url  = jsonDecode(body)['secure_url'] as String?;
      if (url == null) { _showSnack('DP upload failed'); return; }
      await FirebaseFirestore.instance
          .collection('Groups').doc(chatId)
          .update({'groupPic': url});
      _showSnack('✅ Group DP updated!');
    } catch (e) {
      _showSnack('Error: $e');
    } finally {
      if (mounted) setState(() => _isUploadingDp = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DOWNLOAD (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _downloadFile(String url, String fileName) async {
    if (kIsWeb) {
      try {
        html.HttpRequest.request(url, responseType: 'blob').then((request) {
          final blob = request.response as html.Blob;
          final blobUrl = html.Url.createObjectUrlFromBlob(blob);
          final ext = url.split('.').last.split('?').first;
          html.AnchorElement(href: blobUrl)
            ..setAttribute('download',
                'CP_${DateTime.now().millisecondsSinceEpoch}.$ext')
            ..click();
          html.Url.revokeObjectUrl(blobUrl);
        }).catchError((_) => html.window.open(url, '_blank'));
      } catch (e) {
        html.window.open(url, '_blank');
      }
      return;
    }
    try {
      if (Platform.isAndroid) {
        await Permission.storage.request();
        await Permission.manageExternalStorage.request();
      }
      final directory = Platform.isAndroid
          ? Directory('/storage/emulated/0/Download/Campus Pulse')
          : await getApplicationDocumentsDirectory();
      if (!await directory.exists()) await directory.create(recursive: true);
      final String ext =
          url.toLowerCase().contains('.pdf') ? '.pdf' : '.jpg';
      final String savePath =
          '${directory.path}/CP_${DateTime.now().millisecondsSinceEpoch}$ext';
      await Dio().download(url, savePath);
      if (mounted) _showSnack('Saved to Download/Campus Pulse');
    } catch (e) {
      if (mounted) _showSnack('Download failed');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI HELPERS (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _getDateLabel(int ts) {
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final now  = DateTime.now();
    final fmt  = DateFormat('yyyyMMdd');
    if (fmt.format(date) == fmt.format(now)) return 'Today';
    if (fmt.format(date) ==
        fmt.format(now.subtract(const Duration(days: 1)))) return 'Yesterday';
    return DateFormat('MMMM d, yyyy').format(date);
  }

  void _scrollToMessage(String messageId) {
    final key = _messageKeys[messageId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        alignment: 0.5,
      );
    }
  }

  void _forwardMessage(String text) {
    _messageController.text = text;
    _showSnack('Message copied to input — select a chat to forward');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _currentBgColor,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // offline banner (original)
          if (!_isOnline)
            Container(
              width: double.infinity,
              color: Colors.orange.shade50,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.wifi_off_rounded,
                      size: 15, color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "You're offline — showing cached messages",
                      style: TextStyle(
                          fontSize: 12, color: Colors.orange.shade800),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(child: _buildMessageList()),
          if (replyingTo != null) _buildReplyPreview(),

          // ✅ NEW: announcement toggle (teacher + group only)
          if (widget.isGroup && _isTeacher) _buildAnnouncementToggle(),

          _canSend ? _buildInputBar() : _buildAdminNotice(),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // APP BAR — original + group additions
  // ─────────────────────────────────────────────────────────────────────────
  AppBar _buildAppBar() {
    // For group: live DP, tap to change (teacher), admin-only badge
    final Widget avatar = widget.isGroup
        ? GestureDetector(
            onTap: _isTeacher ? _changeGroupDp : null,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: const Color(0xFFFBC02D), width: 1.5),
                  ),
                  child: _isUploadingDp
                      ? const CircleAvatar(
                          radius: 20,
                          backgroundColor: Color(0xFFB71C1C),
                          child: SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          ))
                      : _currentGroupPic.isNotEmpty
                          ? ClipOval(
                              child: CachedNetworkImage(
                                imageUrl: _currentGroupPic,
                                width: 40, height: 40, fit: BoxFit.cover,
                                placeholder: (_, __) => _dpFallback(),
                                errorWidget: (_, __, ___) => _dpFallback(),
                              ))
                          : _dpFallback(),
                ),
                if (_isTeacher)
                  Positioned(
                    bottom: 0, right: 0,
                    child: Container(
                      width: 14, height: 14,
                      decoration: const BoxDecoration(
                          color: Color(0xFFFBC02D),
                          shape: BoxShape.circle),
                      child: const Icon(Icons.camera_alt_rounded,
                          size: 9, color: Color(0xFF8B0A1A)),
                    ),
                  ),
              ],
            ),
          )
        : CircleAvatar(
            radius: 20,
            backgroundImage: widget.partnerPic.isNotEmpty
                ? NetworkImage(widget.partnerPic)
                : null,
            backgroundColor: Colors.white24,
            child: widget.partnerPic.isEmpty
                ? Text(widget.partnerName[0].toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold))
                : null,
          );

    return AppBar(
      backgroundColor: const Color(0xFF8B0A1A),
      elevation: 0,
      titleSpacing: 0,
      title: Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.partnerName,
                    style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white,
                        fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    Text(
                      widget.isGroup ? 'Group Chat' : widget.partnerDept,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white70),
                    ),
                    // ✅ NEW: admin-only badge
                    if (widget.isGroup && isAdminOnly) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFBC02D).withOpacity(0.25),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('🔒 Admin only',
                            style: TextStyle(
                                color: Color(0xFFFBC02D),
                                fontSize: 9,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_sweep, color: Colors.white),
          tooltip: 'Clear Chat',
          onPressed: _clearChat,
        ),
        IconButton(
          icon: const Icon(Icons.palette, color: Colors.white),
          tooltip: 'Chat Theme',
          onPressed: _showThemeDialog,
        ),
        // ✅ NEW: members button (group only)
        if (widget.isGroup)
          IconButton(
            icon: const Icon(Icons.people_alt_rounded, color: Colors.white),
            tooltip: 'Members',
            onPressed: _showMembersDialog,
          ),
        // privacy settings (group admin only)
        if (widget.isGroup && currentUserId == groupAdminId)
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: _showPrivacyDialog,
          ),
      ],
    );
  }

  Widget _dpFallback() => CircleAvatar(
        radius: 20,
        backgroundColor: const Color(0xFFB71C1C),
        child: Text(
          widget.partnerName.isNotEmpty
              ? widget.partnerName[0].toUpperCase()
              : 'G',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold),
        ),
      );

  // ─────────────────────────────────────────────────────────────────────────
  // MESSAGE LIST — original hybrid (Hive+RTDB) + announcement type handling
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildMessageList() {
    return StreamBuilder<DatabaseEvent>(
      stream: _chatDbRef.orderByChild('timestamp').onValue,
      builder: (context, snapshot) {
        List<ChatMessage> msgs;

        if (snapshot.hasError ||
            !snapshot.hasData ||
            snapshot.data!.snapshot.value == null) {
          // offline: use Hive cache
          if (!snapshot.hasData && _cachedMessages.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chat_bubble_outline,
                      size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 12),
                  Text('No messages yet',
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 15)),
                ],
              ),
            );
          }
          msgs = _cachedMessages
              .where((m) =>
                  m.hiddenBy == null ||
                  !m.hiddenBy!.containsKey(currentUserId))
              .toList();
          if (snapshot.hasError && mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _isOnline = false);
            });
          }
        } else {
          // online: parse from RTDB
          final data = snapshot.data!.snapshot.value as Map;
          _rawMsgMap.clear(); // ← NEW: refresh raw map for type lookup

          msgs = data.entries
              .map((e) {
                // ← NEW: store raw map before creating ChatMessage
                _rawMsgMap[e.key as String] =
                    Map<dynamic, dynamic>.from(e.value as Map);
                return ChatMessage.fromMap(
                    Map<dynamic, dynamic>.from(e.value as Map),
                    e.key as String);
              })
              .where((m) =>
                  m.hiddenBy == null ||
                  !m.hiddenBy!.containsKey(currentUserId))
              .toList()
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

          _saveMessagesToHive(msgs);
          if (!_isOnline && mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _isOnline = true);
            });
          }
        }

        if (msgs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline,
                    size: 64, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text('No messages yet',
                    style: TextStyle(
                        color: Colors.grey.shade500, fontSize: 15)),
              ],
            ),
          );
        }

        for (final msg in msgs) {
          _messageKeys.putIfAbsent(msg.messageId, () => GlobalKey());
        }

        return ListView.builder(
          controller: _scrollController,
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final msg      = msgs[i];
            final showDate = i == msgs.length - 1 ||
                _getDateLabel(msg.timestamp) !=
                    _getDateLabel(msgs[i + 1].timestamp);

            // ← NEW: check type from raw map
            final String msgType =
                _rawMsgMap[msg.messageId]?['type']?.toString() ?? 'text';

            return Column(
              children: [
                if (showDate) _buildDateChip(_getDateLabel(msg.timestamp)),

                // ← NEW: announcement gets its own bubble
                if (msgType == 'announcement')
                  _buildAnnouncementBubble(msg)
                else
                  KeyedSubtree(
                    key: _messageKeys[msg.messageId],
                    child: ChatBubble(
                      message: msg,
                      isMe: msg.senderId == currentUserId,
                      isGroup: widget.isGroup,
                      currentUserId: currentUserId,
                      onReply: () => setState(() => replyingTo = msg),
                      onDeleteForMe: () => _deleteForMe(msg),
                      onDeleteForEveryone: () => _deleteForEveryone(msg),
                      onForward: () => _forwardMessage(msg.text),
                      onDownload: (url, name) => _downloadFile(url, name),
                      receiverId: widget.receiverId,
                      onReact: (emoji) => _toggleReaction(msg, emoji),
                      onReplyTap: msg.replyToMessageId != null
                          ? () => _scrollToMessage(msg.replyToMessageId!)
                          : null,
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDateChip(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.10),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label,
              style: const TextStyle(
                  color: Color(0xFF555555),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ NEW — ANNOUNCEMENT BUBBLE
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildAnnouncementBubble(ChatMessage msg) {
    final bool isDeleted = msg.isDeleted;
    final String text    = isDeleted ? '🚫 This message was deleted' : msg.text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFF8B0A1A), Color(0xFFB71C1C)]),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFF8B0A1A).withOpacity(0.25),
                blurRadius: 8,
                offset: const Offset(0, 3))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.campaign_rounded,
                    color: Color(0xFFFBC02D), size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Announcement • ${msg.senderName}',
                    style: const TextStyle(
                        color: Color(0xFFFBC02D),
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  DateFormat('HH:mm').format(
                      DateTime.fromMillisecondsSinceEpoch(msg.timestamp)),
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 10),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(text,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REPLY PREVIEW (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildReplyPreview() {
    return Container(
      color: Colors.grey[100],
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Container(width: 3, height: 44, color: const Color(0xFF8B0A1A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  replyingTo!.senderId == currentUserId
                      ? 'You'
                      : replyingTo!.senderName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF8B0A1A),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  replyingTo!.isDeleted
                      ? '🚫 Message deleted'
                      : replyingTo!.isMedia
                          ? '📎 Attachment'
                          : replyingTo!.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: Colors.grey),
            onPressed: () => setState(() => replyingTo = null),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ NEW — ANNOUNCEMENT TOGGLE (group teacher only)
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildAnnouncementToggle() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: _isAnnouncement
          ? const Color(0xFF8B0A1A).withOpacity(0.07)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          Icon(Icons.campaign_rounded,
              size: 18,
              color: _isAnnouncement
                  ? const Color(0xFF8B0A1A)
                  : Colors.grey[400]),
          const SizedBox(width: 8),
          Text('Announcement mode',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _isAnnouncement
                      ? const Color(0xFF8B0A1A)
                      : Colors.grey[500])),
          const Spacer(),
          Switch(
            value: _isAnnouncement,
            activeColor: const Color(0xFF8B0A1A),
            activeTrackColor: const Color(0xFFFBC02D),
            onChanged: (v) => setState(() => _isAnnouncement = v),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // INPUT BAR (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildInputBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.attach_file,
                  color: Color(0xFF8B0A1A)),
              onPressed: _openFilePicker,
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(26),
                  // ← NEW: highlight border in announcement mode
                  border: widget.isGroup && _isAnnouncement
                      ? Border.all(
                          color: const Color(0xFF8B0A1A), width: 1.5)
                      : null,
                ),
                child: TextField(
                  controller: _messageController,
                  minLines: 1, maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: widget.isGroup && _isAnnouncement
                        ? '📢 Type announcement...'
                        : 'Message',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _sendMessage,
              child: Container(
                width: 44, height: 44,
                decoration: const BoxDecoration(
                  color: Color(0xFF8B0A1A), shape: BoxShape.circle),
                child: const Icon(Icons.send_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminNotice() {
    return Container(
      width: double.infinity,
      color: Colors.black.withOpacity(0.04),
      padding: const EdgeInsets.all(12),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline, size: 15, color: Colors.grey),
          SizedBox(width: 8),
          Text('Only admins can send messages',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // THEME DIALOG (original — unchanged)
  // ─────────────────────────────────────────────────────────────────────────
  void _showThemeDialog() {
    const themes = {
      'Default (Beige)': '#F0EDE8',
      'White':           '#FFFFFF',
      'Dark Slate':      '#1E1E2E',
      'Soft Blue':       '#E3F2FD',
      'Light Green':     '#E8F5E9',
      'Warm Peach':      '#FFF3E0',
      'Lavender':        '#F3E5F5',
      'Mint':            '#E0F2F1',
    };
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Chat Theme',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: themes.entries.map((e) {
            final color =
                Color(int.parse(e.value.replaceFirst('#', '0xff')));
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: Colors.grey.shade300),
                ),
              ),
              title: Text(e.key),
              onTap: () async {
                setState(() => _currentBgColor = color);
                (await SharedPreferences.getInstance())
                    .setString('bg_color_$chatId', e.value);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVACY DIALOG — ✅ FIXED: now writes to Firestore (was RTDB bug)
  // ─────────────────────────────────────────────────────────────────────────
  void _showPrivacyDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Group Messaging',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Who can send messages in this group?'),
        actions: [
          TextButton(
            onPressed: () {
              FirebaseFirestore.instance // ← FIXED (was RTDB)
                  .collection('Groups').doc(chatId)
                  .update({'isAdminOnly': true, 'createdBy': currentUserId});
              Navigator.pop(ctx);
              _showSnack('Only admins can now send messages');
            },
            child: const Text('Admin Only'),
          ),
          TextButton(
            onPressed: () {
              FirebaseFirestore.instance // ← FIXED (was RTDB)
                  .collection('Groups').doc(chatId)
                  .update({'isAdminOnly': false});
              Navigator.pop(ctx);
              _showSnack('Everyone can now send messages');
            },
            child: const Text('Everyone'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ NEW — MEMBERS DIALOG
  // ─────────────────────────────────────────────────────────────────────────
  void _showMembersDialog() {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 440),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.people_alt_rounded,
                      color: Color(0xFF8B0A1A), size: 20),
                  const SizedBox(width: 8),
                  const Text('Members',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Color(0xFF8B0A1A))),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: FutureBuilder<DocumentSnapshot>(
                  future: FirebaseFirestore.instance
                      .collection('Groups').doc(chatId).get(),
                  builder: (ctx, snap) {
                    if (!snap.hasData) {
                      return const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFF8B0A1A)));
                    }
                    final List members =
                        ((snap.data!.data() as Map)['members'] as List?) ??
                            [];
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: members.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1),
                      itemBuilder: (ctx2, i) {
                        return FutureBuilder<DocumentSnapshot>(
                          future: FirebaseFirestore.instance
                              .collection('Users')
                              .doc(members[i].toString())
                              .get(),
                          builder: (ctx3, uSnap) {
                            if (!uSnap.hasData) {
                              return const ListTile(
                                  dense: true,
                                  title: Text('Loading...'));
                            }
                            final d = uSnap.data!.data()
                                    as Map<String, dynamic>? ??
                                {};
                            final String name = d['name']       ?? 'Unknown';
                            final String role = d['role']       ?? 'student';
                            final String pic  = d['profilePic'] ?? '';
                            final bool isAdmin =
                                members[i].toString() == groupAdminId;
                            return ListTile(
                              dense: true,
                              leading: ClipOval(
                                child: pic.isNotEmpty
                                    ? CachedNetworkImage(
                                        imageUrl: pic,
                                        width: 36, height: 36,
                                        fit: BoxFit.cover)
                                    : CircleAvatar(
                                        radius: 18,
                                        backgroundColor: const Color(
                                                0xFFFBC02D)
                                            .withOpacity(0.3),
                                        child: const Icon(Icons.person,
                                            size: 18,
                                            color: Color(0xFF8B0A1A))),
                              ),
                              title: Row(children: [
                                Flexible(
                                    child: Text(name,
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600))),
                                if (isAdmin) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF8B0A1A)
                                          .withOpacity(0.1),
                                      borderRadius:
                                          BorderRadius.circular(6),
                                    ),
                                    child: const Text('Admin',
                                        style: TextStyle(
                                            fontSize: 9,
                                            color: Color(0xFF8B0A1A),
                                            fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ]),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: role == 'teacher'
                                      ? const Color(0xFF8B0A1A)
                                          .withOpacity(0.1)
                                      : Colors.blue.withOpacity(0.1),
                                  borderRadius:
                                      BorderRadius.circular(8),
                                ),
                                child: Text(role,
                                    style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: role == 'teacher'
                                            ? const Color(0xFF8B0A1A)
                                            : Colors.blue[700])),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}