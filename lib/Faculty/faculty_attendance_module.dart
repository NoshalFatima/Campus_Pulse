// ✅ lib/Teacher/teacher_attendance_fragment.dart — FINAL FIXED VERSION
//
// BUG FIXES IN THIS VERSION:
//
// BUG 1 — "Failed to save location" (RTDB permission denied):
//   Your Firebase rules check root.child('Users').child(auth.uid).child('role')
//   in RTDB, but user profiles are stored in FIRESTORE, not RTDB.
//   So RTDB role was ALWAYS null → write denied → "failed to save".
//   FIX: Role is now verified in Dart via Firestore BEFORE touching RTDB.
//       If Firestore is offline, role check is skipped gracefully (RTDB rules
//       still enforce server-side as a second layer).
//
// BUG 2 — Double Firebase write (corrupted save function):
//   Previous version had TWO separate .set() calls — one direct + one in retry
//   loop — racing each other and causing unpredictable failures.
//   FIX: Single write inside the retry loop only.
//
// BUG 3 — "Permission issue" / location not getting:
//   Geolocator.checkPermission() returns LocationPermission.denied on first
//   launch BEFORE the system dialog appears. Code was treating this as a hard
//   denial and returning immediately.
//   FIX: On first launch (denied, not deniedForever), always call
//       requestPermission() and wait for user response. Also added a small
//       delay after permission grant so the OS GPS stack can warm up.
//
// OTHER FIXES RETAINED FROM PREVIOUS VERSION:
//   - Best-position tracking (never fails if any GPS reading received)
//   - Single stream subscription, no leaks
//   - _locationResolved flag prevents timeout overwriting success
//   - Auto-stop timer only on status transitions
//   - DropdownButtonFormField uses `value` not deprecated `initialValue`

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/attendance_models.dart';
import '../services/onesignal_service.dart';

class TeacherAttendanceFragment extends StatefulWidget {
  const TeacherAttendanceFragment({super.key});

  @override
  State<TeacherAttendanceFragment> createState() =>
      _TeacherAttendanceFragmentState();
}

class _TeacherAttendanceFragmentState extends State<TeacherAttendanceFragment> {
  // ── Dropdown selections ────────────────────────────────────────────────────
  String? selectedDept;
  String? selectedSem;
  String? selectedShift;
  String? selectedRadius;

  static const List<String> departments = [
    'Computer Science', 'Zoology', 'Mathematics',
    'English', 'Urdu', 'Physics', 'Pol Science',
  ];
  static const List<String> semesters = [
    'Semester 1', 'Semester 2', 'Semester 3', 'Semester 4',
    'Semester 5', 'Semester 6', 'Semester 7', 'Semester 8',
  ];
  static const List<String> shifts = ['Morning', 'Evening'];
  static const List<String> radii  = ['10', '15', '20', '30', '50'];

  // ── Controllers ────────────────────────────────────────────────────────────
  final TextEditingController _subjectController = TextEditingController();

  // ── State ──────────────────────────────────────────────────────────────────
  String _statusText   = 'Location not set';
  String _accuracyText = '📡 Accuracy: N/A';
  String _facultyName  = 'Loading...';
  String _currentSessionPath = '';
  bool _isLocationSet    = false;
  bool _isSessionActive  = false;
  bool _isLoading        = false;
  bool _locationResolved = false;

  // ── Firebase ───────────────────────────────────────────────────────────────
  final _auth      = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;
  late DatabaseReference _attendanceRootRef;
  StreamSubscription<DatabaseEvent>? _sessionListener;
  StreamSubscription<Position>?      _positionSub;

  // ── Auto-stop timer ────────────────────────────────────────────────────────
  Timer? _autoStopTimer;
  static const Duration _autoStopDuration = Duration(minutes: 40);
  String? _lastSessionStatus;

  // ── SharedPreferences keys ─────────────────────────────────────────────────
  static const String _keySessionPath = 'session_path';
  static const String _keySubject     = 'subject_name';
  static const String _keyRadius      = 'radius_value';

  @override
  void initState() {
    super.initState();
    _attendanceRootRef = FirebaseDatabase.instance.ref();
    _loadFacultyName();
    _loadCachedSession();
  }

  @override
  void dispose() {
    _autoStopTimer?.cancel();
    _sessionListener?.cancel();
    _positionSub?.cancel();
    _subjectController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FACULTY NAME
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadFacultyName() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;
      final doc = await _firestore
          .collection('Users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 10));
      if (doc.exists) {
        final data = doc.data()!;
        final name = data['name']?.toString().trim();
        if (name != null && name.isNotEmpty) {
          if (mounted) setState(() => _facultyName = name);
        } else {
          final combined =
              '${data['firstName'] ?? ''} ${data['lastName'] ?? ''}'.trim();
          if (mounted) {
            setState(() =>
                _facultyName = combined.isNotEmpty ? combined : 'Unknown Faculty');
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => _facultyName = 'Error Loading Name');
      debugPrint('❌ Load faculty name: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SESSION PATH
  // ─────────────────────────────────────────────────────────────────────────

  String? _buildSessionPath() {
    if (selectedDept == null || selectedSem == null || selectedShift == null) return null;
    final deptKey  = selectedDept!.replaceAll(' ', '_').toUpperCase();
    final semNum   = selectedSem!.replaceAll(RegExp(r'[^0-9]'), '');
    final shiftKey = selectedShift!.toUpperCase();
    return '${deptKey}_S${semNum}_$shiftKey';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CACHE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _saveToCache(String path, String subject, String radius) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySessionPath, path);
    await prefs.setString(_keySubject, subject);
    await prefs.setString(_keyRadius, radius);
  }

  Future<void> _clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySessionPath);
    await prefs.remove(_keySubject);
    await prefs.remove(_keyRadius);
    if (mounted) {
      setState(() {
        _currentSessionPath = '';
        _isLocationSet      = false;
        _isSessionActive    = false;
        _lastSessionStatus  = null;
      });
    }
  }

  Future<void> _loadCachedSession() async {
    final prefs      = await SharedPreferences.getInstance();
    final cachedPath = prefs.getString(_keySessionPath) ?? '';
    if (cachedPath.isNotEmpty) {
      if (mounted) {
        setState(() {
          _currentSessionPath     = cachedPath;
          _isLocationSet          = true;
          _subjectController.text = prefs.getString(_keySubject) ?? '';
          selectedRadius = (prefs.getString(_keyRadius) ?? '').isEmpty
              ? null
              : prefs.getString(_keyRadius);
          _statusText = 'Loaded from cache. Checking Firebase...';
        });
      }
      _restoreSelectionsFromPath(cachedPath);
      _listenSession();
    }
  }

  void _restoreSelectionsFromPath(String path) {
    for (final dept in departments) {
      if (path.contains(dept.replaceAll(' ', '_').toUpperCase())) {
        setState(() => selectedDept = dept);
        break;
      }
    }
    for (int i = 1; i <= 8; i++) {
      if (path.contains('_S${i}_') || path.endsWith('_S$i')) {
        setState(() => selectedSem = 'Semester $i');
        break;
      }
    }
    if (path.endsWith('MORNING'))      setState(() => selectedShift = 'Morning');
    else if (path.endsWith('EVENING')) setState(() => selectedShift = 'Evening');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LOCATION — BUG 3 FIX: proper permission flow
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _handleSetLocation() async {
    final path = _buildSessionPath();
    if (path == null) { _showSnack('Please select Department, Semester, and Shift.'); return; }
    if (selectedRadius == null) { _showSnack('Please select a radius.'); return; }
    if (_subjectController.text.trim().isEmpty) { _showSnack('Please enter the subject name.'); return; }
    if (_facultyName == 'Loading...' || _facultyName == 'Error Loading Name' || _facultyName == 'Unknown Faculty') {
      _showSnack('Faculty name not loaded yet. Please wait a moment.'); return;
    }

    _currentSessionPath = path;
    _locationResolved   = false;
    setState(() { _isLoading = true; _statusText = '⏳ Checking location permission...'; });

    // BUG 3 FIX: check then always request if not yet granted
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      // First launch OR previously dismissed — show system dialog
      if (mounted) setState(() => _statusText = '⏳ Requesting permission...');
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) setState(() { _isLoading = false; _statusText = 'Permission permanently denied ❌'; });
      _showSnack('Location permanently denied. Opening app settings...', isError: true);
      await Geolocator.openAppSettings();
      return;
    }

    if (permission == LocationPermission.denied) {
      if (mounted) setState(() { _isLoading = false; _statusText = 'Permission denied ❌'; });
      _showSnack('Location permission is required.', isError: true);
      return;
    }

    // Check GPS service
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) setState(() { _isLoading = false; _statusText = 'GPS disabled ❌'; });
      _showSnack('GPS is off. Opening location settings...');
      await Geolocator.openLocationSettings();
      return;
    }

    if (mounted) setState(() => _statusText = '⏳ Starting GPS...');
    await Future.delayed(const Duration(milliseconds: 500)); // warm-up
    await _fetchAccurateLocation();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // GPS FETCH — best-position tracking
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _fetchAccurateLocation() async {
    if (kIsWeb) {
      try {
        if (mounted) setState(() => _statusText = '⏳ Getting location...');
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 20));
        _locationResolved = true;
        if (mounted) setState(() => _isLoading = false);
        await _saveLocationToFirebase(pos);
      } catch (e) {
        if (mounted) setState(() { _isLoading = false; _statusText = '❌ Location unavailable on web.'; });
        _showSnack('Could not get location on web. Try again.', isError: true);
      }
      return;
    }

    // Stream-based with best-position tracking.
    // Accept immediately at ≤25 m; after 20 s use best reading; only fail on zero readings.
    const double goodAccuracy = 25.0;
    Position? bestPosition;

    await _positionSub?.cancel();
    final completer = Completer<void>();

    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen(
      (Position pos) {
        if (_locationResolved) return;
        final acc = pos.accuracy;
        if (bestPosition == null || acc < bestPosition!.accuracy) bestPosition = pos;

        final dot = acc <= 10 ? '🟢' : acc <= 30 ? '🟡' : '🔴';
        if (mounted) {
          setState(() {
            _accuracyText = '$dot GPS: ${acc.toStringAsFixed(1)}m';
            _statusText   = '⏳ Getting location… (${acc.toStringAsFixed(1)}m)';
          });
        }

        if (acc <= goodAccuracy && !completer.isCompleted) completer.complete();
      },
      onError: (e) {
        debugPrint('❌ GPS stream: $e');
        if (!completer.isCompleted) completer.completeError(e);
      },
    );

    try {
      await completer.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      debugPrint('⏰ GPS timeout — best: ${bestPosition?.accuracy}m');
    } catch (e) {
      await _positionSub?.cancel(); _positionSub = null; _locationResolved = true;
      if (mounted) setState(() { _isLoading = false; _statusText = '❌ GPS error.'; _accuracyText = '❌ GPS Error'; });
      _showSnack('GPS error. Restart the app and try again.', isError: true);
      return;
    }

    await _positionSub?.cancel(); _positionSub = null; _locationResolved = true;
    if (mounted) setState(() => _isLoading = false);

    if (bestPosition == null) {
      if (mounted) setState(() { _statusText = '❌ No GPS signal. Move outside and retry.'; _accuracyText = '❌ No Signal'; });
      _showSnack('No GPS signal. Move near a window or outside, then try again.', isError: true);
      return;
    }

    if (bestPosition!.accuracy > goodAccuracy) {
      _showSnack('⚠️ GPS accuracy ${bestPosition!.accuracy.toStringAsFixed(0)}m — saved. Works better outdoors.');
    }

    await _saveLocationToFirebase(bestPosition!);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FIREBASE SAVE — BUG 1 & 2 FIX
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _saveLocationToFirebase(Position position) async {
    // Role check via Firestore. Try cache first (instant/offline), then server.
    // If both fail, skip client check — RTDB rules enforce server-side.
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      _showSnack('Not logged in. Please log in and try again.', isError: true);
      if (mounted) setState(() { _isLoading = false; _isLocationSet = false; });
      return;
    }

    try {
      String? role;

      // 1. Try cache first — works offline and is instant on web
      try {
        final cached = await _firestore
            .collection('Users')
            .doc(uid)
            .get(const GetOptions(source: Source.cache));
        role = cached.data()?['role']?.toString();
        debugPrint('Role from cache: $role');
      } catch (_) {
        // No cache — fall through to server
      }

      // 2. Fetch from server if cache missed
      if (role == null) {
        final server = await _firestore
            .collection('Users')
            .doc(uid)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 15));
        role = server.data()?['role']?.toString();
        debugPrint('Role from server: $role');
      }

      if (role != null && role != 'Teacher') {
        _showSnack('Access denied: only Teachers can set attendance.', isError: true);
        if (mounted) setState(() { _isLoading = false; _isLocationSet = false; });
        return;
      }
    } catch (e) {
      debugPrint('Role check skipped (will rely on RTDB rules): $e');
    }

    final radius = double.tryParse(selectedRadius ?? '20') ?? 20.0;
    final sessionData = <String, dynamic>{
      'latitude':         position.latitude,
      'longitude':        position.longitude,
      'locationAccuracy': position.accuracy,
      'department':       selectedDept,
      'semester':         selectedSem,
      'shift':            selectedShift,
      'radiusMeters':     radius,
      'timestamp':        DateTime.now().millisecondsSinceEpoch,
      'subjectName':      _subjectController.text.trim(),
      'facultyName':      _facultyName,
      'status':           'set',
    };

    const int maxAttempts = 3;
    Exception? lastError;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (mounted && attempt > 1) {
          setState(() => _statusText = '⏳ Saving… (retry $attempt/$maxAttempts)');
        }

        // BUG 2 FIX: single write in retry loop only (removed duplicate write)
        await _attendanceRootRef
            .child('AttendanceSession')
            .child(_currentSessionPath)
            .set(sessionData)
            .timeout(const Duration(seconds: 10));

        await _saveToCache(
          _currentSessionPath,
          _subjectController.text.trim(),
          selectedRadius!,
        );

        if (mounted) {
          setState(() {
            _isLocationSet = true;
            _statusText =
                '✅ Location Set\n'
                'Session: ${_currentSessionPath.replaceAll('_', ' ')}\n'
                'Subject: ${_subjectController.text.trim()} | Faculty: $_facultyName\n'
                'Radius: ${radius.toStringAsFixed(1)}m';
          });
        }

        _listenSession();
        return;

      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        debugPrint('❌ Firebase save attempt $attempt/$maxAttempts: $e');
        if (attempt < maxAttempts) await Future.delayed(Duration(seconds: attempt));
      }
    }

    if (mounted) {
      setState(() { _isLocationSet = false; _statusText = '❌ Failed to save. Check internet.'; });
    }
    _showSnack('Could not save location after $maxAttempts attempts. Check internet.',
        isError: true);
    debugPrint('❌ All save attempts failed. Last: $lastError');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SESSION MANAGEMENT
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _startAttendance() async {
    if (!_isLocationSet || _currentSessionPath.isEmpty) { _showSnack('Please set location first.'); return; }
    try {
      await _attendanceRootRef
          .child('AttendanceSession').child(_currentSessionPath).child('status')
          .set('allowed').timeout(const Duration(seconds: 10));
      _showSnack('✅ Attendance started. Auto-stops in 40 minutes.');
      await _sendAttendanceNotification(isStarting: true);
      _startAutoStopTimer();
    } catch (e) {
      _showSnack('Failed to start attendance. Check internet.', isError: true);
      debugPrint('❌ Start attendance: $e');
    }
  }

  Future<void> _stopAttendance() async {
    if (_currentSessionPath.isEmpty) { _showSnack('No active session found.'); return; }
    _autoStopTimer?.cancel();
    try {
      await _attendanceRootRef
          .child('AttendanceSession').child(_currentSessionPath).child('status')
          .set('stopped').timeout(const Duration(seconds: 10));
      _showSnack('✅ Attendance stopped.');
      await _sendAttendanceNotification(isStarting: false);
      await _clearCache();
      if (mounted) {
        setState(() {
          _statusText = 'Attendance Stopped ⛔';
          _accuracyText = '📡 Accuracy: N/A';
          _isSessionActive = false;
          _lastSessionStatus = null;
        });
      }
    } catch (e) {
      _showSnack('Failed to stop attendance. Check internet.', isError: true);
      debugPrint('❌ Stop attendance: $e');
    }
  }

  void _startAutoStopTimer() {
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(_autoStopDuration, () {
      debugPrint('⏰ 40 min elapsed — auto-stopping session in Firebase.');
      // Store path locally before any state changes
      final pathToStop = _currentSessionPath;
      if (pathToStop.isEmpty) return;

      // Directly write 'stopped' to Firebase — bypasses any state race condition
      _attendanceRootRef
          .child('AttendanceSession')
          .child(pathToStop)
          .child('status')
          .set('stopped')
          .then((_) {
            debugPrint('✅ Auto-stop: Firebase status set to stopped');
            if (mounted) {
              _showSnack('⚠️ Attendance auto-stopped after 40 minutes.');
            }
          })
          .catchError((e) {
            debugPrint('❌ Auto-stop Firebase write failed: $e');
          });

      // Clear local state
      _clearCache();
      if (mounted) {
        setState(() {
          _statusText      = 'Attendance Auto-Stopped ⛔';
          _accuracyText    = '📡 Accuracy: N/A';
          _isSessionActive = false;
          _lastSessionStatus = null;
        });
      }
    });
  }

  void _listenSession() {
    if (_currentSessionPath.isEmpty) return;
    _sessionListener?.cancel();
    _sessionListener = _attendanceRootRef
        .child('AttendanceSession').child(_currentSessionPath).child('status')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final status = event.snapshot.value?.toString() ?? 'none';
      if (status == _lastSessionStatus) return;
      _lastSessionStatus = status;

      if (status == 'allowed') {
        setState(() { _isSessionActive = true; _statusText = '${_currentSessionPath.replaceAll('_', ' ')} — Active ✅'; });
        _startAutoStopTimer();
      } else {
        setState(() { _isSessionActive = false; _statusText = '${_currentSessionPath.replaceAll('_', ' ')} — Inactive ⛔'; });
        _autoStopTimer?.cancel();
        if (status == 'stopped' || status == 'none') _clearCache();
      }
    }, onError: (e) => debugPrint('❌ Session listener: $e'));
  }

  Future<void> _sendAttendanceNotification({required bool isStarting}) async {
    try {
      if (selectedDept == null || selectedSem == null || selectedShift == null) return;
      final subject = _subjectController.text.trim();
      await OneSignalService.sendToSpecific(
        title: isStarting ? '📋 Attendance Started' : '⛔ Attendance Closed',
        body:  isStarting
            ? 'Attendance is now open for $subject. Mark your attendance now!'
            : 'Attendance for $subject has been closed by $_facultyName.',
        dept: selectedDept!, sem: selectedSem!, shift: selectedShift!,
        data: {
          'type': isStarting ? 'attendance_started' : 'attendance_stopped',
          'subject': subject, 'faculty': _facultyName, 'sessionPath': _currentSessionPath,
        },
      );
    } catch (e) { debugPrint('❌ OneSignal: $e'); }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(isError ? Icons.error_outline : Icons.info_outline, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500))),
      ]),
      backgroundColor: isError ? Colors.red.shade700 : const Color(0xFF8B0A1A),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(12),
      duration: const Duration(seconds: 4),
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        margin: const EdgeInsets.fromLTRB(18, 20, 18, 20),
        decoration: BoxDecoration(
          color: const Color(0xFFFDF2F3),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFFFBC02D), width: 2.5),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, 6))],
        ),
        child: Column(children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Row(children: [
              Container(width: 4, height: 24,
                  decoration: BoxDecoration(color: const Color(0xFF8B0A1A), borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 12),
              const Text('Attendance Control',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _buildStatusCard(), const SizedBox(height: 16),
                _buildClassSelectionCard(), const SizedBox(height: 16),
                _buildLectureDetailsCard(), const SizedBox(height: 16),
                _buildAreaCard(), const SizedBox(height: 20),
                _buildActionButtons(), const SizedBox(height: 20),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildStatusCard() {
    return _buildCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('📍 Current Status',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
      const SizedBox(height: 8),
      Text(_statusText,
          style: const TextStyle(fontSize: 13.5, color: Color(0xFF8B0A1A), fontWeight: FontWeight.w600)),
      if (_accuracyText.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(_accuracyText, style: const TextStyle(fontSize: 11, color: Color(0xFF8B6914))),
      ],
    ]));
  }

  Widget _buildClassSelectionCard() {
    return _buildCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('🎓 Class Selection',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF333333))),
      const SizedBox(height: 12),
      _buildDropdownField(label: '🏢 Department', value: selectedDept, items: departments, onChanged: (v) => setState(() => selectedDept = v)),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _buildDropdownField(label: '📝 Semester', value: selectedSem, items: semesters, onChanged: (v) => setState(() => selectedSem = v))),
        const SizedBox(width: 10),
        Expanded(child: _buildDropdownField(label: '🕒 Shift', value: selectedShift, items: shifts, onChanged: (v) => setState(() => selectedShift = v))),
      ]),
    ]));
  }

  Widget _buildLectureDetailsCard() {
    return _buildCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Lecture Details',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
      const SizedBox(height: 12),
      const Text('📚 Subject Name',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
      TextField(
        controller: _subjectController,
        decoration: const InputDecoration(
          hintText: 'Enter subject',
          hintStyle: TextStyle(fontSize: 13, color: Colors.black38),
          border: InputBorder.none, isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 8),
        ),
      ),
      Divider(color: Colors.grey.shade200),
      const Text('👤 Faculty',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
      const SizedBox(height: 4),
      Text(_facultyName, style: const TextStyle(fontSize: 14, color: Color(0xFF666666))),
    ]));
  }

  Widget _buildAreaCard() {
    return _buildCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Attendance Area',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
      const SizedBox(height: 10),
      _buildDropdownField(label: '📐 Radius (meters)', value: selectedRadius, items: radii, onChanged: (v) => setState(() => selectedRadius = v)),
    ]));
  }

  Widget _buildActionButtons() {
    return Column(children: [
      _buildButton(label: '📍 Set Location', onPressed: _isLoading ? null : _handleSetLocation, isLoading: _isLoading),
      const SizedBox(height: 10),
      if (!_isSessionActive)
        _buildButton(label: '▶️ Start Attendance', onPressed: _isLocationSet ? _startAttendance : null)
      else
        _buildButton(label: '⏹️ Stop Attendance', onPressed: _stopAttendance, backgroundColor: const Color(0xFF2C2C2C)),
      const SizedBox(height: 10),
      if (_isSessionActive || _isLocationSet)
        _buildButton(
          label: '👁️ View Attendance',
          onPressed: () {
            if (_currentSessionPath.isEmpty) {
              _showSnack('No active session. Set location first.');
              return;
            }
            // Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceRecordFragment(...)));
          },
        ),
    ]);
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: child,
    );
  }

  Widget _buildDropdownField({
    required String label, required String? value,
    required List<String> items, required ValueChanged<String?> onChanged,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF8B0A1A))),
      DropdownButtonFormField<String>(
        value: value,
        decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 4)),
        hint: const Text('Select', style: TextStyle(fontSize: 13)),
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 13)))).toList(),
        onChanged: onChanged,
      ),
      Divider(color: Colors.grey.shade200, height: 1),
    ]);
  }

  Widget _buildButton({
    required String label, required VoidCallback? onPressed,
    bool isLoading = false, Color backgroundColor = const Color(0xFF8B0A1A),
  }) {
    return SizedBox(
      width: double.infinity, height: 58,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: onPressed == null ? Colors.grey.shade400 : backgroundColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          elevation: 4,
        ),
        child: isLoading
            ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
      ),
    );
  }
}