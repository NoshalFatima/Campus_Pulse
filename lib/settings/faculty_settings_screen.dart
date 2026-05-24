
// lib/settings/faculty_settings_screen.dart

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';

class FacultySettingsScreen extends StatefulWidget {
  const FacultySettingsScreen({super.key});

  @override
  State<FacultySettingsScreen> createState() => _FacultySettingsScreenState();
}

class _FacultySettingsScreenState extends State<FacultySettingsScreen> {
  // ── Profile data ───────────────────────────────────────────────────────────
  String _name          = '';
  String _email         = '';
  String _employeeId    = '';
  String _fatherName    = '';
  String _contact       = '';
  String _cnic          = '';
  String _gender        = '';
  String _designation   = '';
  String _dept          = '';
  String _qualification = '';
  String _experience    = '';
  String _grade         = '';
  String _majorSubject  = '';
  String _joiningDate   = '';
  String _profilePic    = '';
  bool   _isLoading     = true;
  bool   _isUploading   = false;

  // ── Notification prefs ─────────────────────────────────────────────────────
  bool _announcementNotifs = true;
  bool _chatNotifs         = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadPrefs();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LOAD PROFILE
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadProfile() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final doc = await FirebaseFirestore.instance
          .collection('Users')
          .doc(user.uid)
          .get();

      if (!doc.exists || !mounted) return;
      final d = doc.data()!;

      setState(() {
        _name          = d['name']          ?? '';
        _email         = d['email']         ?? user.email ?? '';
        _employeeId    = d['employeeId']    ?? '';
        _fatherName    = d['fatherName']    ?? '';
        _contact       = d['contactNumber'] ?? d['contactNo'] ?? '';
        _cnic          = d['cnic']          ?? '';
        _gender        = d['gender']        ?? '';
        _designation   = d['designation']   ?? '';
        _dept          = d['dept']          ?? '';
        _qualification = d['qualification'] ?? '';
        _experience    = d['experience']    ?? '';
        _grade         = d['grade']         ?? '';
        _majorSubject  = d['majorSubject']  ?? '';
        _joiningDate   = d['joiningDate']   ?? '';
        _profilePic    = d['profilePic']    ?? '';
        _isLoading     = false;
      });
    } catch (e) {
      debugPrint("❌ Faculty settings load: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _announcementNotifs = prefs.getBool('notif_announcements') ?? true;
      _chatNotifs         = prefs.getBool('notif_chat')          ?? true;
    });
  }

  Future<void> _savePref(String key, bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, val);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CHANGE PROFILE PHOTO
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _changePhoto() async {
    final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return;

    setState(() => _isUploading = true);
    try {
      final bytes = await picked.readAsBytes();
      final url   = await _uploadToCloudinary(bytes);
      if (url == null) { _showSnack("Upload failed.", isError: true); return; }

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await FirebaseFirestore.instance
          .collection('Users')
          .doc(user.uid)
          .update({'profilePic': url});

      setState(() => _profilePic = url);
      _showSnack("Profile photo updated.");
    } catch (e) {
      _showSnack("Error: $e", isError: true);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<String?> _uploadToCloudinary(Uint8List bytes) async {
    try {
      const cloudName    = "drp97v6nd";
      const uploadPreset = "unsigned_preset";
      final uri = Uri.parse(
          "https://api.cloudinary.com/v1_1/$cloudName/image/upload");
      final req = http.MultipartRequest("POST", uri)
        ..fields['upload_preset'] = uploadPreset
        ..files.add(http.MultipartFile.fromBytes('file', bytes,
            filename: 'faculty_profile.jpg'));
      final res  = await req.send();
      final data = await res.stream.toBytes();
      if (res.statusCode == 200) {
        return jsonDecode(String.fromCharCodes(data))['secure_url'];
      }
    } catch (e) {
      debugPrint("❌ Cloudinary: $e");
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CHANGE PASSWORD
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _showChangePasswordDialog() async {
    final currentCtrl = TextEditingController();
    final newCtrl     = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool obscCurrent  = true;
    bool obscNew      = true;
    bool obscConfirm  = true;
    bool isLoading    = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Future<void> submit() async {
          final cur  = currentCtrl.text.trim();
          final nw   = newCtrl.text.trim();
          final conf = confirmCtrl.text.trim();
          if (cur.isEmpty || nw.isEmpty || conf.isEmpty) {
            _showSnack("Fill all fields.", isError: true); return;
          }
          if (nw.length < 6) {
            _showSnack("Min 6 characters.", isError: true); return;
          }
          if (nw != conf) {
            _showSnack("Passwords don't match.", isError: true); return;
          }
          set(() => isLoading = true);
          try {
            final user = FirebaseAuth.instance.currentUser!;
            final cred = EmailAuthProvider.credential(
                email: user.email!, password: cur);
            await user.reauthenticateWithCredential(cred);
            await user.updatePassword(nw);
            Navigator.pop(ctx);
            _showSnack("Password updated.");
          } on FirebaseAuthException catch (e) {
            set(() => isLoading = false);
            _showSnack(
              e.code == 'wrong-password' || e.code == 'invalid-credential'
                  ? "Current password is incorrect."
                  : e.code == 'weak-password'
                      ? "Password too weak."
                      : "Something went wrong.",
              isError: true,
            );
          }
        }

        return AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: const Row(children: [
            Icon(Icons.lock_outline, color: Color(0xFF8B0A1A)),
            SizedBox(width: 8),
            Text("Change Password",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Color(0xFF8B0A1A))),
          ]),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _passField("Current Password", currentCtrl, obscCurrent,
                  () => set(() => obscCurrent = !obscCurrent),
                  Icons.lock_outline),
              const SizedBox(height: 12),
              _passField("New Password", newCtrl, obscNew,
                  () => set(() => obscNew = !obscNew),
                  Icons.lock_reset_outlined),
              const SizedBox(height: 12),
              _passField("Confirm Password", confirmCtrl, obscConfirm,
                  () => set(() => obscConfirm = !obscConfirm),
                  Icons.check_circle_outline),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: isLoading ? null : () => Navigator.pop(ctx),
                child: const Text("Cancel",
                    style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8B0A1A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: isLoading ? null : submit,
              child: isLoading
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text("Update",
                      style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      }),
    );
  }

  Widget _passField(String label, TextEditingController c, bool obscure,
      VoidCallback toggle, IconData icon) {
    return TextField(
      controller: c,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: const Color(0xFF8B0A1A), size: 20),
        suffixIcon: IconButton(
          icon: Icon(
              obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 20, color: Colors.grey),
          onPressed: toggle,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                const BorderSide(color: Color(0xFF8B0A1A), width: 1.5)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CLEAR CACHE
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _clearCache() async {
    final confirmed = await _confirm(
      "Clear Cache",
      "Offline cached data will be deleted and reloaded when online.",
    );
    if (!confirmed) return;
    try {
      const boxName = 'announcements_cache';
      if (Hive.isBoxOpen(boxName)) await Hive.box(boxName).clear();
      await Hive.deleteBoxFromDisk(boxName);
      _showSnack("Cache cleared.");
    } catch (_) {
      _showSnack("Cache cleared.");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CLEAR READ HISTORY
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _clearReadHistory() async {
    final confirmed = await _confirm(
      "Clear Read History",
      "All announcements will be marked as unread.",
    );
    if (!confirmed) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('read_announcements_${user.uid}');
    _showSnack("Read history cleared.");
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────
  Future<bool> _confirm(String title, String msg) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            title: Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF8B0A1A))),
            content: Text(msg, style: const TextStyle(fontSize: 13.5)),
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
                child: const Text("Confirm",
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
            isError
                ? Icons.error_outline
                : Icons.check_circle_outline,
            color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(msg,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500))),
      ]),
      backgroundColor:
          isError ? Colors.red.shade700 : const Color(0xFF8B0A1A),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(12),
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
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
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                  color: Color(0xFF8B0A1A)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── PROFILE PHOTO ──────────────────────────────────────
                Center(
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 52,
                        backgroundColor: const Color(0xFF8B0A1A),
                        child: CircleAvatar(
                          radius: 49,
                          backgroundColor: Colors.white,
                          backgroundImage: _profilePic.isNotEmpty
                              ? NetworkImage(_profilePic)
                              : null,
                          child: _profilePic.isEmpty
                              ? Text(
                                  _name.isNotEmpty
                                      ? _name[0].toUpperCase()
                                      : 'F',
                                  style: const TextStyle(
                                      fontSize: 36,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF8B0A1A)))
                              : null,
                        ),
                      ),
                      if (_isUploading)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                                color: Colors.black38,
                                shape: BoxShape.circle),
                            child: const Center(
                                child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2)),
                          ),
                        ),
                      Positioned(
                        bottom: 0, right: 0,
                        child: GestureDetector(
                          onTap: _isUploading ? null : _changePhoto,
                          child: Container(
                            padding: const EdgeInsets.all(7),
                            decoration: const BoxDecoration(
                                color: Color(0xFF8B0A1A),
                                shape: BoxShape.circle),
                            child: const Icon(Icons.camera_alt,
                                color: Colors.white, size: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: Text(_name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Color(0xFF8B0A1A))),
                ),
                Center(
                  child: Text(_designation.isNotEmpty ? _designation : 'Faculty',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                ),
                const SizedBox(height: 20),

                // ── ACCOUNT INFO ───────────────────────────────────────
                _sectionHeader("Account Information"),
                _infoCard([
                  _infoRow(Icons.badge_outlined,        "Employee ID",    _employeeId),
                  _infoRow(Icons.person_outline,        "Full Name",      _name),
                  _infoRow(Icons.email_outlined,        "Email",          _email),
                  _infoRow(Icons.family_restroom,       "Father's Name",  _fatherName),
                  _infoRow(Icons.phone_outlined,        "Contact",        _contact),
                  _infoRow(Icons.contact_page_outlined, "CNIC",           _cnic),
                  _infoRow(Icons.wc_outlined,           "Gender",         _gender),
                  _infoRow(Icons.calendar_today_outlined,"Joining Date",  _joiningDate),
                ]),
                const SizedBox(height: 20),

                // ── ACADEMIC INFO ──────────────────────────────────────
                _sectionHeader("Academic Details"),
                _infoCard([
                  _infoRow(Icons.school_outlined,       "Department",     _dept),
                  _infoRow(Icons.work_outline,          "Designation",    _designation),
                  _infoRow(Icons.emoji_events_outlined, "Qualification",  _qualification),
                  _infoRow(Icons.timeline_outlined,     "Experience",     _experience.isNotEmpty ? "$_experience years" : ''),
                  _infoRow(Icons.grade_outlined,        "Grade",          _grade),
                  _infoRow(Icons.menu_book_outlined,    "Major Subject",  _majorSubject),
                ]),
                const SizedBox(height: 20),

                // ── NOTIFICATIONS ──────────────────────────────────────
                _sectionHeader("Notifications"),
                _settingsCard([
                  _toggleTile(
                    icon: Icons.campaign_outlined,
                    title: "Announcement Notifications",
                    subtitle: "Get notified for new announcements",
                    value: _announcementNotifs,
                    onChanged: (v) {
                      setState(() => _announcementNotifs = v);
                      _savePref('notif_announcements', v);
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
                      _savePref('notif_chat', v);
                    },
                  ),
                ]),
                const SizedBox(height: 20),

                // ── DATA & PRIVACY ─────────────────────────────────────
                _sectionHeader("Data & Privacy"),
                _settingsCard([
                  _actionTile(
                    icon: Icons.lock_outline,
                    title: "Change Password",
                    subtitle: "Update your login password",
                    onTap: _showChangePasswordDialog,
                  ),
                  const Divider(height: 1, indent: 56),
                  _actionTile(
                    icon: Icons.cleaning_services_outlined,
                    title: "Clear Cache",
                    subtitle: "Delete offline cached data",
                    onTap: _clearCache,
                  ),
                  const Divider(height: 1, indent: 56),
                  _actionTile(
                    icon: Icons.done_all_rounded,
                    title: "Clear Read History",
                    subtitle: "Reset all announcements to unread",
                    onTap: _clearReadHistory,
                  ),
                  const Divider(height: 1, indent: 56),
                  _actionTile(
                    icon: Icons.logout,
                    title: "Logout",
                    subtitle: "",
                    isRed: true,
                    onTap: () async {
                      final ok = await _confirm("Logout",
                          "Are you sure you want to logout?");
                      if (ok) {
                        await FirebaseAuth.instance.signOut();
                        if (mounted) {
                          Navigator.pushReplacementNamed(
                              context, '/login');
                        }
                      }
                    },
                  ),
                ]),

                const SizedBox(height: 30),
                Center(
                  child: Text("Campus Pulse v1.0.0",
                      style: TextStyle(
                          color: Colors.grey.shade400, fontSize: 12)),
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI HELPERS
  // ─────────────────────────────────────────────────────────────────────────
  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF8B0A1A),
                letterSpacing: 1.2)),
      );

  Widget _infoCard(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: const Color(0xFFFBC02D).withOpacity(0.4)),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 6)
          ],
        ),
        child: Column(children: children),
      );

  Widget _settingsCard(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 6)
          ],
        ),
        child: Column(children: children),
      );

  Widget _infoRow(IconData icon, String label, String value) =>
      Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF8B0A1A), size: 20),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade500)),
              const SizedBox(height: 2),
              Text(value.isNotEmpty ? value : '—',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500)),
            ]),
          ],
        ),
      );

  Widget _toggleTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      SwitchListTile(
        secondary:
            Icon(icon, color: const Color(0xFF8B0A1A), size: 22),
        title: Text(title,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle,
            style: TextStyle(
                fontSize: 11, color: Colors.grey.shade500)),
        value: value,
        onChanged: onChanged,
        activeColor: const Color(0xFF8B0A1A),
        dense: true,
      );

  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isRed = false,
  }) =>
      ListTile(
        leading: Icon(icon,
            color: isRed ? Colors.red : const Color(0xFF8B0A1A),
            size: 22),
        title: Text(title,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isRed ? Colors.red : null)),
        subtitle: subtitle.isNotEmpty
            ? Text(subtitle,
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade500))
            : null,
        trailing: const Icon(Icons.chevron_right,
            color: Colors.grey, size: 20),
        onTap: onTap,
        dense: true,
      );
}
