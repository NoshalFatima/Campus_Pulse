import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // ✅ Added for Notifications
import 'package:image_picker/image_picker.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'package:intl/intl.dart';

class FacultySignupActivity extends StatefulWidget {
  const FacultySignupActivity({super.key});

  @override
  State<FacultySignupActivity> createState() => _FacultySignupActivityState();
}

class _FacultySignupActivityState extends State<FacultySignupActivity> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  bool _isLoading = false;

  // ── Controllers (Exact as your Java Code) ──
  final TextEditingController _empIdController = TextEditingController();
  final TextEditingController _fNameController = TextEditingController();
  final TextEditingController _lNameController = TextEditingController();
  final TextEditingController _fatherNameController = TextEditingController();
  final TextEditingController _contactController = TextEditingController();
  final TextEditingController _cnicController = TextEditingController();
  final TextEditingController _qualificationController = TextEditingController();
  final TextEditingController _experienceController = TextEditingController();
  final TextEditingController _gradeController = TextEditingController();
  final TextEditingController _majorSubjectController = TextEditingController();

  // ── Formatters (Pakistani CNIC) ──
  var cnicFormatter = MaskTextInputFormatter(mask: '#####-#######-#', filter: {"#": RegExp(r'[0-9]')});

  Uint8List? _profileImageBytes;
  String _selectedJoiningDate = "Select Joining Date";

  // ── Dropdowns (Exact values from your Java setupSpinners) ──
  String selGender = 'Select Gender';
  String selDesignation = 'Select Designation';
  String selDept = 'Select Department';

  // Cloudinary Upload Logic
  Future<String?> _uploadToCloudinary(Uint8List bytes) async {
    String cloudName = "drp97v6nd";
    String uploadPreset = "unsigned_preset";

    var uri = Uri.parse("https://api.cloudinary.com/v1_1/$cloudName/image/upload");
    var request = http.MultipartRequest("POST", uri);
    request.fields['upload_preset'] = uploadPreset;
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'teacher_profile.jpg'));

    var response = await request.send();
    if (response.statusCode == 200) {
      var data = await response.stream.toBytes();
      return jsonDecode(String.fromCharCodes(data))['secure_url'];
    }
    return null;
  }

  // 🚀 MAIN SIGNUP LOGIC (As per Java Validation)
  Future<void> _handleSignup() async {
    String phone = _contactController.text.trim();
    String cnic = _cnicController.text.trim();

    // 1. Compulsory Checks
    if (_profileImageBytes == null || _empIdController.text.isEmpty || _selectedJoiningDate.contains("Select")) {
      _showToast("❌ All fields, Joining Date, and Image are required!"); return;
    }

    // 2. Pakistani Phone Validation (03XXXXXXXXX)
    if (!RegExp(r'^03[0-9]{9}$').hasMatch(phone)) {
      _showToast("❌ Valid Pakistani number required (03XXXXXXXXX)"); return;
    }

    // 3. Pakistani CNIC Validation (XXXXX-XXXXXXX-X)
    if (!RegExp(r'^[0-9]{5}-[0-9]{7}-[0-9]$').hasMatch(cnic)) {
      _showToast("❌ Valid CNIC required (XXXXX-XXXXXXX-X)"); return;
    }

    // 4. Spinner checks
    if (selGender == 'Select Gender' || selDesignation == 'Select Designation' || selDept == 'Select Department') {
      _showToast("❌ Please select all dropdown options!"); return;
    }

    setState(() => _isLoading = true);

    try {
      // ✅ Get FCM Token for Notifications
      String? token = await FirebaseMessaging.instance.getToken();

      // 5. Duplicate Employee ID Check
      var idCheck = await _db.collection("Users").where("employeeId", isEqualTo: _empIdController.text.trim()).get();
      if (idCheck.docs.isNotEmpty) {
        _showToast("❌ Employee ID already registered!");
        setState(() => _isLoading = false); return;
      }

      // 6. Duplicate CNIC Check
      var cnicCheck = await _db.collection("Users").where("cnic", isEqualTo: cnic).get();
      if (cnicCheck.docs.isNotEmpty) {
        _showToast("❌ CNIC already exists!");
        setState(() => _isLoading = false); return;
      }

      // 7. Upload to Cloudinary
      String? profileUrl = await _uploadToCloudinary(_profileImageBytes!);

      // 8. Save to Firestore (Exact Fields from Java ProfileMap)
      User? user = _auth.currentUser;
      await _db.collection("Users").doc(user?.uid).set({
        "employeeId": _empIdController.text.trim(),
        "name": "${_fNameController.text.trim()} ${_lNameController.text.trim()}",
        "fatherName": _fatherNameController.text.trim(),
        "contactNumber": phone, // As per Java Map key
        "cnic": cnic,
        "gender": selGender,
        "designation": selDesignation,
        "dept": selDept,
        "qualification": _qualificationController.text.trim(),
        "experience": _experienceController.text.trim(),
        "grade": _gradeController.text.trim(),
        "majorSubject": _majorSubjectController.text.trim(),
        "joiningDate": _selectedJoiningDate,
        "profilePic": profileUrl,
        "fcmToken": token, // ✅ New field for Notifications
        "role": "Teacher",
        "createdAt": FieldValue.serverTimestamp(),
      });

      _showToast("✅ Faculty profile saved!");
      Navigator.pushReplacementNamed(context, '/faculty_dashboard');

    } catch (e) {
      _showToast("❌ Error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showToast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF2F3),
      appBar: AppBar(title: const Text("Faculty Signup"), backgroundColor: const Color(0xFF7B0000), foregroundColor: Colors.white),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF7B0000)))
          : SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Center(
              child: Column(
                children: [
                  GestureDetector(
                    onTap: () async {
                      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
                      if (x != null) {
                        var b = await x.readAsBytes();
                        setState(() => _profileImageBytes = b);
                      }
                    },
                    child: CircleAvatar(
                      radius: 60, backgroundColor: const Color(0xFF7B0000),
                      child: CircleAvatar(
                        radius: 57, backgroundColor: Colors.white,
                        backgroundImage: _profileImageBytes != null ? MemoryImage(_profileImageBytes!) : null,
                        child: _profileImageBytes == null ? const Icon(Icons.person_add, size: 40, color: Color(0xFF7B0000)) : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text("Select Profile Image", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF7B0000))),
                ],
              ),
            ),
            const SizedBox(height: 25),

            _input(_empIdController, "Employee ID", Icons.badge),
            Row(children: [
              Expanded(child: _input(_fNameController, "First Name", Icons.person)),
              const SizedBox(width: 10),
              Expanded(child: _input(_lNameController, "Last Name", Icons.person)),
            ]),
            _input(_fatherNameController, "Father's Name", Icons.family_restroom),

            Row(children: [
              Expanded(child: _input(_qualificationController, "Qualification", Icons.school)),
              const SizedBox(width: 10),
              Expanded(child: _input(_experienceController, "Experience", Icons.work, isNum: true)),
            ]),

            Row(children: [
              Expanded(child: _input(_gradeController, "Grade", Icons.grade)),
              const SizedBox(width: 10),
              Expanded(child: _input(_majorSubjectController, "Major Subject", Icons.book)),
            ]),

            Row(children: [
              Expanded(child: _dropdown("Gender", ["Select Gender", "Male", "Female", "Other"], selGender, (v) => setState(() => selGender = v!))),
              const SizedBox(width: 10),
              Expanded(child: _dropdown("Designation", ["Select Designation", "Lecturer", "Assistant Professor", "Associate Professor", "Professor"], selDesignation, (v) => setState(() => selDesignation = v!))),
            ]),

            _dropdown("Department", ["Select Department", "Computer Science", "Zoology", "Information Technology", "English", "Physics", "Mathematics", "Pol-Science", "Urdu"], selDept, (v) => setState(() => selDept = v!)),

            _input(_contactController, "03XXXXXXXXX", Icons.phone, isNum: true),
            _input(_cnicController, "XXXXX-XXXXXXX-X", Icons.contact_page, formatter: cnicFormatter),

            const SizedBox(height: 10),
            _dateBtn(),

            const SizedBox(height: 30),

            SizedBox(
              width: double.infinity, height: 55,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7B0000)),
                onPressed: _handleSignup,
                child: const Text("COMPLETE REGISTRATION", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  // --- Widgets Helpers ---
  Widget _input(TextEditingController c, String h, IconData icon, {bool isNum = false, dynamic formatter}) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: TextField(
      controller: c, inputFormatters: formatter != null ? [formatter] : [],
      keyboardType: isNum ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: const Color(0xFF7B0000)),
        hintText: h, filled: true, fillColor: Colors.white,
        focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFF7B0000))),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  );

  Widget _dropdown(String label, List<String> items, String current, Function(String?) onChanged) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF7B0000))),
      Container(
        margin: const EdgeInsets.only(top: 5, bottom: 15),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String>(
          value: current, isExpanded: true,
          items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
          onChanged: onChanged,
        )),
      ),
    ],
  );

  Widget _dateBtn() => InkWell(
    onTap: () async {
      DateTime? d = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(1980), lastDate: DateTime(2100));
      if (d != null) {
        setState(() => _selectedJoiningDate = DateFormat('dd-MM-yyyy').format(d));
      }
    },
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF7B0000))),
      child: Row(children: [
        const Icon(Icons.calendar_today, color: Color(0xFF7B0000)),
        const SizedBox(width: 10),
        Text(_selectedJoiningDate, style: const TextStyle(color: Color(0xFF7B0000))),
      ]),
    ),
  );
}