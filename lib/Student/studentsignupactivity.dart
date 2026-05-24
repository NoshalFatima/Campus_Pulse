import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import 'package:image/image.dart' as img;
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/face_service.dart';
import 'face_capture_screen.dart';

const int   kRequiredFaceCaptures = 5;
const int   kFaceCaptureDelayMs   = 800;
const Color kPrimary              = Color(0xFF8B0A1A);
const Color kBg                   = Color(0xFFFDF2F3);

class StudentSignupActivity extends StatefulWidget {
  const StudentSignupActivity({super.key});

  @override
  State<StudentSignupActivity> createState() => _StudentSignupActivityState();
}

class _StudentSignupActivityState extends State<StudentSignupActivity> {
  final _auth = FirebaseAuth.instance;
  final _db   = FirebaseFirestore.instance;
  bool _isLoading = false;

  // Controllers
  final _regNoCtrl     = TextEditingController();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl  = TextEditingController();
  final _fatherCtrl    = TextEditingController();
  final _contactCtrl   = TextEditingController();
  final _cnicCtrl      = TextEditingController();
  final _emailCtrl     = TextEditingController();

  final _cnicFormatter = MaskTextInputFormatter(
    mask: '#####-#######-#', filter: {'#': RegExp(r'[0-9]')});

  // Photo state
  Uint8List? _profileBytes;
  Uint8List? _facePreviewBytes;
  List<double>? _faceEmbedding;
  bool _faceEnrolled = false;

  final _picker = ImagePicker();

  // Dropdowns
  String _gender   = 'Select Gender';
  String _batch    = 'Select Batch';
  String _dept     = 'Select Department';
  String _shift    = 'Select Shift';
  String _semester = 'Select Semester';

  @override
  void initState() {
    super.initState();
    _initFaceService();
  }

  Future<void> _initFaceService() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try { await FaceService.instance.init(); } catch (e) {
      debugPrint('FaceService init: $e');
    }
  }

  // ── Pick profile photo ────────────────────────────────────────
  Future<void> _pickProfilePhoto() async {
    final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x != null) {
      final b = await x.readAsBytes();
      setState(() => _profileBytes = b);
    }
  }

  // ── Face capture ──────────────────────────────────────────────
  Future<void> _launchFaceCapture() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      _showToast('Camera is not available on this platform');
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) { _showToast('Camera nahi mila!'); return; }
    if (!mounted) return;
    final result = await Navigator.of(context).push<Map<String, dynamic>?>(
      MaterialPageRoute(
        builder: (_) => FaceCaptureScreen(cameras: cameras),
        fullscreenDialog: true,
      ),
    );
    if (result != null) {
      setState(() {
        _faceEmbedding    = result['embedding'] as List<double>;
        _facePreviewBytes = result['previewBytes'] as Uint8List;
        _faceEnrolled     = true;
      });
      _showToast('Face successfully enroll ho gaya! ✅');
    }
  }

  // ── Cloudinary upload ─────────────────────────────────────────
  Future<String?> _uploadToCloudinary(Uint8List bytes) async {
    final cloudName    = dotenv.env['CLOUDINARY_CLOUD_NAME'] ?? '';
    final uploadPreset = dotenv.env['CLOUDINARY_UPLOAD_PRESET'] ?? '';
    final uri = Uri.parse('https://api.cloudinary.com/v1_1/$cloudName/image/upload');
    final req = http.MultipartRequest('POST', uri)
      ..fields['upload_preset'] = uploadPreset
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'upload.jpg'));
    final res = await req.send();
    if (res.statusCode == 200) {
      final data = await res.stream.toBytes();
      return jsonDecode(String.fromCharCodes(data))['secure_url'];
    }
    return null;
  }

  // ════════════════════════════════════════════════════════════════
  //  UNIQUE FIELD CHECKS
  // ════════════════════════════════════════════════════════════════

  /// Returns an error message if the field is already taken, null if free.
  Future<String?> _checkUnique(String field, String value) async {
    final snap = await _db
        .collection('Users')
        .where(field, isEqualTo: value)
        .limit(1)
        .get();
    if (snap.docs.isNotEmpty) return field;
    return null;
  }

  Future<bool> _runUniqueChecks() async {
    final checks = await Future.wait([
      _checkUnique('regNo',     _regNoCtrl.text.trim()),
      _checkUnique('cnic',      _cnicCtrl.text.trim()),
      _checkUnique('contactNo', _contactCtrl.text.trim()),
      _checkUnique('email',     _emailCtrl.text.trim().toLowerCase()),
    ]);

    final fieldLabels = {
      'regNo'     : 'Registration Number',
      'cnic'      : 'CNIC',
      'contactNo' : 'Phone Number',
      'email'     : 'Email',
    };

    final duplicates = checks
        .whereType<String>()
        .map((f) => fieldLabels[f] ?? f)
        .toList();

    if (duplicates.isNotEmpty) {
      _showToast('${duplicates.join(', ')} already exists!');
      return false;
    }
    return true;
  }

  // ── Basic validation ──────────────────────────────────────────
  String? _validateFields() {
    if (_profileBytes == null)
      return 'Profile photo zaroor chahiye!';
    if (!_faceEnrolled || _faceEmbedding == null)
      return 'Pehle apna face scan karein!';
    if (_regNoCtrl.text.trim().isEmpty)
      return 'Registration number daalen!';
    if (_firstNameCtrl.text.trim().isEmpty || _lastNameCtrl.text.trim().isEmpty)
      return 'Poora naam daalen!';
    if (_fatherCtrl.text.trim().isEmpty)
      return "Father's name daalen!";
    if (!RegExp(r'^03[0-9]{9}$').hasMatch(_contactCtrl.text.trim()))
      return 'Valid Pakistani number daalen (03XXXXXXXXX)';
    if (_cnicCtrl.text.replaceAll(RegExp(r'[^0-9]'), '').length != 13)
      return 'Valid CNIC daalen!';
    if (!RegExp(r'^[\w.+-]+@[\w-]+\.[a-zA-Z]{2,}$')
        .hasMatch(_emailCtrl.text.trim()))
      return 'Valid email daalen!';
    if ([_gender, _batch, _dept, _shift, _semester]
        .any((v) => v.startsWith('Select')))
      return 'Saare dropdown options select karein!';
    return null;
  }

  // ── Main signup handler ───────────────────────────────────────
  Future<void> _handleSignup() async {
    // 1. Basic validation
    final validationError = _validateFields();
    if (validationError != null) {
      _showToast(validationError);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 2. Unique checks (Firestore queries)
      final isUnique = await _runUniqueChecks();
      if (!isUnique) {
        setState(() => _isLoading = false);
        return;
      }

      // 3. FCM token
      String? token = 'no_token';
      if (!kIsWeb) token = await FirebaseMessaging.instance.getToken();

      // 4. Upload images
      final profileUrl = await _uploadToCloudinary(_profileBytes!);
      final faceUrl    = _facePreviewBytes != null
          ? await _uploadToCloudinary(_facePreviewBytes!) : null;

      // 5. Save to Firestore
      final user = _auth.currentUser;
      await _db.collection('Users').doc(user?.uid).set({
        'regNo'       : _regNoCtrl.text.trim(),
        'name'        : '${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}',
        'fatherName'  : _fatherCtrl.text.trim(),
        'contactNo'   : _contactCtrl.text.trim(),
        'cnic'        : _cnicCtrl.text.trim(),
        'email'       : _emailCtrl.text.trim().toLowerCase(),
        'gender'      : _gender,
        'batch'       : _batch,
        'dept'        : _dept,
        'shift'       : _shift,
        'semester'    : _semester,
        'faceData'    : _faceEmbedding!.join(','),
        'profilePic'  : profileUrl,
        'faceImageUrl': faceUrl,
        'fcmToken'    : token,
        'role'        : 'student',
        'createdAt'   : FieldValue.serverTimestamp(),
      });

      _showToast('Signup kamyab ho gaya! 🎉');
      if (mounted) Navigator.pushReplacementNamed(context, '/student_dashboard');
    } catch (e) {
      _showToast('Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ════════════════════════════════════════════════════════════════
  //  BUILD
  // ════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: kPrimary))
          : SingleChildScrollView(
              child: Column(children: [
                _buildHeader(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 12, offset: const Offset(0, 4),
                      )],
                    ),
                    child: Column(children: [
                      const SizedBox(height: 24),
                      _buildPhotoRow(),
                      _buildFaceStatusBanner(),
                      const SizedBox(height: 20),

                      // ── Personal Info ──────────────────────────
                      _sectionHeader('Personal Information'),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(children: [
                          _labeledField('Registration Number', _regNoCtrl,
                              hint: 'Enter registration number'),
                          Row(children: [
                            Expanded(child: _labeledField('First Name', _firstNameCtrl,
                                hint: 'Enter first name')),
                            const SizedBox(width: 12),
                            Expanded(child: _labeledField('Last Name', _lastNameCtrl,
                                hint: 'Enter last name')),
                          ]),
                          _labeledField("Father's Name", _fatherCtrl,
                              hint: "Enter father's name"),
                          _labeledField('Phone Number', _contactCtrl,
                              hint: '03XXXXXXXXX', isPhone: true),
                          _labeledField('CNIC', _cnicCtrl,
                              hint: 'XXXXX-XXXXXXX-X', formatter: _cnicFormatter),
                          // ── Email (new unique field) ──────────
                          _labeledField('Email Address', _emailCtrl,
                              hint: 'example@email.com', isEmail: true),
                        ]),
                      ),

                      const SizedBox(height: 8),

                      // ── Academic Info ──────────────────────────
                      _sectionHeader('Academic Information'),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(children: [
                          _labeledDrop('Gender',
                            ['Select Gender', 'Male', 'Female', 'Other'],
                            _gender, (v) => setState(() => _gender = v!)),
                          _labeledDrop('Batch',
                            ['Select Batch', '2021', '2022', '2023', '2024', '2025'],
                            _batch, (v) => setState(() => _batch = v!)),
                          _labeledDrop('Department',
                            ['Select Department', 'Computer Science', 'Zoology',
                             'Mathematics', 'English', 'Urdu', 'Physics', 'Pol Science'],
                            _dept, (v) => setState(() => _dept = v!)),
                          _labeledDrop('Shift',
                            ['Select Shift', 'Morning', 'Evening'],
                            _shift, (v) => setState(() => _shift = v!)),
                          _labeledDrop('Semester',
                            ['Select Semester', '1st', '2nd', '3rd', '4th',
                             '5th', '6th', '7th', '8th'],
                            _semester, (v) => setState(() => _semester = v!)),
                        ]),
                      ),

                      const SizedBox(height: 28),

                      // ── Submit ─────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: SizedBox(
                          width: double.infinity, height: 54,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kPrimary,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              elevation: 3,
                            ),
                            onPressed: _handleSignup,
                            child: const Text('Complete Signup',
                              style: TextStyle(color: Colors.white,
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                    ]),
                  ),
                ),
                const SizedBox(height: 30),
              ]),
            ),
    );
  }

  // ── Header with logo1.jpeg ────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 56, bottom: 32),
      decoration: const BoxDecoration(color: kBg),
      child: Column(children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: kPrimary, width: 2.5),
            boxShadow: [BoxShadow(
              color: kPrimary.withOpacity(0.15),
              blurRadius: 12, offset: const Offset(0, 4),
            )],
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/logo1.jpeg',
              fit: BoxFit.cover,
              // fallback if asset somehow missing
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.school_rounded, color: kPrimary, size: 40),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Student Signup',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold,
              color: kPrimary)),
        const SizedBox(height: 6),
        Text('Complete your Signup process',
          style: TextStyle(fontSize: 14, color: Colors.grey[600])),
      ]),
    );
  }

  // ── Photo row ─────────────────────────────────────────────────
  Widget _buildPhotoRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Expanded(child: _photoCard(
          icon: Icons.person_rounded,
          title: 'Profile Picture',
          subtitle: 'For display in app',
          buttonLabel: _profileBytes == null ? 'Select from Gallery' : 'Change Photo',
          previewBytes: _profileBytes,
          onTap: _pickProfilePhoto,
          enrolled: _profileBytes != null,
        )),
        const SizedBox(width: 12),
        Expanded(child: _photoCard(
          icon: Icons.face_retouching_natural_rounded,
          title: 'Face Recognition',
          subtitle: 'For attendance system',
          buttonLabel: _faceEnrolled ? 'Re-capture Face' : 'Capture Face',
          previewBytes: _facePreviewBytes,
          onTap: _launchFaceCapture,
          enrolled: _faceEnrolled,
        )),
      ]),
    );
  }

  Widget _photoCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required String buttonLabel,
    required Uint8List? previewBytes,
    required VoidCallback onTap,
    required bool enrolled,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enrolled ? kPrimary.withOpacity(0.4) : Colors.grey.shade200,
          width: enrolled ? 1.5 : 1,
        ),
      ),
      child: Column(children: [
        Container(
          width: 70, height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: kPrimary, width: 2),
            image: previewBytes != null
                ? DecorationImage(
                    image: MemoryImage(previewBytes), fit: BoxFit.cover)
                : null,
          ),
          child: previewBytes == null
              ? Icon(icon, color: kPrimary, size: 32)
              : null,
        ),
        const SizedBox(height: 10),
        Text(title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.bold,
              color: kPrimary, fontSize: 13)),
        const SizedBox(height: 4),
        Text(subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: kPrimary,
              padding: const EdgeInsets.symmetric(vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            onPressed: onTap,
            child: Text(buttonLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white,
                  fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }

  // ── Face status banner ────────────────────────────────────────
  Widget _buildFaceStatusBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: _faceEnrolled
              ? const Color(0xFFE8F5E9)
              : const Color(0xFFFFF8E1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _faceEnrolled
                ? Colors.green.shade300
                : kPrimary.withOpacity(0.4),
          ),
        ),
        child: Row(children: [
          Icon(
            _faceEnrolled
                ? Icons.check_circle_rounded
                : Icons.warning_amber_rounded,
            color: _faceEnrolled ? Colors.green : kPrimary,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(
            _faceEnrolled
                ? 'Face successfully register ho gaya hai ✅'
                : 'Face not registered for attendance',
            style: TextStyle(
              fontSize: 13,
              color: _faceEnrolled ? Colors.green[800] : Colors.red[900],
              fontWeight: FontWeight.w500,
            ),
          )),
        ]),
      ),
    );
  }

  // ── Section header ────────────────────────────────────────────
  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold,
              color: Colors.black87)),
      ),
    );
  }

  // ── Labeled text field ────────────────────────────────────────
  Widget _labeledField(
    String label,
    TextEditingController c, {
    String hint = '',
    bool isPhone = false,
    bool isEmail = false,
    dynamic formatter,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(
            fontWeight: FontWeight.bold, color: kPrimary, fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          inputFormatters: formatter != null ? [formatter] : [],
          keyboardType: isPhone
              ? TextInputType.phone
              : isEmail
                  ? TextInputType.emailAddress
                  : TextInputType.text,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
            filled: true,
            fillColor: const Color(0xFFFAFAFA),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 14),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: kPrimary.withOpacity(0.4), width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: kPrimary, width: 2),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Labeled dropdown ──────────────────────────────────────────
  Widget _labeledDrop(String label, List<String> items, String value,
      Function(String?) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(
            fontWeight: FontWeight.bold, color: kPrimary, fontSize: 13)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFAFAFA),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: kPrimary.withOpacity(0.4), width: 1.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down_rounded,
                  color: kPrimary),
              items: items.map((s) => DropdownMenuItem(
                value: s,
                child: Text(s, style: const TextStyle(fontSize: 14)),
              )).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ]),
    );
  }
}