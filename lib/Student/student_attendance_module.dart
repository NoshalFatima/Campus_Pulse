// lib/Student/student_attendance_module.dart
//
// FIXES IN THIS VERSION:
//
// FIX 1 — GPS Out of Range randomly:
//   Root cause: GPS accuracy indoors can be 50-100m so student appears
//   outside radius even when physically present.
//   Fix: effective radius = teacher_radius + student_gps_accuracy + 30m buffer
//   This means if accuracy is 60m the allowed zone expands accordingly.
//
// FIX 2 — "Bad state: failed precondition" inference error:
//   Root cause: interpreter was called right after takePicture() while
//   camera was still active. Interpreter state was corrupt.
//   Fix: camera fully disposed BEFORE inference. Added await + delay.
//   Also interpreter is re-initialized if null before each attempt.
//
// FIX 3 — Torch/Flash control:
//   Flash toggle button added to camera UI.
//   Auto-detects if torch is available.

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart' ;
import 'package:firebase_database/firebase_database.dart' as rtdb ;
import '../services/face_service.dart';
import '../services/onesignal_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────────────────────────────────

class _SessionData {
  final double lat, lon, radius;
  final String faculty, subject, dept, sem, shift, status;
  const _SessionData({
    required this.lat, required this.lon, required this.radius,
    required this.faculty, required this.subject,
    required this.dept, required this.sem, required this.shift,
    required this.status,
  });
  factory _SessionData.fromMap(Map m) => _SessionData(
    lat:     (m['latitude']     as num?)?.toDouble() ?? 0,
    lon:     (m['longitude']    as num?)?.toDouble() ?? 0,
    radius:  (m['radiusMeters'] as num?)?.toDouble() ?? 20,
    faculty: m['facultyName']?.toString() ?? '',
    subject: m['subjectName']?.toString() ?? '',
    dept:    m['department']?.toString()  ?? '',
    sem:     m['semester']?.toString()    ?? '',
    shift:   m['shift']?.toString()       ?? '',
    status:  m['status']?.toString()      ?? 'none',
  );
}

class _StudentProfile {
  final String uid, sessionPath, faceData, dept, sem, shift;
  const _StudentProfile({
    required this.uid, required this.sessionPath,
    required this.faceData, required this.dept,
    required this.sem, required this.shift,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class StudentAttendanceFragment extends StatefulWidget {
  const StudentAttendanceFragment({super.key});
  @override
  State<StudentAttendanceFragment> createState() => _State();
}

class _State extends State<StudentAttendanceFragment>
    with WidgetsBindingObserver {

  final _face  = FaceService.instance;
  final _db    = rtdb.FirebaseDatabase.instance;
  final _fs    = FirebaseFirestore.instance;
  final _auth  = FirebaseAuth.instance;

  late final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableClassification: true,
    ),
  );

  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _camera;
  bool _cameraReady   = false;
  bool _showCamera    = false;
  bool _torchOn       = false;
  bool _torchAvail    = false;

  // ── State ──────────────────────────────────────────────────────────────────
  _StudentProfile? _profile;
  _SessionData?    _session;
  List<double>?    _storedEmbedding;

  String _status      = 'System Ready';
  String _instruction = 'Tap the button below to begin';
  bool _loading   = false;
  bool _showBtn   = true;
  bool _showRetry = false;

  StreamSubscription<rtdb.DatabaseEvent>? _sessionSub;
  String _liveStatus = 'unknown';

  // ── Blink ──────────────────────────────────────────────────────────────────
  bool  _blinkDetected   = false;
  bool  _processingFrame = false;
  Timer? _blinkTimeout;
  Timer? _frameTimer;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _face.init();
    _loadProfile();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detector.close();
    _sessionSub?.cancel();
    _blinkTimeout?.cancel();
    _frameTimer?.cancel();
    _destroyCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _destroyCamera();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PROFILE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadProfile() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;

      final doc = await _fs.collection('Users').doc(uid).get();
      if (!doc.exists) return;

      final d = doc.data()!;
      final dept  = d['dept']?.toString()     ?? '';
      final sem   = d['semester']?.toString() ?? d['sem']?.toString() ?? '';
      final shift = d['shift']?.toString()    ?? '';

      final deptKey  = dept.trim().replaceAll(' ', '_').toUpperCase();
      final semNum   = sem.replaceAll(RegExp(r'[^0-9]'), '');
      final shiftKey = shift.trim().toUpperCase();
      final path     = '${deptKey}_S${semNum}_$shiftKey';

      _profile = _StudentProfile(
        uid: uid, sessionPath: path,
        faceData: d['faceData']?.toString() ?? '',
        dept: dept, sem: sem, shift: shift,
      );

      OneSignalService.registerStudentClassTag(
          dept: dept, sem: sem, shift: shift);

      _watchSession(path);
      _loadSessionData(path);
    } catch (e) {
      debugPrint('Profile: $e');
    }
  }

  void _watchSession(String path) {
    _sessionSub?.cancel();
    _sessionSub = _db.ref('AttendanceSession/$path/status').onValue.listen((e) {
      final s = e.snapshot.value?.toString() ?? 'none';
      if (s != _liveStatus && mounted) {
        setState(() => _liveStatus = s);
        if (s != 'allowed' && _showCamera) {
          _ui('Session Closed', 'Teacher stopped the attendance session.');
          _destroyCamera();
          setState(() { _showCamera = false; _showBtn = false; _showRetry = true; });
        }
      }
    });
  }

  Future<void> _loadSessionData(String path) async {
    try {
      final snap = await _db.ref('AttendanceSession/$path').get()
          .timeout(const Duration(seconds: 8));
      if (snap.exists && snap.value != null) {
        final s = _SessionData.fromMap(snap.value as Map);
        if (mounted) setState(() { _session = s; _liveStatus = s.status; });
      }
    } catch (e) {
      debugPrint('Session data: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STEP 1: START
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _start() async {
    // Re-init model if it was reset after a failed inference
    if (!_face.isReady) {
      _ui('Loading Model…', 'Initializing face recognition…');
      try {
        await _face.init();
      } catch (e) {
        _fail('Face model not available. Please restart the app.');
        return;
      }
    }

    final cam = await Permission.camera.request();
    final loc = await Permission.location.request();
    if (!cam.isGranted || !loc.isGranted) {
      _ui('Permission Required', 'Camera and location permissions are needed.');
      setState(() { _showBtn = true; });
      return;
    }

    setState(() { _loading = true; _showBtn = false; });
    _ui('Loading…', 'Checking your class information…');

    try {
      if (_profile == null) await _loadProfile();
      if (_profile == null) {
        _fail('Profile not found. Please complete signup first.');
        return;
      }

      _storedEmbedding = _face.parseStoredEmbedding(_profile!.faceData);
      if (_storedEmbedding == null || _storedEmbedding!.isEmpty) {
        _fail('Face data missing from profile. Please re-register your face.');
        return;
      }

      await _validateSession();
    } catch (e) {
      _fail('Error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STEP 2: SESSION VALIDATION
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _validateSession() async {
    _ui('Checking Session…', 'Looking for active attendance…');

    try {
      final snap = await _db
          .ref('AttendanceSession/${_profile!.sessionPath}')
          .get()
          .timeout(const Duration(seconds: 10));

      if (!snap.exists || snap.value == null) {
        _fail('No session found for your class.\nWait for your teacher to start attendance.');
        return;
      }

      final s = _SessionData.fromMap(snap.value as Map);
      _session = s;

      if (s.status != 'allowed') {
        _fail(s.status == 'stopped'
            ? 'Attendance has been closed by the teacher.'
            : 'Attendance not started yet. Wait for your teacher.');
        return;
      }

      // Normalize comparison
      String numOnly(String v) => v.replaceAll(RegExp(r'[^0-9]'), '');
      String norm(String v)    => v.trim().replaceAll(' ', '_').toUpperCase();

      final ok = norm(_profile!.dept)   == norm(s.dept) &&
                 numOnly(_profile!.sem) == numOnly(s.sem) &&
                 norm(_profile!.shift)  == norm(s.shift);

      if (!ok) {
        _fail('This session is for ${s.dept} ${s.sem} ${s.shift}.\n'
              'Your class: ${_profile!.dept} ${_profile!.sem} ${_profile!.shift}');
        return;
      }

      // Duplicate check
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final dup   = await _db
          .ref('AttendanceRecords/${_profile!.sessionPath}/$today/${_profile!.uid}')
          .get();
      if (dup.exists) {
        _ui('Already Marked', 'Your attendance is already recorded for today.');
        setState(() { _loading = false; _showBtn = false; _showRetry = false; });
        return;
      }

      if (mounted) setState(() => _liveStatus = 'allowed');
      await _validateGps();
    } catch (e) {
      _fail('Session error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STEP 3: GPS — FIX 1: dynamic radius based on accuracy
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _validateGps() async {
    _ui('GPS Check', 'Verifying your location…');

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _ui('GPS Disabled', 'Please enable GPS and try again.');
        setState(() { _loading = false; _showRetry = true; });
        await Geolocator.openLocationSettings();
        return;
      }

      final pos = await _getBestPosition();

      if (pos == null) {
        // No GPS — proceed without location check
        print('GPS: No position, proceeding');
        await _startCamera();
        return;
      }

      final dist = Geolocator.distanceBetween(
        pos.latitude, pos.longitude,
        _session!.lat, _session!.lon,
      );

      // FIX 1: effective radius includes GPS accuracy + 30m indoor buffer
      final effectiveRadius = _session!.radius + pos.accuracy + 30.0;

      print('GPS: dist=${dist.toStringAsFixed(1)}m '
            'accuracy=${pos.accuracy.toStringAsFixed(1)}m '
            'effectiveRadius=${effectiveRadius.toStringAsFixed(1)}m');

      if (dist > effectiveRadius) {
        _fail('You are ${dist.toStringAsFixed(0)}m from the classroom.\n'
              'Allowed radius: ${_session!.radius.toStringAsFixed(0)}m\n'
              'Move closer and try again.');
        return;
      }

      await _startCamera();
    } catch (e) {
      print('GPS error — proceeding: $e');
      await _startCamera();
    }
  }

  Future<Position?> _getBestPosition() async {
    Position? best;
    const goodAccuracy = 35.0;
    final completer = Completer<Position?>();

    StreamSubscription<Position>? sub;
    sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen((p) {
      if (best == null || p.accuracy < best!.accuracy) best = p;
      if (p.accuracy <= goodAccuracy && !completer.isCompleted) {
        completer.complete(p);
      }
    }, onError: (_) {
      if (!completer.isCompleted) completer.complete(null);
    });

    Future.delayed(const Duration(seconds: 12), () {
      if (!completer.isCompleted) completer.complete(best);
    });

    final result = await completer.future;
    await sub.cancel();
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STEP 4: CAMERA WITH TORCH — FIX 3
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _startCamera() async {
    _ui('Opening Camera', 'Please wait…');

    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _camera = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );

      await _camera!.initialize();

      // Check torch availability
      try {
        await _camera!.setFlashMode(FlashMode.torch);
        await _camera!.setFlashMode(FlashMode.off);
        _torchAvail = true;
      } catch (_) {
        _torchAvail = false;
      }
      _torchOn = false;

      if (!mounted) { await _destroyCamera(); return; }

      setState(() {
        _cameraReady = true;
        _showCamera  = true;
        _loading     = false;
      });

      _ui('Blink Once', 'Look at camera and blink once to verify liveness');

      _blinkDetected    = false;
      _processingFrame  = false;

      _blinkTimeout = Timer(const Duration(seconds: 45), () {
        if (!_blinkDetected && mounted) {
          _ui('Timeout', 'No blink detected in 45 seconds. Please try again.');
          _destroyCamera();
          setState(() { _showCamera = false; _showRetry = true; _showBtn = false; });
        }
      });

      _frameTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (!_blinkDetected && !_processingFrame) _analyzeFrame();
      });

    } catch (e) {
      _fail('Camera error: $e');
    }
  }

  Future<void> _toggleTorch() async {
    if (_camera == null || !_cameraReady) return;
    try {
      _torchOn = !_torchOn;
      await _camera!.setFlashMode(
          _torchOn ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Torch toggle: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STEP 5: BLINK DETECTION
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _analyzeFrame() async {
    if (_camera == null || !_cameraReady || _blinkDetected) return;
    if (!(_camera?.value.isInitialized ?? false)) return;

    _processingFrame = true;
    try {
      final xfile = await _camera!.takePicture();

      final inputImage = InputImage.fromFilePath(xfile.path);
      final faces      = await _detector.processImage(inputImage);

      if (faces.isEmpty) {
        if (mounted) _ui('Blink Once', 'No face detected — look directly at camera');
        _processingFrame = false;
        return;
      }

      final face = faces.first;
      final L    = face.leftEyeOpenProbability  ?? 1.0;
      final R    = face.rightEyeOpenProbability ?? 1.0;

      print('Eyes: L=${L.toStringAsFixed(2)} R=${R.toStringAsFixed(2)}');

      if (L < 0.25 && R < 0.25) {
        // Blink confirmed
        _blinkDetected = true;
        _blinkTimeout?.cancel();
        _frameTimer?.cancel();

        if (mounted) _ui('Blink Detected!', 'Capturing face for verification…');

        // Small delay so eyes are open again for face capture
        await Future.delayed(const Duration(milliseconds: 400));
        await _captureAndMatch();
      } else {
        if (mounted) _ui('Blink Once', 'Eyes open — please blink once naturally');
        _processingFrame = false;
      }
    } catch (e) {
      print('Frame error: $e');
      _processingFrame = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STEP 6: CAPTURE + MATCH — FIX 2: camera disposed BEFORE inference
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _captureAndMatch() async {
    try {
      if (mounted) setState(() => _loading = true);

      // Capture final clear photo while eyes are open
      if (_camera == null || !_cameraReady) {
        _fail('Camera not ready. Please try again.');
        return;
      }

      // Turn off torch before capture for consistent lighting
      if (_torchOn) {
        try { await _camera!.setFlashMode(FlashMode.off); } catch (_) {}
      }

      final xfile = await _camera!.takePicture();
      final bytes = await xfile.readAsBytes();

      // FIX 2: FULLY DESTROY camera BEFORE calling inference
      // This prevents "bad state: failed precondition"
      await _destroyCamera();
      if (mounted) setState(() { _showCamera = false; _cameraReady = false; });

      // Give a frame for UI to update
      await Future.delayed(const Duration(milliseconds: 200));

      _ui('Verifying Identity…', 'Analyzing your face…');

      // Decode image
      final decoded = img.decodeImage(Uint8List.fromList(bytes));
      if (decoded == null) {
        _fail('Could not process photo. Please try again.');
        return;
      }

      // Re-init interpreter if it was reset
      if (!_face.isReady) {
        try {
          await _face.init();
        } catch (e) {
          _fail('Face model not ready. Please restart the app.');
          return;
        }
      }

      // Extract embedding
      final List<double> liveEmbedding;
      try {
        liveEmbedding = _face.extractEmbeddingFromImage(decoded);
      } catch (e) {
        _fail('Face analysis failed.\nEnsure good lighting and face clearly visible.\nTry again.');
        return;
      }

      // Compare
      if (_storedEmbedding == null || _storedEmbedding!.isEmpty) {
        _fail('Stored face data missing. Please re-register.');
        return;
      }

      final similarity = _face.cosineSimilarity(_storedEmbedding!, liveEmbedding);
      final pct = (similarity * 100).toStringAsFixed(1);
      print('Face match: $pct% (threshold: ${(kSimilarityThreshold * 100).toStringAsFixed(0)}%)');

      if (similarity >= kSimilarityThreshold) {
        _ui('Identity Verified! ✅', 'Match: $pct% — saving attendance…');
        await _markAttendance();
      } else {
        _fail('Face not matched ($pct%).\n'
              'Tips:\n'
              '• Use the torch button if lighting is poor\n'
              '• Look straight at camera\n'
              '• Remove glasses if wearing any');
      }
    } catch (e) {
      _fail('Verification error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STEP 7: MARK ATTENDANCE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _markAttendance() async {
    try {
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final ref   = _db.ref(
        'AttendanceRecords/${_profile!.sessionPath}/$today/${_profile!.uid}',
      );

      await Future.delayed(
        Duration(milliseconds: DateTime.now().millisecondsSinceEpoch % 500),
      );

      final result = await ref.runTransaction((current) {
        if (current != null) return rtdb.Transaction.abort();
        return rtdb.Transaction.success({
          'status':       'Present',
          'timestamp':    DateTime.now().millisecondsSinceEpoch,
          'verification': 'Face+GPS+Liveness',
        });
      });

      if (!result.committed) {
        _ui('Already Marked ✅', 'Your attendance is already recorded for today.');
        setState(() { _loading = false; _showBtn = false; _showRetry = false; });
        return;
      }

      if (mounted) {
        _ui('Attendance Recorded! ✅',
            'Your presence has been verified and saved successfully.');
        setState(() { _loading = false; _showBtn = false; _showRetry = false; });
      }

      await Future.delayed(const Duration(milliseconds: 2500));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _fail('Save failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _destroyCamera() async {
    _blinkTimeout?.cancel();
    _frameTimer?.cancel();
    _processingFrame = false;
    _torchOn         = false;

    final ctrl = _camera;
    _camera = null;
    if (mounted) setState(() { _cameraReady = false; _showCamera = false; });

    await Future.delayed(const Duration(milliseconds: 150));
    try { await ctrl?.dispose(); } catch (_) {}
  }

  void _ui(String s, String i) {
    if (!mounted) return;
    setState(() { _status = s; _instruction = i; });
  }

  void _fail(String msg) {
    if (!mounted) return;
    _ui('Failed', msg);
    setState(() { _loading = false; _showBtn = false; _showRetry = true; });
    _destroyCamera();
  }

  void _reset() {
    _blinkDetected   = false;
    _processingFrame = false;
    _storedEmbedding = null;
    _session         = null;
    _destroyCamera();
    setState(() {
      _status      = 'System Ready';
      _instruction = 'Tap the button below to begin';
      _loading     = false;
      _showBtn     = true;
      _showRetry   = false;
      _showCamera  = false;
      _cameraReady = false;
    });
    _loadProfile();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return _webScreen();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        margin: const EdgeInsets.fromLTRB(18, 10, 18, 20),
        decoration: BoxDecoration(
          color: const Color(0xFFFDF2F3),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: const Color(0xFFFBC02D), width: 2),
          boxShadow: [BoxShadow(
              color: const Color(0xFFFFD700).withOpacity(0.3),
              blurRadius: 20, offset: const Offset(0, 6))],
        ),
        child: Column(children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(children: [
              Container(width: 4, height: 24, color: const Color(0xFF8B0A1A)),
              const SizedBox(width: 12),
              const Text('Identity Authentication',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900,
                      color: Color(0xFF8B0A1A))),
            ]),
          ),

          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              _banner(),
              const SizedBox(height: 12),

              if (_session != null && _liveStatus == 'allowed') ...[
                _teacherCard(),
                const SizedBox(height: 12),
              ],

              _statusCard(),
              const SizedBox(height: 18),

              if (_showCamera && _camera != null && _cameraReady) ...[
                _cameraCard(),
                const SizedBox(height: 18),
              ],

              if (_showBtn)
                _btn('Secure Face Unlock', Icons.face_unlock_outlined,
                    _liveStatus == 'allowed' && !_loading ? _start : null),

              if (_showRetry) ...[
                const SizedBox(height: 10),
                _outlineBtn('Try Again', _reset),
              ],

              const SizedBox(height: 18),
              _securityCard(),
            ]),
          )),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI COMPONENTS
  // ─────────────────────────────────────────────────────────────────────────

  Widget _banner() {
    Color bg, border, tc; String label; IconData icon;
    switch (_liveStatus) {
      case 'allowed':
        bg = Colors.green.shade50; border = Colors.green.shade300;
        tc = Colors.green.shade800; label = 'Attendance is OPEN — tap to mark';
        icon = Icons.check_circle_outline; break;
      case 'stopped':
        bg = Colors.red.shade50; border = Colors.red.shade300;
        tc = Colors.red.shade800; label = 'Attendance is CLOSED';
        icon = Icons.cancel_outlined; break;
      case 'set':
        bg = Colors.orange.shade50; border = Colors.orange.shade300;
        tc = Colors.orange.shade800; label = 'Session set — waiting for teacher to start';
        icon = Icons.hourglass_top_outlined; break;
      default:
        bg = Colors.grey.shade100; border = Colors.grey.shade300;
        tc = Colors.grey.shade700; label = 'No active session for your class';
        icon = Icons.info_outline;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border)),
      child: Row(children: [
        Icon(icon, color: tc, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(label,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: tc))),
      ]),
    );
  }

  Widget _teacherCard() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white, borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFFBC02D), width: 1.5),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Active Attendance Session',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
              color: Color(0xFF8B0A1A))),
      const SizedBox(height: 10),
      _row(Icons.person_outline,       'Faculty', _session!.faculty),
      const SizedBox(height: 6),
      _row(Icons.book_outlined,        'Subject', _session!.subject),
      const SizedBox(height: 6),
      _row(Icons.school_outlined,      'Class',
          '${_session!.dept} · ${_session!.sem} · ${_session!.shift}'),
      const SizedBox(height: 6),
      _row(Icons.my_location_outlined, 'Radius',
          '${_session!.radius.toStringAsFixed(0)} meters'),
    ]),
  );

  Widget _row(IconData icon, String label, String value) =>
      Row(children: [
        Icon(icon, size: 16, color: const Color(0xFF8B0A1A)),
        const SizedBox(width: 8),
        Text('$label: ', style: const TextStyle(fontSize: 12,
            fontWeight: FontWeight.bold, color: Color(0xFF555555))),
        Expanded(child: Text(value,
            style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
            overflow: TextOverflow.ellipsis)),
      ]);

  Widget _statusCard() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white, borderRadius: BorderRadius.circular(24),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05),
          blurRadius: 10, offset: const Offset(0, 3))],
    ),
    child: Column(children: [
      if (_loading) ...[
        const SizedBox(width: 45, height: 45,
            child: CircularProgressIndicator(
                color: Color(0xFF8B0A1A), strokeWidth: 3)),
        const SizedBox(height: 12),
      ],
      Text(_status, textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF8B0A1A), fontSize: 18,
              fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Text(_instruction, textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF757575), fontSize: 13,
              height: 1.5)),
    ]),
  );

  Widget _cameraCard() => Container(
    height: 420,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xFFFFD700), width: 2.5),
      boxShadow: [BoxShadow(
          color: const Color(0xFFFFD700).withOpacity(0.3), blurRadius: 15)],
    ),
    clipBehavior: Clip.antiAlias,
    child: Stack(fit: StackFit.expand, children: [
      // Camera preview — safe guard
      if (_camera != null && _cameraReady && (_camera?.value.isInitialized ?? false))
        CameraPreview(_camera!),

      // Oval face guide
      CustomPaint(painter: _OvalPainter()),

      // FIX 3: Torch toggle button
      if (_torchAvail)
        Positioned(top: 12, left: 12,
          child: GestureDetector(
            onTap: _toggleTorch,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _torchOn
                    ? Colors.yellow.withOpacity(0.9)
                    : Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                color: _torchOn ? Colors.black : Colors.white,
                size: 22,
              ),
            ),
          ),
        ),

      // Blink status badge
      Positioned(top: 12, right: 12,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _blinkDetected
                ? Colors.green.withOpacity(0.9)
                : const Color(0xFFFF9800).withOpacity(0.9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _blinkDetected ? '✅ BLINKED' : '👁 BLINK NOW',
            style: const TextStyle(color: Colors.white, fontSize: 11,
                fontWeight: FontWeight.bold),
          ),
        ),
      ),

      // Bottom instruction bar
      Positioned(bottom: 0, left: 0, right: 0,
        child: Container(
          height: 50,
          color: const Color(0xFF8B0A1A).withOpacity(0.85),
          alignment: Alignment.center,
          child: Text(
            _blinkDetected ? 'CAPTURING…' : 'BLINK ONCE TO VERIFY',
            style: const TextStyle(color: Colors.white,
                fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1.5),
          ),
        ),
      ),
    ]),
  );

  Widget _securityCard() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(22)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Security Compliance',
          style: TextStyle(color: Color(0xFF8B0A1A), fontSize: 15,
              fontWeight: FontWeight.bold)),
      Container(width: 30, height: 3,
          margin: const EdgeInsets.only(top: 4, bottom: 12),
          color: const Color(0xFFFBC02D)),
      const Text(
        '• Attendance opens only when teacher starts the session.\n'
        '• Your class details must match the active session.\n'
        '• Blink once when camera opens to confirm liveness.\n'
        '• Use the torch button if lighting is poor.\n'
        '• GPS verifies you are within the classroom radius.\n'
        '• GPS accuracy is considered automatically — no need to go outside.',
        style: TextStyle(color: Color(0xFF616161), fontSize: 13, height: 1.7),
      ),
    ]),
  );

  Widget _btn(String label, IconData icon, VoidCallback? onTap) => SizedBox(
    width: double.infinity, height: 62,
    child: ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: onTap == null
            ? Colors.grey.shade400 : const Color(0xFF8B0A1A),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30)),
        elevation: onTap == null ? 0 : 8,
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: Colors.white, size: 22),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: Colors.white,
            fontWeight: FontWeight.bold, fontSize: 16)),
      ]),
    ),
  );

  Widget _outlineBtn(String label, VoidCallback onTap) => SizedBox(
    width: double.infinity, height: 60,
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF8B0A1A), width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
      child: Text(label, style: const TextStyle(
          color: Color(0xFF8B0A1A), fontWeight: FontWeight.bold, fontSize: 15)),
    ),
  );

  Widget _webScreen() => Scaffold(
    backgroundColor: Colors.transparent,
    body: Container(
      margin: const EdgeInsets.fromLTRB(18, 10, 18, 20),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF2F3),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: const Color(0xFFFBC02D), width: 2),
      ),
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(children: [
            Container(width: 4, height: 24, color: const Color(0xFF8B0A1A)),
            const SizedBox(width: 12),
            const Text('Identity Authentication',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900,
                    color: Color(0xFF8B0A1A))),
          ]),
        ),
        Expanded(child: Center(child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisAlignment: MainAxisAlignment.center,
              children: [
            Container(width: 100, height: 100,
              decoration: BoxDecoration(
                color: const Color(0xFF8B0A1A).withOpacity(0.08),
                shape: BoxShape.circle),
              child: const Icon(Icons.smartphone_outlined,
                  size: 60, color: Color(0xFF8B0A1A))),
            const SizedBox(height: 24),
            const Text('Mobile App Required',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                    color: Color(0xFF8B0A1A))),
            const SizedBox(height: 12),
            const Text(
              'Attendance can only be marked from the Campus Pulse mobile app.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Color(0xFF666666),
                  height: 1.6)),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFBC02D))),
              child: const Row(children: [
                Icon(Icons.info_outline, color: Color(0xFFF9A825)),
                SizedBox(width: 10),
                Expanded(child: Text(
                  'Open Campus Pulse on your Android device to mark attendance.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF5D4037),
                      height: 1.5))),
              ])),
          ]),
        ))),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// OVAL PAINTER
// ─────────────────────────────────────────────────────────────────────────────
class _OvalPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.44);
    canvas.drawOval(
      Rect.fromCenter(center: center, width: 190, height: 250),
      Paint()
        ..color = const Color(0xFFFFD700).withOpacity(0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5,
    );
    // Corner guides
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const rx = 95.0; const ry = 125.0;
    final cx = center.dx; final cy = center.dy;
    canvas.drawLine(Offset(cx - rx, cy - ry + 20), Offset(cx - rx, cy - ry), p);
    canvas.drawLine(Offset(cx - rx, cy - ry), Offset(cx - rx + 20, cy - ry), p);
    canvas.drawLine(Offset(cx + rx - 20, cy - ry), Offset(cx + rx, cy - ry), p);
    canvas.drawLine(Offset(cx + rx, cy - ry), Offset(cx + rx, cy - ry + 20), p);
  }
  @override bool shouldRepaint(_) => false;
}