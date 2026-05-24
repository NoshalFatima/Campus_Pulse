// ✅ lib/Faculty/AnnouncementScreen.dart — FINAL VERSION
// ✅ All functions intact
// ✅ Professional English toasts (SnackBar style)
// ✅ OneSignal filter approach — no segment setup needed

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../services/notification_service.dart';
import '../services/onesignal_service.dart';

class AnnouncementFragment extends StatefulWidget {
  const AnnouncementFragment({super.key});

  @override
  State<AnnouncementFragment> createState() => _AnnouncementFragmentState();
}

class _AnnouncementFragmentState extends State<AnnouncementFragment> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  String selectedCategory = "📢 General";
  String selectedDept = "Computer Science";
  String selectedSem = "1st";
  String selectedShift = "Morning";
  bool isUrgent = false;
  bool sendToAll = false;
  bool isLoading = false;

  static const List<String> categories = [
    "📢 General", "📚 Academic", "⚠️ Important",
    "📅 Event", "📝 Assignment", "🎉 Achievement",
  ];
  static const List<String> depts = [
    "Computer Science", "Zoology", "Mathmatics",
    "English", "Urdu", "Physics", "Pol Science",
  ];
  static const List<String> sems = [
    "1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th"
  ];
  static const List<String> shifts = ["Morning", "Evening"];

  @override
  void initState() {
    super.initState();
    _setupTeacherFCM();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _setupTeacherFCM() async {
    try {
      await FirebaseMessaging.instance
          .requestPermission(alert: true, badge: true, sound: true);
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        if (!mounted || message.notification == null) return;
        if (!kIsWeb) NotificationService.show(message);
      });
    } catch (e) {
      debugPrint("❌ FCM Setup: $e");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // POST ANNOUNCEMENT
  // ─────────────────────────────────────────────────────────────────────────

  void _handlePost() async {
    if (_titleController.text.trim().isEmpty ||
        _descController.text.trim().isEmpty) {
      _showSnack("Please fill in the title and description before posting.",
          isError: true);
      return;
    }

    setState(() => isLoading = true);

    try {
      final String docId =
          FirebaseFirestore.instance.collection("Announcements").doc().id;

      final String notifTitle = isUrgent
          ? "⚠️ URGENT: ${_titleController.text.trim()}"
          : _titleController.text.trim();
      final String notifBody = _descController.text.trim();

      final Map<String, dynamic> data = {
        "id": docId,
        "title": _titleController.text.trim(),
        "desc": _descController.text.trim(),
        "category": selectedCategory,
        "teacherName": _nameController.text.trim().isEmpty
            ? "Faculty Member"
            : _nameController.text.trim(),
        "target": sendToAll
            ? "All Students"
            : "$selectedDept ($selectedSem - $selectedShift)",
        "dept": sendToAll ? "all" : selectedDept.toLowerCase(),
        "sem": sendToAll ? "all" : selectedSem.toLowerCase(),
        "shift": sendToAll ? "all" : selectedShift.toLowerCase(),
        "timestamp": FieldValue.serverTimestamp(),
        "date": DateFormat('dd MMM, yyyy - hh:mm a').format(DateTime.now()),
        "isUrgent": isUrgent,
      };

      // Step 1: Save to Firestore
      await FirebaseFirestore.instance
          .collection("Announcements")
          .doc(docId)
          .set(data);
      debugPrint("✅ Announcement saved to Firestore: $docId");

      // Step 2: Send via OneSignal
      bool sent = false;
      if (sendToAll) {
        sent = await OneSignalService.sendToAll(
          title: notifTitle,
          body: notifBody,
          data: {'announcementId': docId, 'category': selectedCategory},
        );
      } else {
        sent = await OneSignalService.sendToSpecific(
          title: notifTitle,
          body: notifBody,
          dept: selectedDept,
          sem: selectedSem,
          shift: selectedShift,
          data: {'announcementId': docId, 'category': selectedCategory},
        );
      }

      if (mounted) {
        _showSuccessDialog(sent: sent);
        _titleController.clear();
        _descController.clear();
        _nameController.clear();
        setState(() {
          sendToAll = false;
          isUrgent = false;
        });
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
            "Failed to post announcement. Please try again.", isError: true);
      }
      debugPrint("❌ handlePost error: $e");
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ PROFESSIONAL SNACKBAR
  // ─────────────────────────────────────────────────────────────────────────

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                msg,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor:
            isError ? Colors.red.shade700 : const Color(0xFF8B0A1A),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showSuccessDialog({bool sent = true}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF8B0A1A).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded,
                  color: Color(0xFF8B0A1A), size: 20),
            ),
            const SizedBox(width: 12),
            const Text("Announcement Posted",
                style: TextStyle(
                    color: Color(0xFF8B0A1A),
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
          ],
        ),
        content: Text(
          sent
              ? "Your announcement has been published successfully. Push notifications have been sent to all relevant students."
              : "Your announcement has been saved to Firestore. Students will see it when they open the app.\n\nNote: Please verify your OneSignal REST API key if push notifications are not being delivered.",
          style: const TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Done",
                style: TextStyle(
                    color: Color(0xFF8B0A1A),
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(15, 27, 15, 20),
        child: Card(
          color: const Color(0xFFFDF2F3),
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
            side: const BorderSide(color: Color(0xFFFBC02D), width: 2),
          ),
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 10),
                  child: Column(
                    children: [
                      // Web banner
                      if (kIsWeb)
                        Container(
                          margin: const EdgeInsets.only(bottom: 15),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: Colors.green.withOpacity(0.4)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.check_circle_outline,
                                  color: Colors.green, size: 18),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "Web Mode: Push notifications will be delivered to mobile students via OneSignal.",
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.green),
                                ),
                              ),
                            ],
                          ),
                        ),

                      _buildInputField(_nameController,
                          "👤 Teacher Name", "Enter your name"),
                      _buildInputField(_titleController,
                          "📝 Title", "Enter announcement title"),
                      _buildInputField(
                        _descController,
                        "📄 Description",
                        "Enter full announcement details...",
                        lines: 4,
                      ),

                      const SizedBox(height: 10),

                      _buildDropdown("📂 Category", selectedCategory,
                          categories,
                          (v) => setState(() => selectedCategory = v!)),

                      _buildSwitch("📢 Broadcast to All Students",
                          sendToAll,
                          (v) => setState(() => sendToAll = v)),

                      if (!sendToAll) ...[
                        _buildDropdown("🏢 Department", selectedDept,
                            depts,
                            (v) => setState(() => selectedDept = v!)),
                        Row(
                          children: [
                            Expanded(
                              child: _buildDropdown(
                                  "🎓 Semester", selectedSem, sems,
                                  (v) =>
                                      setState(() => selectedSem = v!)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildDropdown(
                                  "⏰ Shift", selectedShift, shifts,
                                  (v) => setState(
                                      () => selectedShift = v!)),
                            ),
                          ],
                        ),

                        // Filter preview
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: Colors.grey.shade300),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.filter_alt_outlined,
                                    size: 14, color: Colors.grey),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    "Target: ${selectedDept.toLowerCase().replaceAll(' ', '_')}_${selectedSem.toLowerCase()}_${selectedShift.toLowerCase()}",
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      _buildUrgentToggle(),
                      const SizedBox(height: 25),

                      isLoading
                          ? const Column(
                              children: [
                                CircularProgressIndicator(
                                    color: Color(0xFF8B0A1A)),
                                SizedBox(height: 10),
                                Text(
                                  "Publishing announcement...",
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 13),
                                ),
                              ],
                            )
                          : _buildSubmitButton(),

                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildHeader() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            const Icon(Icons.campaign_rounded,
                size: 40, color: Color(0xFF8B0A1A)),
            const Text("NEW ANNOUNCEMENT",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF8B0A1A),
                    letterSpacing: 1)),
            Container(
              height: 2,
              width: 60,
              color: const Color(0xFFFBC02D),
              margin: const EdgeInsets.only(top: 5),
            ),
          ],
        ),
      );

  Widget _buildInputField(
      TextEditingController ctrl, String label, String hint,
      {int lines = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Color(0xFF8B0A1A))),
            const SizedBox(height: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.black12)),
              child: TextField(
                controller: ctrl,
                maxLines: lines,
                decoration: InputDecoration(
                    hintText: hint,
                    border: InputBorder.none,
                    hintStyle: const TextStyle(
                        fontSize: 12, color: Colors.black38)),
              ),
            ),
          ],
        ),
      );

  Widget _buildDropdown(String label, String value, List<String> items,
      Function(String?) onChanged) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Color(0xFF8B0A1A))),
            const SizedBox(height: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.black12)),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: value,
                  isExpanded: true,
                  onChanged: onChanged,
                  items: items
                      .map((e) => DropdownMenuItem(
                          value: e,
                          child: Text(e,
                              style: const TextStyle(fontSize: 13))))
                      .toList(),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildSwitch(
          String label, bool value, Function(bool) onChanged) =>
      SwitchListTile(
        title: Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13)),
        value: value,
        activeThumbColor: const Color(0xFF8B0A1A),
        onChanged: onChanged,
        contentPadding: EdgeInsets.zero,
      );

  Widget _buildUrgentToggle() => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: isUrgent
                ? Colors.red.withOpacity(0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isUrgent
                  ? Colors.red.withOpacity(0.3)
                  : Colors.transparent,
            )),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.priority_high_rounded,
                    color: isUrgent ? Colors.red : Colors.grey, size: 20),
                const SizedBox(width: 8),
                Text(
                  "Mark as Urgent",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isUrgent ? Colors.red : Colors.black54,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            Switch(
                value: isUrgent,
                activeThumbColor: Colors.red,
                onChanged: (v) => setState(() => isUrgent = v)),
          ],
        ),
      );

  Widget _buildSubmitButton() => ElevatedButton.icon(
        onPressed: _handlePost,
        icon: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
        label: const Text(
          "Publish & Notify Students",
          style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF8B0A1A),
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15)),
          elevation: 4,
        ),
      );
}