// ✅ chat_bubble.dart — Complete WhatsApp-style Chat Bubble
// ✅ FIXED: 3-state tick system:
//    - Single gray tick  ✓   = Sent (saved to Firebase)
//    - Double gray tick  ✓✓  = Delivered (receiver's device got it)
//    - Double blue tick  ✓✓  = Read (receiver opened the chat)
// ✅ All other features: swipe-to-reply, emoji reactions, long-press menu,
//    image/pdf inline, reply quote, delete for me/everyone, download

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/chat_models.dart';

class ChatBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isMe;
  final bool isGroup;
  final VoidCallback onReply;
  final VoidCallback onDeleteForMe;
  final VoidCallback onDeleteForEveryone;
  final VoidCallback onForward;
  final Function(String url, String fileName) onDownload;
  final VoidCallback? onReplyTap;
  final String? receiverId;
  final Function(String emoji)? onReact;
  final String currentUserId;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.isGroup,
    required this.onReply,
    required this.onDeleteForMe,
    required this.onDeleteForEveryone,
    required this.onForward,
    required this.onDownload,
    required this.receiverId,
    required this.currentUserId,
    this.onReplyTap,
    this.onReact,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble>
    with TickerProviderStateMixin {
  // ── Swipe-to-reply ─────────────────────────────────────────────────────
  double _swipeDx = 0.0;
  bool _hapticFired = false;
  static const double _kReplyThreshold = 60.0;
  static const double _kMaxSwipe = 80.0;

  // ── Highlight ─────────────────────────────────────────────────────────
  late AnimationController _highlightCtrl;
  late Animation<double> _highlightAnim;

  @override
  void initState() {
    super.initState();
    _highlightCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _highlightAnim =
        CurvedAnimation(parent: _highlightCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _highlightCtrl.dispose();
    super.dispose();
  }

  void highlight() => _highlightCtrl.forward(from: 0);

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;

    return GestureDetector(
      onHorizontalDragUpdate: msg.isDeleted
          ? null
          : (details) {
              if (details.delta.dx > 0) {
                setState(() {
                  _swipeDx =
                      (_swipeDx + details.delta.dx).clamp(0, _kMaxSwipe);
                  if (_swipeDx >= _kReplyThreshold && !_hapticFired) {
                    _hapticFired = true;
                    HapticFeedback.mediumImpact();
                  }
                });
              }
            },
      onHorizontalDragEnd: msg.isDeleted
          ? null
          : (_) {
              if (_swipeDx >= _kReplyThreshold) widget.onReply();
              setState(() {
                _swipeDx = 0;
                _hapticFired = false;
              });
            },
      onLongPress: () => _showContextMenu(),
      child: Stack(
        alignment:
            widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
        children: [
          // Reply icon (appears on swipe)
          if (_swipeDx > 0)
            Positioned(
              left: widget.isMe ? null : 4,
              right: widget.isMe ? 4 : null,
              child: Opacity(
                opacity: (_swipeDx / _kReplyThreshold).clamp(0.0, 1.0),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.reply_rounded,
                    size: 20,
                    color: _swipeDx >= _kReplyThreshold
                        ? const Color(0xFF8B0A1A)
                        : Colors.grey.shade500,
                  ),
                ),
              ),
            ),

          // Bubble slides on swipe
          Transform.translate(
            offset: Offset(_swipeDx, 0),
            child: _buildBubbleWithReactions(msg),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUBBLE + REACTIONS
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildBubbleWithReactions(ChatMessage msg) {
    final hasReactions = msg.reactions != null &&
        msg.reactions!.isNotEmpty &&
        msg.reactions!.values.any((list) => list.isNotEmpty);

    return Column(
      crossAxisAlignment:
          widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildBubble(msg),
        if (hasReactions && !msg.isDeleted) _buildReactionsRow(msg),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REACTIONS ROW
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildReactionsRow(ChatMessage msg) {
    final reactions = msg.reactions!;
    final List<MapEntry<String, List<String>>> entries = reactions.entries
        .where((e) => e.value.isNotEmpty)
        .toList();

    return Padding(
      padding: EdgeInsets.only(
        left: widget.isMe ? 0 : 18,
        right: widget.isMe ? 18 : 0,
        bottom: 2,
        top: 2,
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment:
            widget.isMe ? WrapAlignment.end : WrapAlignment.start,
        children: entries.map((entry) {
          final emoji = entry.key;
          final users = entry.value;
          final iMeReacted = users.contains(widget.currentUserId);

          return GestureDetector(
            onTap: () => widget.onReact?.call(emoji),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: iMeReacted
                    ? const Color(0xFF8B0A1A).withOpacity(0.15)
                    : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: iMeReacted
                      ? const Color(0xFF8B0A1A)
                      : Colors.grey.shade300,
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(emoji,
                      style: const TextStyle(fontSize: 13)),
                  if (users.length > 1) ...[
                    const SizedBox(width: 3),
                    Text(
                      '${users.length}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: iMeReacted
                            ? const Color(0xFF8B0A1A)
                            : Colors.black54,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUBBLE CONTAINER
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildBubble(ChatMessage msg) {
    final isMe = widget.isMe;

    late Color bubbleColor;
    if (msg.isDeleted) {
      bubbleColor = Colors.grey.shade200;
    } else if (isMe) {
      bubbleColor = const Color(0xFF8B0A1A);
    } else {
      bubbleColor = Colors.white;
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          top: 2,
          bottom: 2,
          left: isMe ? 60 : 12,
          right: isMe ? 12 : 60,
        ),
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sender name in group chats
            if (widget.isGroup && !isMe && !msg.isDeleted)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  msg.senderName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 11.5,
                    color: Color(0xFF8B0A1A),
                  ),
                ),
              ),

            // Reply quote
            if (msg.replyToText != null && !msg.isDeleted)
              _buildReplyQuote(msg),

            // Message content
            if (msg.isDeleted)
              _buildDeletedContent(isMe)
            else if (msg.isImage)
              _buildImageContent(msg)
            else if (msg.isPdf)
              _buildPdfContent(isMe)
            else
              SelectableText(
                msg.text,
                style: TextStyle(
                  color: isMe ? Colors.white : Colors.black87,
                  fontSize: 14.5,
                  height: 1.35,
                ),
              ),

            const SizedBox(height: 3),

            // ✅ FIXED: Time + 3-state tick icon
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  DateFormat('h:mm a').format(
                      DateTime.fromMillisecondsSinceEpoch(msg.timestamp)),
                  style: TextStyle(
                    fontSize: 10,
                    color: isMe ? Colors.white60 : Colors.black38,
                  ),
                ),
                // ✅ Only show ticks for my messages
                if (isMe) ...[
                  const SizedBox(width: 3),
                  _buildTickIcon(msg),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ FIXED: 3-STATE TICK ICON (WhatsApp style)
  //
  //  State 1 — Sent only (single gray tick ✓):
  //    isDelivered=false, isRead=false
  //    → Message saved to Firebase but receiver hasn't connected yet
  //
  //  State 2 — Delivered (double gray tick ✓✓):
  //    isDelivered=true, isRead=false
  //    → Receiver's device got the message (app opened in background)
  //    → This happens via _listenToAllChats() in users_list_fragment
  //
  //  State 3 — Read (double blue tick ✓✓):
  //    isRead=true (isDelivered is also true at this point)
  //    → Receiver has opened the chat screen
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildTickIcon(ChatMessage msg) {
    if (msg.isDeleted) {
      return Icon(Icons.done_rounded,
          size: 14, color: Colors.white54);
    }

    if (msg.isRead) {
      // ✅ State 3: Double BLUE tick — Read
      return const Icon(
        Icons.done_all_rounded,
        size: 14,
        color: Colors.lightBlueAccent,
      );
    } else if (msg.isDelivered) {
      // ✅ State 2: Double GRAY tick — Delivered
      return Icon(
        Icons.done_all_rounded,
        size: 14,
        color: Colors.white.withOpacity(0.6),
      );
    } else {
      // ✅ State 1: Single GRAY tick — Sent only
      return Icon(
        Icons.done_rounded,
        size: 14,
        color: Colors.white.withOpacity(0.6),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONTENT WIDGETS
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildDeletedContent(bool isMe) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.block_rounded,
            size: 14,
            color: isMe ? Colors.white54 : Colors.grey.shade400),
        const SizedBox(width: 5),
        Text(
          'This message was deleted',
          style: TextStyle(
            fontStyle: FontStyle.italic,
            fontSize: 13.5,
            color: isMe ? Colors.white54 : Colors.grey.shade500,
          ),
        ),
      ],
    );
  }

  Widget _buildImageContent(ChatMessage msg) {
    return GestureDetector(
      onTap: () => _openFullScreenImage(msg.text),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          msg.text,
          width: 240,
          fit: BoxFit.cover,
          loadingBuilder: (ctx, child, progress) {
            if (progress == null) return child;
            return Container(
              width: 240,
              height: 180,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: CircularProgressIndicator(
                  value: progress.expectedTotalBytes != null
                      ? progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!
                      : null,
                  color: const Color(0xFF8B0A1A),
                  strokeWidth: 2,
                ),
              ),
            );
          },
          errorBuilder: (ctx, _, __) => Container(
            width: 240,
            height: 130,
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.broken_image_rounded,
                    size: 44, color: Colors.grey),
                const SizedBox(height: 6),
                const Text('Image unavailable',
                    style:
                        TextStyle(color: Colors.grey, fontSize: 12)),
                TextButton.icon(
                  onPressed: () {
                    String name = "IMG_${msg.timestamp}.jpg";
                    widget.onDownload(msg.text, name);
                  },
                  icon: const Icon(Icons.download, size: 14),
                  label: const Text('Download'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF8B0A1A),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPdfContent(bool isMe) {
    final msg = widget.message;
    return GestureDetector(
      onTap: () => _openUrlInBrowser(msg.text),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: (isMe ? Colors.white : Colors.grey).withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.picture_as_pdf_rounded,
                  color: Colors.red, size: 30),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('PDF Document',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color:
                              isMe ? Colors.white : Colors.black87)),
                  Text('Tap to open in browser',
                      style: TextStyle(
                          fontSize: 11,
                          color: isMe
                              ? Colors.white60
                              : Colors.black45)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.open_in_browser_rounded,
                color: isMe ? Colors.white60 : Colors.grey),
          ],
        ),
      ),
    );
  }

  Future<void> _openUrlInBrowser(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not open file in browser')),
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REPLY QUOTE
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildReplyQuote(ChatMessage msg) {
    final isMe = widget.isMe;
    return GestureDetector(
      onTap: widget.onReplyTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: isMe
              ? Colors.white.withOpacity(0.13)
              : Colors.grey.withOpacity(0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color:
                  isMe ? Colors.white70 : const Color(0xFF8B0A1A),
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              msg.replyToSenderName ?? 'User',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 11,
                color:
                    isMe ? Colors.white : const Color(0xFF8B0A1A),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (msg.replyToText != null &&
                    msg.replyToText!.startsWith('http')) ...[
                  Icon(Icons.attach_file_rounded,
                      size: 12,
                      color: isMe
                          ? Colors.white60
                          : Colors.black45),
                  const SizedBox(width: 3),
                ],
                Flexible(
                  child: Text(
                    msg.replyToText?.startsWith('http') == true
                        ? '📎 Attachment'
                        : (msg.replyToText ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: isMe
                          ? Colors.white70
                          : Colors.black54,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FULL SCREEN IMAGE VIEWER
  // ─────────────────────────────────────────────────────────────────────────

  void _openFullScreenImage(String url) {
    final msg = widget.message;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            actions: [
              IconButton(
                icon: const Icon(Icons.download_rounded,
                    color: Colors.white),
                onPressed: () {
                  Navigator.pop(context);
                  String name = "IMG_${msg.timestamp}.jpg";
                  widget.onDownload(url, name);
                },
              ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4.0,
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.broken_image_rounded,
                  color: Colors.grey,
                  size: 60,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONTEXT MENU (Long Press)
  // ─────────────────────────────────────────────────────────────────────────

  void _showContextMenu() {
    final msg = widget.message;
    if (msg.isDeleted) return;

    HapticFeedback.mediumImpact();

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),

            // ── Quick react row ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: ['👍', '❤️', '😂', '😮', '🙏', '👏']
                    .map((emoji) {
                  final alreadyReacted =
                      msg.reactions?[emoji]?.contains(widget.currentUserId) ??
                          false;

                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      widget.onReact?.call(emoji);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: alreadyReacted
                            ? const Color(0xFF8B0A1A).withOpacity(0.15)
                            : Colors.grey.shade100,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: alreadyReacted
                              ? const Color(0xFF8B0A1A)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Text(emoji,
                          style: const TextStyle(fontSize: 22)),
                    ),
                  );
                }).toList(),
              ),
            ),

            const Divider(height: 1),

            _menuItem(
              icon: Icons.reply_rounded,
              label: 'Reply',
              iconColor: const Color(0xFF8B0A1A),
              onTap: () {
                Navigator.pop(context);
                widget.onReply();
              },
            ),

            if (!msg.isMedia)
              _menuItem(
                icon: Icons.copy_rounded,
                label: 'Copy Text',
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.text));
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Text copied')),
                  );
                },
              ),

            _menuItem(
              icon: Icons.forward_rounded,
              label: 'Forward',
              onTap: () {
                Navigator.pop(context);
                widget.onForward();
              },
            ),

            if (msg.isMedia)
              _menuItem(
                icon: msg.isPdf
                    ? Icons.open_in_browser_rounded
                    : Icons.download_rounded,
                label: msg.isPdf ? 'Open in Browser' : 'Download',
                onTap: () {
                  Navigator.pop(context);
                  if (msg.isPdf) {
                    _openUrlInBrowser(msg.text);
                  } else {
                    String name = "CP_${msg.timestamp}.jpg";
                    widget.onDownload(msg.text, name);
                  }
                },
              ),

            const Divider(height: 1),

            _menuItem(
              icon: Icons.delete_outline_rounded,
              label: 'Delete for Me',
              iconColor: Colors.orange,
              labelColor: Colors.orange,
              onTap: () {
                Navigator.pop(context);
                widget.onDeleteForMe();
              },
            ),

            if (widget.isMe)
              _menuItem(
                icon: Icons.delete_forever_rounded,
                label: 'Delete for Everyone',
                iconColor: Colors.red,
                labelColor: Colors.red,
                onTap: () {
                  Navigator.pop(context);
                  widget.onDeleteForEveryone();
                },
              ),

            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _menuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color iconColor = Colors.black54,
    Color labelColor = Colors.black87,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 16),
            Text(label,
                style: TextStyle(
                    fontSize: 15,
                    color: labelColor,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}