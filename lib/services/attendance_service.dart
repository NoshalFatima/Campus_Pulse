// lib/services/attendance_service.dart
//
// CHANGE: StudentProfile mein 3 fields add kiye:
//   - department, semester, shift
//   (session path pehle se tha, ye extra fields class-match check ke liye hain)
// Baaki sab ORIGINAL SAME hai.

import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';

import 'error_handler.dart';

/// Data bag holding the session details fetched from RTDB.
class SessionInfo {
  const SessionInfo({
    required this.sessionPath,
    required this.teacherLat,
    required this.teacherLon,
    required this.radiusMetres,
  });

  final String sessionPath;
  final double teacherLat;
  final double teacherLon;
  final double radiusMetres;
}

/// Data bag holding the student profile fetched from Firestore.
class StudentProfile {
  const StudentProfile({
    required this.uid,
    required this.sessionPath,
    required this.storedEmbeddingRaw,
    // ── NEW: class info fields for session match validation ──────────────
    required this.department,
    required this.semester,
    required this.shift,
  });

  final String uid;

  /// Session path derived from dept + semester + shift.
  final String sessionPath;

  /// Raw comma-separated embedding string from Firestore `faceData` field.
  final String storedEmbeddingRaw;

  // ── NEW fields ────────────────────────────────────────────────────────────
  /// e.g. "Computer Science"
  final String department;

  /// e.g. "Semester 6"
  final String semester;

  /// e.g. "Morning"
  final String shift;
}

class AttendanceService {
  AttendanceService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseDatabase? database,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _db = (database ?? FirebaseDatabase.instance).ref();

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final DatabaseReference _db;

  String? get _uid => _auth.currentUser?.uid;

  // ── Student Profile ────────────────────────────────────────────────────────

  Future<StudentProfile> fetchStudentProfile() async {
    final uid = _uid;
    if (uid == null) {
      throw const AttendanceException(
        AttendanceErrorCode.profileNotFound,
        'No authenticated user. Please sign in again.',
      );
    }

    return AttendanceErrorHandler.guard(() async {
      final doc = await _firestore.collection('Users').doc(uid).get();
      if (!doc.exists) {
        throw const AttendanceException(
          AttendanceErrorCode.profileNotFound,
          'Student profile not found. Contact support.',
        );
      }

      final data = doc.data()!;
      final dept     = data['dept']?.toString();
      final sem      = data['semester']?.toString() ?? data['sem']?.toString();
      final shift    = data['shift']?.toString();
      final faceData = data['faceData']?.toString();

      if (faceData == null || faceData.trim().isEmpty) {
        throw const AttendanceException(
          AttendanceErrorCode.faceDataMissing,
          'Face data missing. Please re-register your profile.',
        );
      }

      return StudentProfile(
        uid:               uid,
        sessionPath:       _buildSessionPath(dept, sem, shift),
        storedEmbeddingRaw: faceData,
        // ── NEW: pass through raw values for match validation ──────────
        department: dept  ?? '',
        semester:   sem   ?? '',
        shift:      shift ?? '',
      );
    });
  }

  /// "Computer Science" + "Semester 6" + "Morning" → "COMPUTER_SCIENCE_S6_MORNING"
  String _buildSessionPath(String? dept, String? sem, String? shift) {
    final deptKey  = dept?.replaceAll(' ', '_').toUpperCase() ?? '';
    final numStr   = sem?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
    final semKey   = numStr.isNotEmpty ? 'S$numStr' : '';
    final shiftKey = shift?.toUpperCase() ?? '';
    return '${deptKey}_${semKey}_$shiftKey';
  }

  // ── Session Validation ─────────────────────────────────────────────────────

  Future<SessionInfo> fetchActiveSession(String sessionPath) async {
    return AttendanceErrorHandler.guard(() async {
      final snapshot =
          await _db.child('AttendanceSession').child(sessionPath).get();

      if (!snapshot.exists) {
        throw AttendanceException(
          AttendanceErrorCode.sessionNotFound,
          'No active session for: ${sessionPath.replaceAll('_', ' ')}. '
          'Contact your teacher.',
        );
      }

      final data   = snapshot.value as Map<dynamic, dynamic>;
      final status = data['status']?.toString() ?? '';

      if (status != 'allowed') {
        throw const AttendanceException(
          AttendanceErrorCode.sessionClosed,
          'Attendance is not open yet. Wait for your teacher.',
        );
      }

      return SessionInfo(
        sessionPath:  sessionPath,
        teacherLat:   (data['latitude']     as num?)?.toDouble() ?? 0,
        teacherLon:   (data['longitude']    as num?)?.toDouble() ?? 0,
        radiusMetres: (data['radiusMeters'] as num?)?.toDouble() ?? 20,
      );
    });
  }

  // ── Duplicate Check ────────────────────────────────────────────────────────

  Future<bool> isAlreadyMarked(String sessionPath) async {
    final uid = _uid;
    if (uid == null) return false;
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final snap  = await _db
        .child('AttendanceRecords')
        .child(sessionPath)
        .child(today)
        .child(uid)
        .get();
    return snap.exists;
  }

  // ── Atomic Attendance Write ────────────────────────────────────────────────

  Future<void> markAttendance({
    required String sessionPath,
    required String uid,
  }) async {
    return AttendanceErrorHandler.guard(() async {
      final today     = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final recordRef = _db
          .child('AttendanceRecords')
          .child(sessionPath)
          .child(today)
          .child(uid);

      // Random delay (0–500 ms) — replay-attack mitigation
      final jitterMs = DateTime.now().millisecondsSinceEpoch % 500;
      await Future.delayed(Duration(milliseconds: jitterMs));

      // Atomic transaction write
      final transactionResult = await recordRef.runTransaction((current) {
        if (current != null) return Transaction.abort();
        return Transaction.success({
          'status':       'Present',
          'timestamp':    DateTime.now().millisecondsSinceEpoch,
          'verification': 'Face+GPS+Liveness',
        });
      });

      if (!transactionResult.committed) {
        throw const AttendanceException(
          AttendanceErrorCode.duplicateAttendance,
          'Attendance has already been recorded for today.',
        );
      }
    });
  }
}