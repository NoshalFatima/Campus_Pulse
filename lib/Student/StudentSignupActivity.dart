import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb; // ✅ Platform check ke liye
import 'dart:io' show Platform; // ✅ Platform check ke liye

// ✅ Conditional Import: Taake Web/Windows par crash na ho
// ✅ Nayi library "tflite_flutter_plus" ke mutabiq update


import 'package:image/image.dart' as img;
import 'dart:convert';

import 'package:tflite_flutter/tflite_flutter.dart' as tfl;


class StudentSignupActivity extends StatefulWidget {
  const StudentSignupActivity({super.key});

  @override
  State<StudentSignupActivity> createState() => _StudentSignupActivityState();
}

class _StudentSignupActivityState extends State<StudentSignupActivity> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  tfl.Interpreter? _interpreter;
  bool _isLoading = false;

  // ── Controllers ──
  final TextEditingController _regNoController = TextEditingController();
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final TextEditingController _fatherNameController = TextEditingController();
  final TextEditingController _contactController = TextEditingController();
  final TextEditingController _cnicController = TextEditingController();

  var cnicFormatter = MaskTextInputFormatter(
      mask: '#####-#######-#', filter: {"#": RegExp(r'[0-9]')});

  // ── Data State ──
  Uint8List? _profileImageBytes;
  Uint8List? _faceImageBytes;
  List<double>? _faceEmbedding;
  final ImagePicker _picker = ImagePicker();

  String selectedGender = 'Select Gender';
  String selectedBatch = 'Select Batch';
  String selectedDept = 'Select Department';
  String selectedShift = 'Select Shift';
  String selectedSemester = 'Select Semester';

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  // ✅ Updated: Ab ye sirf Mobile par model load karega
  Future<void> _loadModel() async {
    if (kIsWeb) return; // Web par skip karein
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        _interpreter = await tfl.Interpreter.fromAsset('assets/mobilefacenet.tflite');
        debugPrint("Model Loaded Successfully on Mobile");
      }
    } catch (e) {
      debugPrint("Model Load Error: $e");
    }
  }

  // ✅ Updated: Web/Windows par error nahi dega
  Future<void> _extractFaceFeatures(Uint8List bytes) async {
    if (_interpreter == null) {
      debugPrint("Interpreter not available on this platform");
      // Dummy data for Web/Windows taake signup na ruke
      setState(() {
        _faceEmbedding = List.filled(192, 0.0);
      });
      return;
    }

    try {
      img.Image? ori = img.decodeImage(bytes);
      img.Image resized = img.copyResize(ori!, width: 112, height: 112);

      var input = List.generate(1, (i) => List.generate(112, (y) => List.generate(112, (x) => List.generate(3, (c) {
        var pixel = resized.getPixel(x, y);
        if (c == 0) return (pixel.r - 127.5) / 127.5;
        if (c == 1) return (pixel.g - 127.5) / 127.5;
        return (pixel.b - 127.5) / 127.5;
      }))));

      var output = List.generate(1, (_) => List.filled(192, 0.0));
      _interpreter!.run(input, output);

      setState(() {
        _faceEmbedding = List<double>.from(output[0]);
      });
    } catch (e) {
      debugPrint("Feature Extraction Error: $e");
    }
  }

  Future<String?> _uploadToCloudinary(Uint8List bytes) async {
    String cloudName = "drp97v6nd";
    String uploadPreset = "unsigned_preset";

    var uri = Uri.parse("https://api.cloudinary.com/v1_1/$cloudName/image/upload");
    var request = http.MultipartRequest("POST", uri);
    request.fields['upload_preset'] = uploadPreset;
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'upload.jpg'));

    var response = await request.send();
    if (response.statusCode == 200) {
      var data = await response.stream.toBytes();
      return jsonDecode(String.fromCharCodes(data))['secure_url'];
    }
    return null;
  }

  Future<void> _handleSignup() async {
    if (_profileImageBytes == null || _faceImageBytes == null) {
      _showToast("Both Photos are required!"); return;
    }

    // Web/Windows par agar embedding null hai toh dummy bhej dein
    if (_faceEmbedding == null && (kIsWeb || !Platform.isAndroid)) {
      _faceEmbedding = List.filled(192, 0.0);
    }

    String phone = _contactController.text.trim();
    String cnic = _cnicController.text.trim();

    if (!RegExp(r'^03[0-9]{9}$').hasMatch(phone)) {
      _showToast("Enter valid Pakistani number (03XXXXXXXXX)"); return;
    }

    if (selectedGender == 'Select Gender' || selectedBatch == 'Select Batch' ||
        selectedDept == 'Select Department' || selectedShift == 'Select Shift' ||
        selectedSemester == 'Select Semester') {
      _showToast("Please select all dropdown options!"); return;
    }

    setState(() => _isLoading = true);

    try {
      String? token = "no_token";
      if (!kIsWeb) {
        token = await FirebaseMessaging.instance.getToken();
      }

      var regCheck = await _db.collection("Users").where("regNo", isEqualTo: _regNoController.text.trim()).get();
      if (regCheck.docs.isNotEmpty) {
        _showToast("Registration No already exists!");
        setState(() => _isLoading = false); return;
      }

      String? profileUrl = await _uploadToCloudinary(_profileImageBytes!);
      String? faceUrl = await _uploadToCloudinary(_faceImageBytes!);

      User? user = _auth.currentUser;
      await _db.collection("Users").doc(user?.uid).set({
        "regNo": _regNoController.text.trim(),
        "name": "${_firstNameController.text.trim()} ${_lastNameController.text.trim()}",
        "fatherName": _fatherNameController.text.trim(),
        "contactNo": phone,
        "cnic": cnic,
        "gender": selectedGender,
        "batch": selectedBatch,
        "dept": selectedDept,
        "shift": selectedShift,
        "semester": selectedSemester,
        "faceData": _faceEmbedding?.join(',') ?? "",
        "profilePic": profileUrl,
        "faceImageUrl": faceUrl,
        "fcmToken": token,
        "role": "student",
        "createdAt": FieldValue.serverTimestamp(),
      });

      _showToast("Signup Successful!");
      Navigator.pushReplacementNamed(context, '/student_dashboard');
    } catch (e) {
      _showToast("Error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showToast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDF2F3),
      appBar: AppBar(title: const Text("Student Signup"), backgroundColor: const Color(0xFF8B0A1A), foregroundColor: Colors.white),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF8B0A1A)))
          : SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(children: [
              _pickBox("Profile Photo", _profileImageBytes, () async {
                final x = await _picker.pickImage(source: ImageSource.gallery);
                if (x != null) {
                  var b = await x.readAsBytes(); setState(() => _profileImageBytes = b);
                }
              }),
              _pickBox("Face Scan", _faceImageBytes, () async {
                final x = await _picker.pickImage(source: ImageSource.camera);
                if (x != null) {
                  var b = await x.readAsBytes();
                  setState(() => _faceImageBytes = b);
                  _extractFaceFeatures(b); // Ye ab safe hai
                }
              }),
            ]),
            const SizedBox(height: 20),
            _inp(_regNoController, "Registration Number"),
            Row(children: [
              Expanded(child: _inp(_firstNameController, "First Name")),
              const SizedBox(width: 10),
              Expanded(child: _inp(_lastNameController, "Last Name")),
            ]),
            _inp(_fatherNameController, "Father's Name"),
            _inp(_contactController, "03XXXXXXXXX (Phone)", isPhone: true),
            _inp(_cnicController, "XXXXX-XXXXXXX-X (CNIC)", formatter: cnicFormatter),

            _drop("Gender", ["Select Gender", "Male", "Female", "Other"], selectedGender, (v) => setState(() => selectedGender = v!)),
            _drop("Batch", ["Select Batch", "2021", "2022", "2023", "2024", "2025"], selectedBatch, (v) => setState(() => selectedBatch = v!)),
            _drop("Department", ["Select Department", "Computer Science", "Zoology", "Mathematics", "English", "Urdu", "Physics", "Pol Science"], selectedDept, (v) => setState(() => selectedDept = v!)),
            _drop("Shift", ["Select Shift", "Morning", "Evening"], selectedShift, (v) => setState(() => selectedShift = v!)),
            _drop("Semester", ["Select Semester", "1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th"], selectedSemester, (v) => setState(() => selectedSemester = v!)),

            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity, height: 55,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B0A1A)),
                onPressed: _handleSignup,
                child: const Text("Complete Signup", style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            )
          ],
        ),
      ),
    );
  }

  // --- UI Helpers ---
  Widget _pickBox(String label, Uint8List? bytes, VoidCallback onTap) => Expanded(
    child: Column(children: [
      CircleAvatar(radius: 45, backgroundColor: Colors.white, backgroundImage: bytes != null ? MemoryImage(bytes) : null, child: bytes == null ? const Icon(Icons.camera_alt, color: Color(0xFF8B0A1A)) : null),
      TextButton(onPressed: onTap, child: Text(label, style: const TextStyle(color: Color(0xFF8B0A1A))))
    ]),
  );

  Widget _inp(TextEditingController c, String h, {bool isPhone = false, dynamic formatter}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c, inputFormatters: formatter != null ? [formatter] : [],
      keyboardType: isPhone ? TextInputType.phone : TextInputType.text,
      decoration: InputDecoration(hintText: h, filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
    ),
  );

  Widget _drop(String l, List<String> i, String v, Function(String?) onChanged) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(l, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: v, isExpanded: true, items: i.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(), onChanged: onChanged)),
      ),
      const SizedBox(height: 12),
    ],
  );
}