// ✅ lib/chat/group_chat_screen.dart — THIN WRAPPER
//
// Sari logic ChatScreen mein hai.
// Yeh file sirf ChatScreen ko sahi params ke saath call karta hai.

import 'package:flutter/material.dart';
import 'chat_screen.dart';

class GroupChatScreen extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String groupPic;
  final String currentUserRole;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPic,
    required this.currentUserRole,
  });

  @override
  Widget build(BuildContext context) {
    return ChatScreen(
      partnerId:       groupId,
      partnerName:     groupName,
      partnerPic:      groupPic,
      partnerDept:     '',
      receiverId:      groupId,   // used as groupId for OneSignal
      isGroup:         true,
      currentUserRole: currentUserRole,
    );
  }
}