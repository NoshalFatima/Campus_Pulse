// lib/settings/settings_screen.dart

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // ── Notification toggles ───────────────────────────────────────────────────
  bool _announcementNotifs = true;
  bool _chatNotifs = true;
  bool _urgentNotifs = true;

  // ── Profile data (editable) ────────────────────────────────────────────────
  String _name = "";
  String _email = "";
  String _dept = "";
  String _sem = "";
  String _shift = "";
  String _rollNo = "";
  bool _isLoadingProfile = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadProfile();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _announcementNotifs = prefs.getBool('notif_announcements') ?? true;
      _chatNotifs = prefs.getBool('notif_chat') ?? true;
      _urgentNotifs = prefs.getBool('notif_urgent') ?? true;
    });
  }

  Future<void> _saveNotifPref(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _loadProfile() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('Users')
          .doc(user.uid)
          .get();
      if (doc.exists && mounted) {
        final d = doc.data()!;
        setState(() {
          _name = (d['name'] ?? d['displayName'] ?? '').toString().trim();
          _email = (d['email'] ?? user.email ?? '').toString().trim();
          _dept = (d['dept'] ?? '').toString().trim();
          _sem = (d['semester'] ?? d['sem'] ?? '').toString().trim();
          _shift = (d['shift'] ?? '').toString().trim();
          _rollNo = (d['rollNo'] ?? d['roll_no'] ?? '').toString().trim();
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingProfile = false);
    }
  }

  Future<void> _clearAnnouncementCache() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('read_announcements_${user.uid}');
    _showSnack("Announcement read history cleared.");
  }

  // ── CLEAR CACHE ────────────────────────────────────────────────────────────
  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Clear Cache",
            style: TextStyle(
                fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
        content: const Text(
            "This will delete all offline cached announcements from your device. "
            "Data will reload automatically when you're online."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel",
                  style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B0A1A),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Clear",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      const boxName = 'announcements_cache';
      if (Hive.isBoxOpen(boxName)) {
        // Box is open as typed Box<Announcement> — use it directly
        final box = Hive.box<dynamic>(boxName);
        await box.clear();
      }
      // Delete from disk so it reloads fresh next time
      await Hive.deleteBoxFromDisk(boxName);
      _showSnack("Cache cleared successfully.");
    } catch (e) {
      // Even if clear() fails, deleteBoxFromDisk handles it
      try {
        await Hive.deleteBoxFromDisk('announcements_cache');
        _showSnack("Cache cleared successfully.");
      } catch (_) {
        _showSnack("Cache cleared.");
      }
    }
  }

  // ── CHANGE PASSWORD ────────────────────────────────────────────────────────
  Future<void> _showChangePasswordDialog() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;
    bool isLoading = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialog) {
          Future<void> submit() async {
            final current = currentCtrl.text.trim();
            final newPass = newCtrl.text.trim();
            final confirm = confirmCtrl.text.trim();

            if (current.isEmpty || newPass.isEmpty || confirm.isEmpty) {
              _showSnack("Please fill in all fields.", isError: true);
              return;
            }
            if (newPass.length < 6) {
              _showSnack("New password must be at least 6 characters.",
                  isError: true);
              return;
            }
            if (newPass != confirm) {
              _showSnack("Passwords do not match.", isError: true);
              return;
            }

            setDialog(() => isLoading = true);

            try {
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) return;

              // Re-authenticate first
              final cred = EmailAuthProvider.credential(
                  email: user.email!, password: current);
              await user.reauthenticateWithCredential(cred);

              // Update password
              await user.updatePassword(newPass);

              Navigator.pop(ctx);
              _showSnack("Password changed successfully.");
            } on FirebaseAuthException catch (e) {
              setDialog(() => isLoading = false);
              String msg = "Something went wrong.";
              if (e.code == 'wrong-password' ||
                  e.code == 'invalid-credential') {
                msg = "Current password is incorrect.";
              } else if (e.code == 'weak-password') {
                msg = "New password is too weak.";
              } else if (e.code == 'requires-recent-login') {
                msg = "Please logout and login again before changing password.";
              }
              _showSnack(msg, isError: true);
            } catch (e) {
              setDialog(() => isLoading = false);
              _showSnack("Error: ${e.toString()}", isError: true);
            }
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: const Row(
              children: [
                Icon(Icons.lock_outline, color: Color(0xFF8B0A1A), size: 22),
                SizedBox(width: 8),
                Text("Change Password",
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFF8B0A1A))),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Current password
                  TextField(
                    controller: currentCtrl,
                    obscureText: obscureCurrent,
                    decoration: InputDecoration(
                      labelText: "Current Password",
                      prefixIcon: const Icon(Icons.lock_outline,
                          color: Color(0xFF8B0A1A), size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                            obscureCurrent
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: Colors.grey),
                        onPressed: () =>
                            setDialog(() => obscureCurrent = !obscureCurrent),
                      ),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: Color(0xFF8B0A1A), width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // New password
                  TextField(
                    controller: newCtrl,
                    obscureText: obscureNew,
                    decoration: InputDecoration(
                      labelText: "New Password",
                      prefixIcon: const Icon(Icons.lock_reset_outlined,
                          color: Color(0xFF8B0A1A), size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                            obscureNew
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: Colors.grey),
                        onPressed: () =>
                            setDialog(() => obscureNew = !obscureNew),
                      ),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: Color(0xFF8B0A1A), width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Confirm password
                  TextField(
                    controller: confirmCtrl,
                    obscureText: obscureConfirm,
                    decoration: InputDecoration(
                      labelText: "Confirm New Password",
                      prefixIcon: const Icon(Icons.check_circle_outline,
                          color: Color(0xFF8B0A1A), size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                            obscureConfirm
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: Colors.grey),
                        onPressed: () =>
                            setDialog(() => obscureConfirm = !obscureConfirm),
                      ),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: Color(0xFF8B0A1A), width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isLoading ? null : () => Navigator.pop(ctx),
                child: const Text("Cancel",
                    style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8B0A1A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  minimumSize: const Size(100, 42),
                ),
                onPressed: isLoading ? null : submit,
                child: isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text("Update",
                        style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        });
      },
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(isError ? Icons.error_outline : Icons.check_circle_outline,
            color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(msg,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500))),
      ]),
      backgroundColor:
          isError ? Colors.red.shade700 : const Color(0xFF8B0A1A),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(12),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF7F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFF8B0A1A),
        foregroundColor: Colors.white,
        title: const Text("Settings",
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: _isLoadingProfile
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF8B0A1A)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── ACCOUNT SECTION ─────────────────────────────────────
                _sectionHeader("Account"),
                _infoCard([
                  _infoRow(Icons.person_outline, "Name", _name),
                  _infoRow(Icons.email_outlined, "Email", _email),
                  _infoRow(Icons.school_outlined, "Department", _dept),
                  _infoRow(Icons.layers_outlined, "Semester", _sem),
                  _infoRow(Icons.schedule_outlined, "Shift", _shift),
                  _infoRow(Icons.badge_outlined, "Roll No", _rollNo),
                ]),

                const SizedBox(height: 20),

                // ── NOTIFICATIONS SECTION ───────────────────────────────
                _sectionHeader("Notifications"),
                _settingsCard([
                  _toggleTile(
                    icon: Icons.campaign_outlined,
                    title: "Announcement Notifications",
                    subtitle: "Get notified when new announcements are posted",
                    value: _announcementNotifs,
                    onChanged: (v) {
                      setState(() => _announcementNotifs = v);
                      _saveNotifPref('notif_announcements', v);
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  _toggleTile(
                    icon: Icons.chat_bubble_outline,
                    title: "Chat Notifications",
                    subtitle: "Get notified for new messages",
                    value: _chatNotifs,
                    onChanged: (v) {
                      setState(() => _chatNotifs = v);
                      _saveNotifPref('notif_chat', v);
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  _toggleTile(
                    icon: Icons.warning_amber_outlined,
                    title: "Urgent Alerts",
                    subtitle: "Always show urgent/important notifications",
                    value: _urgentNotifs,
                    onChanged: (v) {
                      setState(() => _urgentNotifs = v);
                      _saveNotifPref('notif_urgent', v);
                    },
                  ),
                ]),

                const SizedBox(height: 20),

                // ── DATA & PRIVACY ──────────────────────────────────────
                _sectionHeader("Data & Privacy"),
                _settingsCard([
                  // Change Password
                  ListTile(
                    leading: const Icon(Icons.lock_outline,
                        color: Color(0xFF8B0A1A), size: 22),
                    title: const Text("Change Password",
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    subtitle: const Text("Update your login password",
                        style: TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right,
                        color: Colors.grey, size: 20),
                    onTap: _showChangePasswordDialog,
                    dense: true,
                  ),
                  const Divider(height: 1, indent: 56),
                  // Clear Cache
                  ListTile(
                    leading: const Icon(Icons.cleaning_services_outlined,
                        color: Color(0xFF8B0A1A), size: 22),
                    title: const Text("Clear Cache",
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    subtitle: const Text(
                        "Delete offline cached announcements from device",
                        style: TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right,
                        color: Colors.grey, size: 20),
                    onTap: _clearCache,
                    dense: true,
                  ),
                  const Divider(height: 1, indent: 56),
                  // Clear Read History
                  ListTile(
                    leading: const Icon(Icons.done_all_rounded,
                        color: Color(0xFF8B0A1A), size: 22),
                    title: const Text("Clear Read History",
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    subtitle: const Text(
                        "Reset all announcements to unread",
                        style: TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right,
                        color: Colors.grey, size: 20),
                    onTap: _clearAnnouncementCache,
                    dense: true,
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.logout, color: Colors.red, size: 22),
                    title: const Text("Logout",
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.red)),
                    trailing: const Icon(Icons.chevron_right,
                        color: Colors.grey, size: 20),
                    onTap: () async {
                      await FirebaseAuth.instance.signOut();
                      if (mounted) {
                        Navigator.pushReplacementNamed(context, '/login');
                      }
                    },
                    dense: true,
                  ),
                ]),

                const SizedBox(height: 30),
                Center(
                  child: Text(
                    "Campus Pulse v1.0.0",
                    style: TextStyle(
                        color: Colors.grey.shade400, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Color(0xFF8B0A1A),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _infoCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFBC02D).withOpacity(0.4)),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)],
      ),
      child: Column(children: children),
    );
  }

  Widget _settingsCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)],
      ),
      child: Column(children: children),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF8B0A1A), size: 20),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade500)),
              const SizedBox(height: 2),
              Text(
                value.isNotEmpty ? value : "—",
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toggleTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon, color: const Color(0xFF8B0A1A), size: 22),
      title: Text(title,
          style:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      value: value,
      onChanged: onChanged,
      activeColor: const Color(0xFF8B0A1A),
      dense: true,
    );
  }
}