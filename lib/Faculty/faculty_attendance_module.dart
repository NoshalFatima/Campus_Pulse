// lib/Teacher/teacher_attendance_fragment.dart

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
import '../Faculty/faculty_view_attendance.dart';

class TeacherAttendanceFragment extends StatefulWidget {
  const TeacherAttendanceFragment({super.key});
  @override
  State<TeacherAttendanceFragment> createState() =>
      _TeacherAttendanceFragmentState();
}

class _TeacherAttendanceFragmentState
    extends State<TeacherAttendanceFragment> {

  // ── Dropdowns ─────────────────────────────────────────────────
  String? selectedDept;
  String? selectedSem;
  String? selectedShift;
  String? selectedRadius;

  static const List<String> departments = [
    'Computer Science','Zoology','Mathematics',
    'English','Urdu','Physics','Pol Science',
  ];
  static const List<String> semesters = [
    'Semester 1','Semester 2','Semester 3','Semester 4',
    'Semester 5','Semester 6','Semester 7','Semester 8',
  ];
  static const List<String> shifts  = ['Morning','Evening'];
  static const List<String> radii   = ['10','15','20','30','50'];

  final TextEditingController _subjectController = TextEditingController();

  // ── State ─────────────────────────────────────────────────────
  String _statusText    = 'Location not set';
  String _accuracyText  = '📡 Accuracy: N/A';
  String _facultyName   = 'Loading...';
  String _currentSessionPath = '';
  bool _isLocationSet    = false;
  bool _isSessionActive  = false;
  bool _isLoading        = false;
  bool _isMarkingAbsent  = false;
  bool _locationResolved = false;

  // ── Firebase ──────────────────────────────────────────────────
  final _auth      = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;
  late DatabaseReference _attendanceRootRef;
  StreamSubscription<DatabaseEvent>? _sessionListener;
  StreamSubscription<Position>?      _positionSub;

  Timer? _autoStopTimer;
  static const Duration _autoStopDuration = Duration(minutes: 40);
  String? _lastSessionStatus;

  static const String _keySessionPath = 'session_path';
  static const String _keySubject     = 'subject_name';
  static const String _keyRadius      = 'radius_value';
  static const String _keySubjectKey  = 'subject_key';

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

  // ── Faculty name ──────────────────────────────────────────────
  Future<void> _loadFacultyName() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;
      final doc = await _firestore
          .collection('Users').doc(uid).get()
          .timeout(const Duration(seconds: 10));
      if (doc.exists) {
        final data = doc.data()!;
        final name = data['name']?.toString().trim();
        if (mounted) {
          setState(() => _facultyName = (name != null && name.isNotEmpty)
              ? name
              : '${data['firstName'] ?? ''} ${data['lastName'] ?? ''}'.trim());
        }
      }
    } catch (e) {
      if (mounted) setState(() => _facultyName = 'Error Loading Name');
    }
  }

  // ── Session path ──────────────────────────────────────────────
  // Class path — without subject (for fetching students)
  String? _buildClassPath() {
    if (selectedDept == null ||
        selectedSem  == null ||
        selectedShift == null) return null;
    final dk = selectedDept!.replaceAll(' ', '_').toUpperCase();
    final sn = selectedSem!.replaceAll(RegExp(r'[^0-9]'), '');
    final sk = selectedShift!.toUpperCase();
    return '${dk}_S${sn}_$sk';
  }

  // Session path — SUBJECT_TIMESTAMP so each session is unique
  // e.g. COMPUTER_SCIENCE_S8_MORNING/AI_1748234567890
  // This allows multiple lectures of same subject in one day
  String? _buildSessionPath() {
    final classPath = _buildClassPath();
    if (classPath == null) return null;
    final subj = _subjectController.text.trim();
    if (subj.isEmpty) return null;
    final subjKey   = subj.replaceAll(' ', '_').toUpperCase();
    final sessionId = '${subjKey}_${DateTime.now().millisecondsSinceEpoch}';
    return classPath + '/' + sessionId;
  }

  // Extract class path (first part before /)
  String get _classPathOnly {
    final parts = _currentSessionPath.split('/');
    return parts.isNotEmpty ? parts.first : _currentSessionPath;
  }

  // Extract subject key from session ID (remove timestamp)
  // 'AI_1748234567890' → 'AI'
  String _extractSubjectKey(String sessionId) {
    // Remove trailing _TIMESTAMP (13 digits)
    return sessionId.replaceAll(RegExp(r'_\d{13}$'), '');
  }

  String get _subjectKey =>
      _subjectController.text.trim().replaceAll(' ', '_').toUpperCase();

  // ── Cache ─────────────────────────────────────────────────────
  Future<void> _saveToCache(
      String path, String subject, String radius) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySessionPath, path);
    await prefs.setString(_keySubject,     subject);
    await prefs.setString(_keyRadius,      radius);
    await prefs.setString(_keySubjectKey,
        subject.trim().replaceAll(' ', '_').toUpperCase());
  }

  Future<void> _clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySessionPath);
    await prefs.remove(_keySubject);
    await prefs.remove(_keyRadius);
    await prefs.remove(_keySubjectKey);
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
          selectedRadius = prefs.getString(_keyRadius)?.isEmpty == true
              ? null : prefs.getString(_keyRadius);
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
        setState(() => selectedDept = dept); break;
      }
    }
    for (int i = 1; i <= 8; i++) {
      if (path.contains('_S${i}_') || path.endsWith('_S$i')) {
        setState(() => selectedSem = 'Semester $i'); break;
      }
    }
    if (path.endsWith('MORNING'))
      setState(() => selectedShift = 'Morning');
    else if (path.endsWith('EVENING'))
      setState(() => selectedShift = 'Evening');
  }

  // ── Location ──────────────────────────────────────────────────
  Future<void> _handleSetLocation() async {
    if (_subjectController.text.trim().isEmpty) {
      _showSnack('Please enter the subject name first.'); return;
    }
    final path = _buildSessionPath();
    if (path == null) {
      _showSnack('Please select Department, Semester, and Shift.'); return;
    }
    if (selectedRadius == null) {
      _showSnack('Please select a radius.'); return;
    }

    _currentSessionPath = path;
    _locationResolved   = false;
    setState(() { _isLoading = true; _statusText = '⏳ Checking permission...'; });

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      setState(() => _statusText = '⏳ Requesting permission...');
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      setState(() { _isLoading = false; _statusText = 'Permission denied ❌'; });
      _showSnack('Location permanently denied. Opening settings...', isError: true);
      await Geolocator.openAppSettings(); return;
    }
    if (permission == LocationPermission.denied) {
      setState(() { _isLoading = false; _statusText = 'Permission denied ❌'; });
      _showSnack('Location permission is required.', isError: true); return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() { _isLoading = false; _statusText = 'GPS disabled ❌'; });
      _showSnack('GPS is off. Opening settings...');
      await Geolocator.openLocationSettings(); return;
    }

    setState(() => _statusText = '⏳ Starting GPS...');
    await Future.delayed(const Duration(milliseconds: 500));
    await _fetchAccurateLocation();
  }

  Future<void> _fetchAccurateLocation() async {
    if (kIsWeb) {
      try {
        if (mounted) setState(() => _statusText = '⏳ Getting web location...');
        // Web GPS: try 3 times, pick best accuracy
        Position? bestPos;
        for (int i = 0; i < 3; i++) {
          try {
            final pos = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                  accuracy: LocationAccuracy.best),
            ).timeout(const Duration(seconds: 15));
            if (bestPos == null || pos.accuracy < bestPos!.accuracy) {
              bestPos = pos;
            }
            if (pos.accuracy <= 100) break;
            await Future.delayed(const Duration(seconds: 2));
          } catch (_) {}
        }
        if (bestPos == null) throw Exception('No location');
        _locationResolved = true;
        if (mounted) {
          setState(() {
            _isLoading    = false;
            _accuracyText = '⚠️ Web GPS: ${bestPos!.accuracy.toStringAsFixed(0)}m '
                '(web less accurate than mobile)';
          });
        }
        _showSnack('Web GPS accuracy: ${bestPos!.accuracy.toStringAsFixed(0)}m. '
            'Use large radius (50m+) on web.');
        await _saveLocationToFirebase(bestPos!);
      } catch (e) {
        if (mounted) setState(() {
          _isLoading  = false;
          _statusText = '❌ Location unavailable on web.';
        });
        _showSnack('Web GPS failed. Try mobile for better accuracy.',
            isError: true);
      }
      return;
    }

    const double goodAccuracy = 25.0;
    Position? bestPosition;
    await _positionSub?.cancel();
    final completer = Completer<void>();

    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      if (_locationResolved) return;
      if (bestPosition == null || pos.accuracy < bestPosition!.accuracy) {
        bestPosition = pos;
      }
      final dot = pos.accuracy <= 10
          ? '🟢' : pos.accuracy <= 30 ? '🟡' : '🔴';
      if (mounted) setState(() {
        _accuracyText = '$dot GPS: ${pos.accuracy.toStringAsFixed(1)}m';
        _statusText   = '⏳ Getting location… (${pos.accuracy.toStringAsFixed(1)}m)';
      });
      if (pos.accuracy <= goodAccuracy && !completer.isCompleted) {
        completer.complete();
      }
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    try {
      await completer.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      debugPrint('GPS timeout — best: ${bestPosition?.accuracy}m');
    } catch (e) {
      await _positionSub?.cancel(); _positionSub = null;
      _locationResolved = true;
      if (mounted) setState(() {
        _isLoading = false;
        _statusText = '❌ GPS error.';
      });
      _showSnack('GPS error. Restart and try again.', isError: true);
      return;
    }

    await _positionSub?.cancel();
    _positionSub = null;
    _locationResolved = true;
    if (mounted) setState(() => _isLoading = false);

    if (bestPosition == null) {
      if (mounted) setState(() {
        _statusText   = '❌ No GPS signal.';
        _accuracyText = '❌ No Signal';
      });
      _showSnack('No GPS signal. Move near a window and try again.',
          isError: true);
      return;
    }
    await _saveLocationToFirebase(bestPosition!);
  }

  Future<void> _saveLocationToFirebase(Position position) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      _showSnack('Not logged in.', isError: true);
      if (mounted) setState(() { _isLoading = false; });
      return;
    }

    try {
      String? role;
      try {
        final cached = await _firestore.collection('Users').doc(uid)
            .get(const GetOptions(source: Source.cache));
        role = cached.data()?['role']?.toString();
      } catch (_) {}
      if (role == null) {
        final server = await _firestore.collection('Users').doc(uid)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 15));
        role = server.data()?['role']?.toString();
      }
      if (role != null && role != 'Teacher') {
        _showSnack('Access denied: only Teachers can set attendance.',
            isError: true);
        if (mounted) setState(() { _isLoading = false; });
        return;
      }
    } catch (e) {
      debugPrint('Role check skipped: $e');
    }

    final radius = double.tryParse(selectedRadius ?? '20') ?? 20.0;
    final sessionData = <String, dynamic>{
      'latitude'        : position.latitude,
      'longitude'       : position.longitude,
      'locationAccuracy': position.accuracy,
      'department'      : selectedDept,
      'semester'        : selectedSem,
      'shift'           : selectedShift,
      'radiusMeters'    : radius,
      'timestamp'       : DateTime.now().millisecondsSinceEpoch,
      'subjectName'     : _subjectController.text.trim(),
      'subjectKey'      : _subjectKey,
      'facultyName'     : _facultyName,
      'status'          : 'set',
    };

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        if (mounted && attempt > 1) {
          setState(() => _statusText = '⏳ Saving… (retry $attempt/3)');
        }
        // _currentSessionPath = CLASS/SESSION_ID
        // Must split and use two .child() calls — .child() doesn't parse '/'
        final pathParts   = _currentSessionPath.split('/');
        final classNode   = pathParts.first;
        final sessionNode = pathParts.length > 1 ? pathParts.last : pathParts.first;

        await _attendanceRootRef
            .child('AttendanceSession')
            .child(classNode)
            .child(sessionNode)
            .set(sessionData)
            .timeout(const Duration(seconds: 10));

        await _saveToCache(
            _currentSessionPath,
            _subjectController.text.trim(),
            selectedRadius!);

        if (mounted) {
          setState(() {
            _isLocationSet = true;
            _statusText =
                '✅ Location Set\n'
                'Session: ${_currentSessionPath.replaceAll('_', ' ')}\n'
                'Subject: ${_subjectController.text.trim()} | '
                'Faculty: $_facultyName\n'
                'Radius: ${radius.toStringAsFixed(1)}m';
          });
        }
        _listenSession();
        return;
      } catch (e) {
        debugPrint('Save attempt $attempt: $e');
        if (attempt < 3) {
          await Future.delayed(Duration(seconds: attempt));
        }
      }
    }

    if (mounted) {
      setState(() {
        _isLocationSet = false;
        _statusText    = '❌ Failed to save. Check internet.';
      });
    }
    _showSnack('Could not save location. Check internet.', isError: true);
  }

  // ── Session management ────────────────────────────────────────
  Future<void> _startAttendance() async {
    if (!_isLocationSet || _currentSessionPath.isEmpty) {
      _showSnack('Please set location first.'); return;
    }
    try {
      final sParts = _currentSessionPath.split('/');
      final sClass = sParts.first;
      final sNode  = sParts.length > 1 ? sParts.last : sParts.first;

      await _attendanceRootRef
          .child('AttendanceSession')
          .child(sClass)
          .child(sNode)
          .update({
            'status'     : 'allowed',
            'startedAt'  : DateTime.now().millisecondsSinceEpoch,
            'sessionDate': _today(),
          })
          .timeout(const Duration(seconds: 10));
      _showSnack('✅ Attendance started. Auto-stops in 40 minutes.');
      await _sendAttendanceNotification(isStarting: true);
      _startAutoStopTimer();
    } catch (e) {
      _showSnack('Failed to start attendance.', isError: true);
    }
  }

  Future<void> _stopAttendance() async {
    if (_currentSessionPath.isEmpty) {
      _showSnack('No active session.'); return;
    }
    _autoStopTimer?.cancel();

    final parts    = _currentSessionPath.split('/');
    final clsNode  = parts.first;
    final sessNode = parts.length > 1 ? parts.last : parts.first;

    try {
      await _attendanceRootRef
          .child('AttendanceSession')
          .child(clsNode)
          .child(sessNode)
          .child('status')
          .set('stopped')
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      _showSnack('Failed to stop. Check internet.', isError: true);
      return;
    }

    await _sendAttendanceNotification(isStarting: false);
    _showSnack('Attendance stopped. Marking absent students...');

    // Mark absent — await so it completes before clearing state
    await _markAbsentStudents(clsNode, sessNode);

    await _clearCache();
    if (mounted) {
      setState(() {
        _statusText      = 'Attendance Stopped ⛔';
        _accuracyText    = '📡 Accuracy: N/A';
        _isSessionActive = false;
        _lastSessionStatus = null;
      });
    }
  }

  
  Future<void> _markAbsentStudents(
    String classPath, String sessionId) async {
    if (mounted) setState(() => _isMarkingAbsent = true);
    debugPrint('=== MARK ABSENT START ===');
    debugPrint('classPath : $classPath');
    debugPrint('sessionId : $sessionId');

    try {
      // ── 1. Fetch session data from RTDB ──────────────────────
      Map<String, dynamic> sData = {};
      try {
        final snap = await _attendanceRootRef
            .child('AttendanceSession')
            .child(classPath)
            .child(sessionId)
            .get()
            .timeout(const Duration(seconds: 10));
        if (snap.exists && snap.value != null) {
          sData = Map<String, dynamic>.from(snap.value as Map);
        }
      } catch (e) {
        debugPrint('Session fetch error: $e');
      }

      debugPrint('Session data keys: ' + sData.keys.toString());

      // ── 2. Extract dept / sem / shift ────────────────────────
      String dept  = sData['department']?.toString() ?? selectedDept  ?? '';
      String sem   = sData['semester']?.toString()   ?? selectedSem   ?? '';
      String shift = sData['shift']?.toString()      ?? selectedShift ?? '';
      String subjDisplay = sData['subjectName']?.toString()
          ?? sessionId.replaceAll(RegExp(r'_\d+\$'), '').replaceAll('_', ' ');

      debugPrint('dept=$dept sem=$sem shift=$shift subj=$subjDisplay');

      if (dept.isEmpty || shift.isEmpty) {
        debugPrint('Cannot mark absent — missing dept/shift');
        if (mounted) setState(() => _isMarkingAbsent = false);
        return;
      }

      // ── 3. Session date ──────────────────────────────────────
      String today = sData['sessionDate']?.toString() ?? _today();
      debugPrint('date=$today');

      // ── 4. Fetch students from Firestore ─────────────────────
      final semNum    = sem.replaceAll(RegExp(r'[^0-9]'), '');
      final semSuffix = _semSuffix(semNum); // '8th'

      debugPrint('Querying students: dept=$dept sem=$semSuffix/$sem shift=$shift');

      QuerySnapshot? snap;

      // Try suffix format first ('8th')
      try {
        final q = await _firestore.collection('Users')
            .where('role',     isEqualTo: 'student')
            .where('dept',     isEqualTo: dept)
            .where('semester', isEqualTo: semSuffix)
            .where('shift',    isEqualTo: shift)
            .get()
            .timeout(const Duration(seconds: 15));
        if (q.docs.isNotEmpty) snap = q;
      } catch (e) { debugPrint('Query 1 error: $e'); }

      // Try 'Semester N' format
      if (snap == null || snap.docs.isEmpty) {
        try {
          final q = await _firestore.collection('Users')
              .where('role',     isEqualTo: 'student')
              .where('dept',     isEqualTo: dept)
              .where('semester', isEqualTo: sem)
              .where('shift',    isEqualTo: shift)
              .get()
              .timeout(const Duration(seconds: 15));
          if (q.docs.isNotEmpty) snap = q;
        } catch (e) { debugPrint('Query 2 error: $e'); }
      }

      // Try without shift filter (fallback)
      if (snap == null || snap.docs.isEmpty) {
        try {
          final q = await _firestore.collection('Users')
              .where('role',     isEqualTo: 'student')
              .where('dept',     isEqualTo: dept)
              .where('semester', isEqualTo: semSuffix)
              .get()
              .timeout(const Duration(seconds: 15));
          snap = q;
          debugPrint('Fallback query (no shift): ' + q.docs.length.toString() + ' students');
        } catch (e) { debugPrint('Query 3 error: $e'); }
      }

      final students = snap?.docs ?? [];
      debugPrint('Total students found: ' + students.length.toString());

      if (students.isEmpty) {
        debugPrint('No students found — check dept/sem/shift values');
        if (mounted) setState(() => _isMarkingAbsent = false);
        return;
      }

      // ── 5. Check who already marked present ─────────────────
      Set<String> alreadyPresent = {};
      try {
        final existSnap = await _attendanceRootRef
            .child('AttendanceRecords')
            .child(classPath)
            .child(sessionId)
            .child(today)
            .get()
            .timeout(const Duration(seconds: 10));
        if (existSnap.exists && existSnap.value != null) {
          final dayMap = Map<String, dynamic>.from(existSnap.value as Map);
          alreadyPresent = dayMap.keys.toSet();
        }
      } catch (e) { debugPrint('Existing records fetch: $e'); }

      debugPrint('Already present: ' + alreadyPresent.length.toString());

      // ── 6. Mark absent for everyone not present ──────────────
      int absentCount = 0;
      for (final doc in students) {
        final uid = doc.id;
        if (alreadyPresent.contains(uid)) {
          debugPrint('Skip (present): $uid');
          continue;
        }
        final data  = doc.data() as Map<String, dynamic>;
        final name  = data['name']?.toString()  ?? '';
        final regNo = data['regNo']?.toString() ?? '';

        debugPrint('Marking absent: $name ($regNo)');
        try {
          await _attendanceRootRef
              .child('AttendanceRecords')
              .child(classPath)
              .child(sessionId)
              .child(today)
              .child(uid)
              .set({
            'status'      : 'Absent',
            'timestamp'   : DateTime.now().millisecondsSinceEpoch,
            'verification': 'Auto-absent',
            'name'        : name,
            'regNo'       : regNo,
            'uid'         : uid,
            'subject'     : subjDisplay,
            'sessionId'   : sessionId,
            'dept'        : dept,
            'semester'    : semSuffix,
            'shift'       : shift,
          });
          absentCount++;
        } catch (e) {
          debugPrint('Failed absent for $uid: $e');
        }
      }

      debugPrint('=== MARK ABSENT DONE: $absentCount marked ===');
      if (mounted && absentCount > 0) {
        _showSnack('$absentCount student(s) marked absent.');
      }
    } catch (e) {
      debugPrint('_markAbsentStudents error: $e');
    } finally {
      if (mounted) setState(() => _isMarkingAbsent = false);
    }
  }

  
  String _semSuffix(String num) {
    switch (num) {
      case '1': return '1st';
      case '2': return '2nd';
      case '3': return '3rd';
      default:  return '${num}th';
    }
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  void _startAutoStopTimer() {
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(_autoStopDuration, () async {
      final pathToStop = _currentSessionPath;
      if (pathToStop.isEmpty) return;

      try {
        final asParts = pathToStop.split('/');
        final asClass = asParts.first;
        final asNode  = asParts.length > 1 ? asParts.last : asParts.first;
        await _attendanceRootRef
            .child('AttendanceSession')
            .child(asClass)
            .child(asNode)
            .child('status')
            .set('stopped');
        debugPrint('Auto-stop: status set to stopped');
        if (mounted) {
          _showSnack('⚠️ Attendance auto-stopped after 40 minutes.');
        }
      } catch (e) {
        debugPrint('Auto-stop write failed: $e');
      }

      // Also mark absents on auto-stop
      final asParts2 = pathToStop.split('/');
      final asClass2 = asParts2.first;
      final asNode2  = asParts2.length > 1 ? asParts2.last : asParts2.first;
      await _markAbsentStudents(asClass2, asNode2);
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
    final lParts = _currentSessionPath.split('/');
    final lClass = lParts.first;
    final lNode  = lParts.length > 1 ? lParts.last : lParts.first;

    _sessionListener = _attendanceRootRef
        .child('AttendanceSession')
        .child(lClass)
        .child(lNode)
        .child('status')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final status = event.snapshot.value?.toString() ?? 'none';
      if (status == _lastSessionStatus) return;
      _lastSessionStatus = status;

      if (status == 'allowed') {
        setState(() {
          _isSessionActive = true;
          _statusText = '${_currentSessionPath.replaceAll('_', ' ')} — Active ✅';
        });
        _startAutoStopTimer();
      } else {
        setState(() {
          _isSessionActive = false;
          _statusText = '${_currentSessionPath.replaceAll('_', ' ')} — Inactive ⛔';
        });
        _autoStopTimer?.cancel();
        if (status == 'stopped' || status == 'none') _clearCache();
      }
    }, onError: (e) => debugPrint('Session listener: $e'));
  }

  Future<void> _sendAttendanceNotification(
      {required bool isStarting}) async {
    try {
      if (selectedDept == null ||
          selectedSem  == null ||
          selectedShift == null) return;
      final subject = _subjectController.text.trim();
      await OneSignalService.sendToSpecific(
        title: isStarting
            ? '📋 Attendance Started'
            : '⛔ Attendance Closed',
        body: isStarting
            ? 'Attendance is now open for $subject. Mark now!'
            : 'Attendance for $subject has been closed by $_facultyName.',
        dept: selectedDept!, sem: selectedSem!, shift: selectedShift!,
        data: {
          'type'        : isStarting ? 'attendance_started' : 'attendance_stopped',
          'subject'     : subject,
          'faculty'     : _facultyName,
          'sessionPath' : _currentSessionPath,
        },
      );
    } catch (e) { debugPrint('OneSignal: $e'); }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(isError ? Icons.error_outline : Icons.info_outline,
            color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(msg,
            style: const TextStyle(color: Colors.white,
                fontWeight: FontWeight.w500))),
      ]),
      backgroundColor: isError
          ? Colors.red.shade700
          : const Color(0xFF8B0A1A),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(12),
      duration: const Duration(seconds: 4),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        margin: const EdgeInsets.fromLTRB(18, 27, 18, 20),
        decoration: BoxDecoration(
          color: const Color(0xFFFDF2F3),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFFFBC02D), width: 2.5),
          boxShadow: [BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 20, offset: const Offset(0, 6))],
        ),
        child: Column(children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Row(children: [
              Container(width: 4, height: 24,
                  decoration: BoxDecoration(
                      color: const Color(0xFF8B0A1A),
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 12),
              const Text('Attendance Control',
                  style: TextStyle(fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF8B0A1A))),
              const Spacer(),
              // Marking absent indicator
              if (_isMarkingAbsent)
                Row(children: [
                  const SizedBox(width: 12, height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF8B0A1A))),
                  const SizedBox(width: 6),
                  Text('Marking absent...',
                      style: TextStyle(fontSize: 11,
                          color: Colors.grey[600])),
                ]),
            ]),
          ),
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatusCard(),    const SizedBox(height: 16),
                _buildClassCard(),     const SizedBox(height: 16),
                _buildLectureCard(),   const SizedBox(height: 16),
                _buildAreaCard(),      const SizedBox(height: 20),
                _buildActionButtons(), const SizedBox(height: 20),
              ],
            ),
          )),
        ]),
      ),
    );
  }

  Widget _buildStatusCard() => _buildCard(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('📍 Current Status',
          style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8B0A1A))),
      const SizedBox(height: 8),
      Text(_statusText,
          style: const TextStyle(fontSize: 13.5,
              color: Color(0xFF8B0A1A),
              fontWeight: FontWeight.w600)),
      if (_accuracyText.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(_accuracyText,
            style: const TextStyle(fontSize: 11,
                color: Color(0xFF8B6914))),
      ],
    ],
  ));

  Widget _buildClassCard() => _buildCard(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('🎓 Class Selection',
          style: TextStyle(fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF333333))),
      const SizedBox(height: 12),
      _buildDropdown('🏢 Department', selectedDept, departments,
          (v) => setState(() => selectedDept = v)),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _buildDropdown('📝 Semester',
            selectedSem, semesters,
            (v) => setState(() => selectedSem = v))),
        const SizedBox(width: 10),
        Expanded(child: _buildDropdown('🕒 Shift',
            selectedShift, shifts,
            (v) => setState(() => selectedShift = v))),
      ]),
    ],
  ));

  Widget _buildLectureCard() => _buildCard(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Lecture Details',
          style: TextStyle(fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8B0A1A))),
      const SizedBox(height: 12),
      const Text('📚 Subject Name',
          style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8B0A1A))),
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
          style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8B0A1A))),
      const SizedBox(height: 4),
      Text(_facultyName,
          style: const TextStyle(fontSize: 14,
              color: Color(0xFF666666))),
    ],
  ));

  Widget _buildAreaCard() => _buildCard(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Attendance Area',
          style: TextStyle(fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8B0A1A))),
      const SizedBox(height: 10),
      _buildDropdown('📐 Radius (meters)',
          selectedRadius, radii,
          (v) => setState(() => selectedRadius = v)),
    ],
  ));

  Widget _buildActionButtons() => Column(children: [
    _buildButton(
        label: '📍 Set Location',
        onPressed: _isLoading ? null : _handleSetLocation,
        isLoading: _isLoading),
    const SizedBox(height: 10),
    if (!_isSessionActive)
      _buildButton(
          label: '▶️ Start Attendance',
          onPressed: _isLocationSet ? _startAttendance : null)
    else
      _buildButton(
          label: '⏹️ Stop Attendance',
          onPressed: _isMarkingAbsent ? null : _stopAttendance,
          backgroundColor: const Color(0xFF2C2C2C)),
    const SizedBox(height: 10),
    if (_isSessionActive || _isLocationSet)
      _buildButton(
        label: '👁️ View Attendance',
        onPressed: () {
          if (_currentSessionPath.isEmpty) {
            _showSnack('No active session. Set location first.');
            return;
          }
          Navigator.push(context, MaterialPageRoute(
              builder: (_) => const FacultyViewAttendance()));
        },
      ),
  ]);

  Widget _buildCard({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 6, offset: const Offset(0, 2))],
    ),
    child: child,
  );

  Widget _buildDropdown(String label, String? value,
      List<String> items, ValueChanged<String?> onChanged) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(
            fontSize: 11, fontWeight: FontWeight.bold,
            color: Color(0xFF8B0A1A))),
        DropdownButtonFormField<String>(
          value: value,
          decoration: const InputDecoration(
              border: InputBorder.none, isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 4)),
          hint: const Text('Select',
              style: TextStyle(fontSize: 13)),
          items: items.map((e) => DropdownMenuItem(
              value: e,
              child: Text(e,
                  style: const TextStyle(fontSize: 13)))).toList(),
          onChanged: onChanged,
        ),
        Divider(color: Colors.grey.shade200, height: 1),
      ]);

  Widget _buildButton({
    required String label,
    required VoidCallback? onPressed,
    bool isLoading = false,
    Color backgroundColor = const Color(0xFF8B0A1A),
  }) =>
      SizedBox(
        width: double.infinity, height: 58,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: onPressed == null
                ? Colors.grey.shade400 : backgroundColor,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30)),
            elevation: 4,
          ),
          child: isLoading
              ? const SizedBox(width: 22, height: 22,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : Text(label,
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 15)),
        ),
      );
}