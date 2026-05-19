// ✅ lib/models/chat_models.dart — HIVE CACHED VERSION
// ✅ Manual Hive adapter — no build_runner needed
// ✅ 3-state tick system:
//    isDelivered=false, isRead=false → Single gray tick  ✓  (Sent)
//    isDelivered=true,  isRead=false → Double gray tick  ✓✓ (Delivered)
//    isDelivered=true,  isRead=true  → Double blue tick  ✓✓ (Read)

import 'package:hive/hive.dart';

class ChatMessage {
  final String messageId;
  final String senderId;
  final String senderName;
  final String text;
  final int timestamp;
  final bool isRead;
  final bool isDelivered;
  final bool isDeleted;
  final Map? hiddenBy;

  // Reply fields
  final String? replyToText;
  final String? replyToSenderName;
  final String? replyToMessageId;

  // Reactions — { emoji: [userId1, userId2, ...] }
  final Map<String, List<String>>? reactions;

  ChatMessage({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    required this.isRead,
    required this.isDelivered,
    required this.isDeleted,
    this.hiddenBy,
    this.replyToText,
    this.replyToSenderName,
    this.replyToMessageId,
    this.reactions,
  });

  // ─── Media type helpers ───────────────────────────────────────────────────

  bool get isCloudinaryUrl =>
      text.startsWith('http') && text.contains('cloudinary.com');

  bool get isImage {
    if (isDeleted || !isCloudinaryUrl) return false;
    final lower = text.toLowerCase();
    if (lower.contains('.pdf')) return false;
    if (lower.contains('.mp4') ||
        lower.contains('.mov') ||
        lower.contains('.avi')) return false;
    return lower.contains('/image/upload/') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
  }

  bool get isPdf {
    if (isDeleted || !isCloudinaryUrl) return false;
    return text.toLowerCase().contains('.pdf') ||
        text.toLowerCase().contains('/raw/upload/');
  }

  bool get isMedia => isImage || isPdf;

  // ─── From Firebase RTDB map ───────────────────────────────────────────────

  factory ChatMessage.fromMap(Map<dynamic, dynamic> map, String key) {
    Map<String, List<String>>? parsedReactions;
    if (map['reactions'] != null) {
      parsedReactions = {};
      final rawReactions = Map<dynamic, dynamic>.from(map['reactions']);
      rawReactions.forEach((emoji, usersMap) {
        if (usersMap is Map) {
          parsedReactions![emoji.toString()] =
              usersMap.keys.map((k) => k.toString()).toList();
        }
      });
    }

    return ChatMessage(
      messageId: key,
      senderId: map['senderId'] ?? '',
      senderName: map['senderName'] ?? 'User',
      text: map['text'] ?? '',
      timestamp: map['timestamp'] ?? 0,
      isRead: map['isRead'] ?? false,
      isDelivered: map['isDelivered'] ?? false,
      isDeleted: map['isDeleted'] ?? false,
      hiddenBy: map['hiddenBy'] != null ? Map.from(map['hiddenBy']) : null,
      replyToText: map['replyToText'],
      replyToSenderName: map['replyToSenderName'],
      replyToMessageId: map['replyToMessageId'],
      reactions: parsedReactions,
    );
  }

  // ─── To flat map for Hive storage ────────────────────────────────────────
  // Reactions stored as JSON-safe map: { "👍": ["uid1","uid2"] }

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'senderId': senderId,
      'senderName': senderName,
      'text': text,
      'timestamp': timestamp,
      'isRead': isRead,
      'isDelivered': isDelivered,
      'isDeleted': isDeleted,
      if (hiddenBy != null) 'hiddenBy': hiddenBy,
      if (replyToText != null) 'replyToText': replyToText,
      if (replyToSenderName != null) 'replyToSenderName': replyToSenderName,
      if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
      if (reactions != null)
        'reactions': reactions!.map(
          (k, v) => MapEntry(k, v),
        ),
    };
  }

  // ─── Reconstruct from Hive-stored flat map ────────────────────────────────

  factory ChatMessage.fromStoredMap(Map<dynamic, dynamic> map) {
    Map<String, List<String>>? parsedReactions;
    if (map['reactions'] != null) {
      parsedReactions = {};
      (map['reactions'] as Map).forEach((emoji, users) {
        if (users is List) {
          parsedReactions![emoji.toString()] =
              users.map((u) => u.toString()).toList();
        }
      });
    }

    return ChatMessage(
      messageId: map['messageId'] ?? '',
      senderId: map['senderId'] ?? '',
      senderName: map['senderName'] ?? 'User',
      text: map['text'] ?? '',
      timestamp: map['timestamp'] ?? 0,
      isRead: map['isRead'] ?? false,
      isDelivered: map['isDelivered'] ?? false,
      isDeleted: map['isDeleted'] ?? false,
      hiddenBy: map['hiddenBy'] != null ? Map.from(map['hiddenBy']) : null,
      replyToText: map['replyToText'],
      replyToSenderName: map['replyToSenderName'],
      replyToMessageId: map['replyToMessageId'],
      reactions: parsedReactions,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Manual Hive Adapter — typeId: 1 (0 is used by AnnouncementAdapter)
// Stores messages as JSON map in a single string field for simplicity
// No build_runner needed
// ─────────────────────────────────────────────────────────────────────────────

class ChatMessageAdapter extends TypeAdapter<ChatMessage> {
  @override
  final int typeId = 1;

  @override
  ChatMessage read(BinaryReader reader) {
    // Read all fields in the same order as write()
    final messageId = reader.readString();
    final senderId = reader.readString();
    final senderName = reader.readString();
    final text = reader.readString();
    final timestamp = reader.readInt();
    final isRead = reader.readBool();
    final isDelivered = reader.readBool();
    final isDeleted = reader.readBool();
    final replyToText =
        reader.readBool() ? reader.readString() : null;
    final replyToSenderName =
        reader.readBool() ? reader.readString() : null;
    final replyToMessageId =
        reader.readBool() ? reader.readString() : null;

    return ChatMessage(
      messageId: messageId,
      senderId: senderId,
      senderName: senderName,
      text: text,
      timestamp: timestamp,
      isRead: isRead,
      isDelivered: isDelivered,
      isDeleted: isDeleted,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToMessageId: replyToMessageId,
      // reactions/hiddenBy are not cached — fetched fresh from RTDB
    );
  }

  @override
  void write(BinaryWriter writer, ChatMessage obj) {
    writer.writeString(obj.messageId);
    writer.writeString(obj.senderId);
    writer.writeString(obj.senderName);
    writer.writeString(obj.text);
    writer.writeInt(obj.timestamp);
    writer.writeBool(obj.isRead);
    writer.writeBool(obj.isDelivered);
    writer.writeBool(obj.isDeleted);

    // Optional string fields — write a bool flag first
    writer.writeBool(obj.replyToText != null);
    if (obj.replyToText != null) writer.writeString(obj.replyToText!);

    writer.writeBool(obj.replyToSenderName != null);
    if (obj.replyToSenderName != null) writer.writeString(obj.replyToSenderName!);

    writer.writeBool(obj.replyToMessageId != null);
    if (obj.replyToMessageId != null) writer.writeString(obj.replyToMessageId!);
  }
}