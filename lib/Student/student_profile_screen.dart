import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
class StudentProfileScreen extends StatefulWidget {
  const StudentProfileScreen({super.key});

  @override
  State<StudentProfileScreen> createState() => _StudentProfileScreenState();
}

class _StudentProfileScreenState extends State<StudentProfileScreen>
    with SingleTickerProviderStateMixin {
  static const Color _primary     = Color(0xFF8B0A1A);
  static const Color _gold        = Color(0xFFFBC02D);
  static const Color _bg          = Color(0xFFFDF2F3);

  final _auth   = FirebaseAuth.instance;
  final _db     = FirebaseFirestore.instance;
  final _picker = ImagePicker();

  bool _isLoading = true;
  bool _isEditing = false;
  bool _isSaving  = false;
  Map<String, dynamic> _userData = {};
  Uint8List? _newProfileBytes;
  int _picVersion = 0;

  late TextEditingController _firstNameCtrl;
  late TextEditingController _lastNameCtrl;
  late TextEditingController _fatherNameCtrl;
  late TextEditingController _contactCtrl;

  String _selectedShift    = 'Morning';
  String _selectedSemester = '1st';

  late AnimationController _fadeCtrl;
  late Animation<double>   _fadeAnim;
  late Animation<Offset>   _slideAnim;

  @override
  void initState() {
    super.initState();
    _firstNameCtrl  = TextEditingController();
    _lastNameCtrl   = TextEditingController();
    _fatherNameCtrl = TextEditingController();
    _contactCtrl    = TextEditingController();

    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _fadeAnim  = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
            begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut));

    _loadProfile();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _fatherNameCtrl.dispose();
    _contactCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  String _str(String key, [String fallback = '—']) {
    final val = _userData[key];
    return val == null ? fallback : val.toString();
  }

  Future<void> _loadProfile() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;
      final doc = await _db
          .collection("Users")
          .doc(uid)
          .get(const GetOptions(source: Source.serverAndCache));
      if (doc.exists) {
        final data      = doc.data() ?? {};
        final fullName  = data['name']?.toString() ?? '';
        final nameParts = fullName.trim().split(' ');
        setState(() {
          _userData            = data;
          _firstNameCtrl.text  = nameParts.isNotEmpty ? nameParts.first : '';
          _lastNameCtrl.text   =
              nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
          _fatherNameCtrl.text = data['fatherName']?.toString() ?? '';
          _contactCtrl.text    = data['contactNo']?.toString() ?? '';
          final shift = data['shift']?.toString() ?? '';
          _selectedShift =
              ['Morning', 'Evening'].contains(shift) ? shift : 'Morning';
          final sem = data['semester']?.toString() ?? '';
          _selectedSemester =
              ['1st','2nd','3rd','4th','5th','6th','7th','8th'].contains(sem)
                  ? sem : '1st';
          _isLoading = false;
        });
        _fadeCtrl.forward();
      }
    } catch (e) {
      debugPrint("Profile load error: $e");
      if (mounted) setState(() => _isLoading = false);
      _toast("Failed to load profile");
    }
  }

  Future<void> _pickNewProfilePic() async {
    try {
      final x = await _picker.pickImage(
          source: ImageSource.gallery, imageQuality: 80);
      if (x != null) {
        final b = await x.readAsBytes();
        if (mounted) setState(() => _newProfileBytes = b);
      }
    } catch (e) {
      _toast("Could not pick image: $e");
    }
  }

  Future<String?> _uploadToCloudinary(Uint8List bytes) async {
    String cloudName = dotenv.env['CLOUDINARY_CLOUD_NAME'] ?? '';
String uploadPreset = dotenv.env['CLOUDINARY_UPLOAD_PRESET'] ?? '';
    final uri = Uri.parse(
        "https://api.cloudinary.com/v1_1/$cloudName/image/upload");
    try {
      final req = http.MultipartRequest("POST", uri);
      req.fields['upload_preset'] = uploadPreset;
      req.files.add(http.MultipartFile.fromBytes(
        'file', bytes,
        filename: 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg',
        contentType: MediaType('image', 'jpeg'),
      ));
      final res          = await req.send();
      final responseData = await res.stream.bytesToString();
      debugPrint("Cloudinary Status: ${res.statusCode}");
      debugPrint("Cloudinary Response: $responseData");
      if (res.statusCode == 200 || res.statusCode == 201) {
        return jsonDecode(responseData)['secure_url'];
      }
      return null;
    } catch (e) {
      debugPrint("Cloudinary error: $e");
      return null;
    }
  }

  Future<void> _saveChanges() async {
    final phone = _contactCtrl.text.trim();
    if (!RegExp(r'^03[0-9]{9}$').hasMatch(phone)) {
      _toast("Enter valid Pakistani number (03XXXXXXXXX)");
      return;
    }
    setState(() => _isSaving = true);
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) throw Exception("Not logged in");

      String? newPicUrl;
      if (_newProfileBytes != null) {
        newPicUrl = await _uploadToCloudinary(_newProfileBytes!);
      }

      final updates = <String, dynamic>{
        "name"      : "${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}",
        "fatherName": _fatherNameCtrl.text.trim(),
        "contactNo" : phone,
        "shift"     : _selectedShift,
        "semester"  : _selectedSemester,
        if (newPicUrl != null) "profilePic": newPicUrl,
      };

      await _db.collection("Users").doc(uid).update(updates);

      if (newPicUrl != null) {
        try {
          final oldUrl = _userData['profilePic']?.toString();
          if (oldUrl != null && oldUrl.isNotEmpty) {
            await CachedNetworkImage.evictFromCache(oldUrl);
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _userData.addAll(updates);
          if (newPicUrl != null) {
            _userData['profilePic'] = newPicUrl;
            _picVersion++;
          }
          _newProfileBytes = null;
          _isEditing       = false;
        });
      }
      _toast("Profile updated successfully!");
    } catch (e) {
      _toast("Error saving: $e");
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _cancelEdit() {
    final nameParts =
        (_userData['name']?.toString() ?? '').trim().split(' ');
    _firstNameCtrl.text  = nameParts.isNotEmpty ? nameParts.first : '';
    _lastNameCtrl.text   =
        nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
    _fatherNameCtrl.text = _userData['fatherName']?.toString() ?? '';
    _contactCtrl.text    = _userData['contactNo']?.toString() ?? '';
    final shift = _userData['shift']?.toString() ?? '';
    _selectedShift =
        ['Morning', 'Evening'].contains(shift) ? shift : 'Morning';
    final sem = _userData['semester']?.toString() ?? '';
    _selectedSemester =
        ['1st','2nd','3rd','4th','5th','6th','7th','8th'].contains(sem)
            ? sem : '1st';
    setState(() {
      _newProfileBytes = null;
      _isEditing       = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: _primary));
  }

  // ══════════════════════════════════════════════
  //  BUILD
  //  ✅ EXACT same wrapper as StudentAnnouncementFragment:
  //     - backgroundColor: Colors.transparent  → dashboard header shows fully
  //     - outer Container with margin(15,25,15,60) + gold border + radius(30)
  // ══════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // ✅ Transparent — dashboard AppBar shows through fully (same as announcement)
      backgroundColor: Colors.transparent,
      body: Container(
        width: double.infinity,
        // ✅ Same exact margins as StudentAnnouncementFragment
        margin: const EdgeInsets.fromLTRB(15, 25, 15, 60),
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(30),
          // ✅ Same gold border as announcement screen
          border: Border.all(color: _gold, width: 2),
        ),
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: _primary))
            : SlideTransition(
                position: _slideAnim,
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: ClipRRect(
                    // Clip content to match container's rounded corners
                    borderRadius: BorderRadius.circular(28),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(children: [
                        _buildHeroCard(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                          child: Column(children: [
                            if (_isEditing) _buildLockedBanner(),
                            _buildSection(
                              icon: Icons.person_outline,
                              title: "Personal Info",
                              children: _isEditing
                                  ? [
                                      _buildEditRow("First Name", _firstNameCtrl),
                                      _buildEditRow("Last Name", _lastNameCtrl),
                                      _buildEditRow("Father's Name", _fatherNameCtrl),
                                      _buildEditRow("Contact", _contactCtrl,
                                          isPhone: true),
                                    ]
                                  : [
                                      _buildInfoRow(Icons.badge_outlined,
                                          "Full Name", _str('name')),
                                      _buildInfoRow(Icons.family_restroom,
                                          "Father's Name", _str('fatherName')),
                                      _buildInfoRow(Icons.phone_outlined,
                                          "Contact", _str('contactNo')),
                                      _buildInfoRow(
                                          _str('gender') == 'Female'
                                              ? Icons.female : Icons.male,
                                          "Gender", _str('gender')),
                                    ],
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              icon: Icons.school_outlined,
                              title: "Academic Info",
                              children: [
                                _buildInfoRow(Icons.numbers, "Reg. Number",
                                    _str('regNo'), locked: _isEditing),
                                _buildInfoRow(Icons.account_balance_outlined,
                                    "Department", _str('dept'),
                                    locked: _isEditing),
                                _buildInfoRow(Icons.calendar_today_outlined,
                                    "Batch", _str('batch'),
                                    locked: _isEditing),
                                if (_isEditing) ...[
                                  _buildDropRow(
                                      "Semester",
                                      ['1st','2nd','3rd','4th','5th','6th','7th','8th'],
                                      _selectedSemester,
                                      (v) => setState(() => _selectedSemester = v!)),
                                  _buildDropRow(
                                      "Shift", ['Morning', 'Evening'],
                                      _selectedShift,
                                      (v) => setState(() => _selectedShift = v!)),
                                ] else ...[
                                  _buildInfoRow(Icons.format_list_numbered,
                                      "Semester", _str('semester')),
                                  _buildInfoRow(Icons.wb_sunny_outlined,
                                      "Shift", _str('shift')),
                                ],
                              ],
                            ),
                            const SizedBox(height: 14),
                            _buildSection(
                              icon: Icons.lock_outline,
                              title: "Identity (Read-only)",
                              children: [
                                _buildInfoRow(Icons.fingerprint, "CNIC",
                                    _str('cnic'), locked: true),
                                _buildInfoRow(Icons.manage_accounts_outlined,
                                    "Role",
                                    _str('role', 'student').toUpperCase(),
                                    locked: true),
                              ],
                            ),
                            const SizedBox(height: 28),
                            _isEditing
                                ? _buildEditActions()
                                : _buildEditButton(),
                            const SizedBox(height: 16),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  // ══════════════════════════════════════════════
  //  HERO CARD — same as before
  // ══════════════════════════════════════════════
  Widget _buildHeroCard() {
    final profileUrl = _userData['profilePic']?.toString() ?? '';

    return SizedBox(
      width: double.infinity,
      height: 210,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // Curved painted card
          Positioned(
            top: 48, left: 20, right: 20,
            child: Container(
              height: 162,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Stack(children: [
                  CustomPaint(
                    size: const Size(double.infinity, 162),
                    painter: _ProfileCardPainter(),
                  ),
                  Positioned.fill(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 44),
                        Text(
                          _str('name', 'Student'),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _str('regNo', 'N/A'),
                          style: const TextStyle(
                              color: Color(0xFFFFCDD2), fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  // Edit icon
                  Positioned(
                    top: 10, right: 14,
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _isEditing = !_isEditing),
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isEditing ? Icons.close : Icons.edit_outlined,
                          color: Colors.white, size: 17,
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),

          // Overlapping profile pic
          Positioned(
            top: 0,
            child: GestureDetector(
              onTap: _isEditing ? _pickNewProfilePic : null,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Container(
                    width: 100, height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: _gold, width: 3),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 10)
                      ],
                    ),
                    child: ClipOval(
                      child: _newProfileBytes != null
                          ? Image.memory(_newProfileBytes!, fit: BoxFit.cover,
                              key: ValueKey('mem_$_picVersion'))
                          : profileUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  key: ValueKey('net_$_picVersion'),
                                  imageUrl: profileUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => const Center(
                                      child: CircularProgressIndicator(
                                          color: _primary, strokeWidth: 2)),
                                  errorWidget: (_, __, ___) => const Icon(
                                      Icons.person, size: 50,
                                      color: Colors.grey),
                                )
                              : Container(
                                  color: Colors.white,
                                  child: const Icon(Icons.person,
                                      size: 50, color: Colors.grey)),
                    ),
                  ),
                  if (_isEditing)
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _gold,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.camera_alt,
                          size: 13, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLockedBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFCC00).withOpacity(0.5)),
      ),
      child: const Row(children: [
        Icon(Icons.info_outline, size: 18, color: Color(0xFF856404)),
        SizedBox(width: 8),
        Expanded(
            child: Text("CNIC, Reg. No., Batch & Dept. cannot be changed.",
                style: TextStyle(fontSize: 12, color: Color(0xFF856404)))),
      ]),
    );
  }

  Widget _buildSection({
    required IconData     icon,
    required String       title,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 12,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: const BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: Color(0xFFF0E0E2), width: 1))),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: _primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 16, color: _primary),
            ),
            const SizedBox(width: 10),
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Color(0xFF1A0005))),
          ]),
        ),
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: children)),
      ]),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value,
      {bool locked = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Icon(icon, size: 18, color: locked ? Colors.grey : _primary),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: locked
                          ? Colors.grey[500]
                          : const Color(0xFF1A0005))),
            ])),
        if (locked)
          const Icon(Icons.lock_outline, size: 14, color: Colors.grey),
      ]),
    );
  }

  Widget _buildEditRow(String label, TextEditingController ctrl,
      {bool isPhone = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: TextField(
        controller: ctrl,
        keyboardType: isPhone ? TextInputType.phone : TextInputType.text,
        style: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600,
            color: Color(0xFF1A0005)),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: _primary, fontSize: 13),
          filled: true, fillColor: _bg,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _primary, width: 1.5)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: _primary.withOpacity(0.3))),
        ),
      ),
    );
  }

  Widget _buildDropRow(String label, List<String> items, String value,
      Function(String?) onChange) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(label,
              style: const TextStyle(
                  color: _primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              color: _bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _primary.withOpacity(0.3))),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value, isExpanded: true,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600,
                  color: Color(0xFF1A0005)),
              items: items
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: onChange,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildEditButton() {
    return SizedBox(
      width: double.infinity, height: 52,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          elevation: 3,
        ),
        icon:  const Icon(Icons.edit_outlined, color: Colors.white, size: 18),
        label: const Text("Edit Profile",
            style: TextStyle(color: Colors.white, fontSize: 15,
                fontWeight: FontWeight.w600)),
        onPressed: () => setState(() => _isEditing = true),
      ),
    );
  }

  Widget _buildEditActions() {
    return Row(children: [
      Expanded(
        child: SizedBox(
          height: 52,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _primary),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            icon:  const Icon(Icons.close, color: _primary, size: 18),
            label: const Text("Cancel",
                style: TextStyle(color: _primary, fontWeight: FontWeight.w600)),
            onPressed: _cancelEdit,
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 3,
            ),
            icon: _isSaving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.check, color: Colors.white, size: 18),
            label: Text(_isSaving ? "Saving..." : "Save Changes",
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
            onPressed: _isSaving ? null : _saveChanges,
          ),
        ),
      ),
    ]);
  }
}

// ══════════════════════════════════════════════
//  PAINTER — same as home screen
// ══════════════════════════════════════════════
class _ProfileCardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    double w = size.width;
    double h = size.height;
    final paint = Paint()..style = PaintingStyle.fill;

    paint.color = const Color(0xFF5A060D);
    final p1 = Path()
      ..lineTo(w, 0)..lineTo(w, h * 0.9)
      ..cubicTo(w * 0.75, h * 1.15, w * 0.25, h * 0.85, 0, h)
      ..close();
    canvas.drawPath(p1, paint);

    paint.color = const Color(0xFF8B0A1A);
    final p2 = Path()
      ..lineTo(w, 0)..lineTo(w, h * 0.7)
      ..cubicTo(w * 0.75, h * 0.95, w * 0.25, h * 0.7, 0, h * 0.85)
      ..close();
    canvas.drawPath(p2, paint);

    final stroke = Paint()
      ..color = const Color(0xFFFBC02D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final sp = Path()
      ..moveTo(0, h * 0.8)
      ..cubicTo(w * 0.25, h * 0.65, w * 0.75, h * 0.95, w, h * 0.7);
    canvas.drawPath(sp, stroke);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}