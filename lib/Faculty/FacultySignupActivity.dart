import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:intl/intl.dart';

const Color kPrimary = Color(0xFF8B0A1A);
const Color kBg      = Color(0xFFFDF2F3);

class FacultySignupActivity extends StatefulWidget {
  const FacultySignupActivity({super.key});

  @override
  State<FacultySignupActivity> createState() => _FacultySignupActivityState();
}

class _FacultySignupActivityState extends State<FacultySignupActivity> {
  final _auth = FirebaseAuth.instance;
  final _db   = FirebaseFirestore.instance;
  bool _isLoading = false;

  // Controllers
  final _empIdCtrl        = TextEditingController();
  final _fNameCtrl        = TextEditingController();
  final _lNameCtrl        = TextEditingController();
  final _fatherCtrl       = TextEditingController();
  final _contactCtrl      = TextEditingController();
  final _cnicCtrl         = TextEditingController();
  final _emailCtrl        = TextEditingController();
  final _qualCtrl         = TextEditingController();
  final _expCtrl          = TextEditingController();
  final _gradeCtrl        = TextEditingController();
  final _majorSubjectCtrl = TextEditingController();

  final _cnicFormatter = MaskTextInputFormatter(
      mask: '#####-#######-#', filter: {'#': RegExp(r'[0-9]')});

  Uint8List? _profileBytes;
  String _joiningDate = 'Select Joining Date';

  // Dropdowns
  String _gender      = 'Select Gender';
  String _designation = 'Select Designation';
  String _dept        = 'Select Department';

  // ── Cloudinary ────────────────────────────────────────────────
  Future<String?> _uploadToCloudinary(Uint8List bytes) async {
    final cloudName    = dotenv.env['CLOUDINARY_CLOUD_NAME'] ?? '';
    final uploadPreset = dotenv.env['CLOUDINARY_UPLOAD_PRESET'] ?? '';
    final uri = Uri.parse('https://api.cloudinary.com/v1_1/$cloudName/image/upload');
    final req = http.MultipartRequest('POST', uri)
      ..fields['upload_preset'] = uploadPreset
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: 'faculty_profile.jpg'));
    final res = await req.send();
    if (res.statusCode == 200) {
      final data = await res.stream.toBytes();
      return jsonDecode(String.fromCharCodes(data))['secure_url'];
    }
    return null;
  }

  // ════════════════════════════════════════════════════════════════
  //  UNIQUE CHECKS
  // ════════════════════════════════════════════════════════════════
  Future<String?> _checkUnique(String field, String value) async {
    final snap = await _db
        .collection('Users')
        .where(field, isEqualTo: value)
        .limit(1)
        .get();
    return snap.docs.isNotEmpty ? field : null;
  }

  Future<bool> _runUniqueChecks() async {
    final results = await Future.wait([
      _checkUnique('employeeId', _empIdCtrl.text.trim()),
      _checkUnique('cnic',       _cnicCtrl.text.trim()),
      _checkUnique('contactNo',  _contactCtrl.text.trim()),
      _checkUnique('email',      _emailCtrl.text.trim().toLowerCase()),
    ]);

    const labels = {
      'employeeId': 'Employee ID',
      'cnic'      : 'CNIC',
      'contactNo' : 'Phone Number',
      'email'     : 'Email',
    };

    final duplicates = results
        .whereType<String>()
        .map((f) => labels[f] ?? f)
        .toList();

    if (duplicates.isNotEmpty) {
      _showToast('${duplicates.join(', ')} already exists!');
      return false;
    }
    return true;
  }

  // ── Validation ────────────────────────────────────────────────
  String? _validate() {
    if (_profileBytes == null)
      return 'Profile photo zaroor chahiye!';
    if (_empIdCtrl.text.trim().isEmpty)
      return 'Employee ID daalen!';
    if (_fNameCtrl.text.trim().isEmpty || _lNameCtrl.text.trim().isEmpty)
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
    if (_qualCtrl.text.trim().isEmpty)
      return 'Qualification daalen!';
    if (_joiningDate.contains('Select'))
      return 'Joining date select karein!';
    if ([_gender, _designation, _dept].any((v) => v.startsWith('Select')))
      return 'Saare dropdown options select karein!';
    return null;
  }

  // ── Main signup ───────────────────────────────────────────────
  Future<void> _handleSignup() async {
    final err = _validate();
    if (err != null) { _showToast(err); return; }

    setState(() => _isLoading = true);
    try {
      final isUnique = await _runUniqueChecks();
      if (!isUnique) { setState(() => _isLoading = false); return; }

      final token      = await FirebaseMessaging.instance.getToken();
      final profileUrl = await _uploadToCloudinary(_profileBytes!);
      final user       = _auth.currentUser;

      await _db.collection('Users').doc(user?.uid).set({
        'employeeId'  : _empIdCtrl.text.trim(),
        'name'        : '${_fNameCtrl.text.trim()} ${_lNameCtrl.text.trim()}',
        'fatherName'  : _fatherCtrl.text.trim(),
        'contactNo'   : _contactCtrl.text.trim(),
        'cnic'        : _cnicCtrl.text.trim(),
        'email'       : _emailCtrl.text.trim().toLowerCase(),
        'gender'      : _gender,
        'designation' : _designation,
        'dept'        : _dept,
        'qualification': _qualCtrl.text.trim(),
        'experience'  : _expCtrl.text.trim(),
        'grade'       : _gradeCtrl.text.trim(),
        'majorSubject': _majorSubjectCtrl.text.trim(),
        'joiningDate' : _joiningDate,
        'profilePic'  : profileUrl,
        'fcmToken'    : token ?? 'no_token',
        'role'        : 'Teacher',
        'createdAt'   : FieldValue.serverTimestamp(),
      });

      _showToast('Faculty profile save ho gaya! 🎉');
      if (mounted) Navigator.pushReplacementNamed(context, '/faculty_dashboard');
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

                      // ── Profile photo ──────────────────────────
                      _buildProfilePhoto(),
                      const SizedBox(height: 20),

                      // ── Personal Info ──────────────────────────
                      _sectionHeader('Personal Information'),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(children: [
                          _labeledField('Employee ID', _empIdCtrl,
                              hint: 'Enter employee ID'),
                          Row(children: [
                            Expanded(child: _labeledField('First Name', _fNameCtrl,
                                hint: 'First name')),
                            const SizedBox(width: 12),
                            Expanded(child: _labeledField('Last Name', _lNameCtrl,
                                hint: 'Last name')),
                          ]),
                          _labeledField("Father's Name", _fatherCtrl,
                              hint: "Enter father's name"),
                          _labeledField('Phone Number', _contactCtrl,
                              hint: '03XXXXXXXXX', isPhone: true),
                          _labeledField('CNIC', _cnicCtrl,
                              hint: 'XXXXX-XXXXXXX-X', formatter: _cnicFormatter),
                          _labeledField('Email Address', _emailCtrl,
                              hint: 'example@email.com', isEmail: true),
                        ]),
                      ),

                      const SizedBox(height: 8),

                      // ── Professional Info ──────────────────────
                      _sectionHeader('Professional Information'),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(children: [
                          _labeledField('Qualification', _qualCtrl,
                              hint: 'e.g. MS Computer Science'),
                          Row(children: [
                            Expanded(child: _labeledField('Experience', _expCtrl,
                                hint: 'Years', isNum: true)),
                            const SizedBox(width: 12),
                            Expanded(child: _labeledField('Grade', _gradeCtrl,
                                hint: 'e.g. BPS-17')),
                          ]),
                          _labeledField('Major Subject', _majorSubjectCtrl,
                              hint: 'e.g. Data Structures'),
                          _labeledDrop('Gender',
                            ['Select Gender', 'Male', 'Female', 'Other'],
                            _gender, (v) => setState(() => _gender = v!)),
                          _labeledDrop('Designation',
                            ['Select Designation', 'Lecturer',
                             'Assistant Professor', 'Associate Professor',
                             'Professor'],
                            _designation,
                            (v) => setState(() => _designation = v!)),
                          _labeledDrop('Department',
                            ['Select Department', 'Computer Science', 'Zoology',
                             'Information Technology', 'English', 'Physics',
                             'Mathematics', 'Pol-Science', 'Urdu'],
                            _dept, (v) => setState(() => _dept = v!)),

                          // ── Joining Date ───────────────────────
                          _joiningDatePicker(),
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
                            child: const Text('Complete Registration',
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

  // ── Header ────────────────────────────────────────────────────
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
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.school_rounded, color: kPrimary, size: 40),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Faculty Signup',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold,
              color: kPrimary)),
        const SizedBox(height: 6),
        Text('Complete your registration process',
          style: TextStyle(fontSize: 14, color: Colors.grey[600])),
      ]),
    );
  }

  // ── Profile photo picker ──────────────────────────────────────
  Widget _buildProfilePhoto() {
    return Column(children: [
      GestureDetector(
        onTap: () async {
          final x = await ImagePicker()
              .pickImage(source: ImageSource.gallery, imageQuality: 85);
          if (x != null) {
            final b = await x.readAsBytes();
            setState(() => _profileBytes = b);
          }
        },
        child: Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(
              color: _profileBytes != null
                  ? kPrimary
                  : kPrimary.withOpacity(0.4),
              width: 2.5,
            ),
            boxShadow: [BoxShadow(
              color: kPrimary.withOpacity(0.1),
              blurRadius: 10, offset: const Offset(0, 3),
            )],
            image: _profileBytes != null
                ? DecorationImage(
                    image: MemoryImage(_profileBytes!), fit: BoxFit.cover)
                : null,
          ),
          child: _profileBytes == null
              ? const Icon(Icons.person_add_rounded,
                  color: kPrimary, size: 36)
              : null,
        ),
      ),
      const SizedBox(height: 10),
      Text(
        _profileBytes == null ? 'Tap to add profile photo' : 'Tap to change photo',
        style: TextStyle(
          fontSize: 13, color: Colors.grey[600],
          fontWeight: FontWeight.w500,
        ),
      ),
    ]);
  }

  // ── Joining date picker ───────────────────────────────────────
  Widget _joiningDatePicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Joining Date',
          style: TextStyle(fontWeight: FontWeight.bold,
              color: kPrimary, fontSize: 13)),
        const SizedBox(height: 6),
        InkWell(
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: DateTime.now(),
              firstDate: DateTime(1980),
              lastDate: DateTime(2100),
              builder: (ctx, child) => Theme(
                data: Theme.of(ctx).copyWith(
                  colorScheme: const ColorScheme.light(primary: kPrimary),
                ),
                child: child!,
              ),
            );
            if (d != null) {
              setState(() =>
                  _joiningDate = DateFormat('dd-MM-yyyy').format(d));
            }
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFA),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _joiningDate.contains('Select')
                    ? kPrimary.withOpacity(0.4)
                    : kPrimary,
                width: 1.5,
              ),
            ),
            child: Row(children: [
              const Icon(Icons.calendar_today_rounded,
                  color: kPrimary, size: 18),
              const SizedBox(width: 10),
              Text(
                _joiningDate,
                style: TextStyle(
                  fontSize: 14,
                  color: _joiningDate.contains('Select')
                      ? Colors.grey[400]
                      : Colors.black87,
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  // ── Section header ────────────────────────────────────────────
  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(title,
          style: const TextStyle(fontSize: 17,
              fontWeight: FontWeight.bold, color: Colors.black87)),
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
    bool isNum   = false,
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
                  : isNum
                      ? TextInputType.number
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