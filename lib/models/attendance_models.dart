// ✅ lib/models/attendance_models.dart
// All attendance-related data models

class AttendanceSession {
  final String sessionPath;
  final double latitude;
  final double longitude;
  final double locationAccuracy;
  final double radiusMeters;
  final String department;
  final String semester;
  final String shift;
  final String subjectName;
  final String facultyName;
  final String status; // "set" | "allowed" | "stopped"
  final int timestamp;

  AttendanceSession({
    required this.sessionPath,
    required this.latitude,
    required this.longitude,
    required this.locationAccuracy,
    required this.radiusMeters,
    required this.department,
    required this.semester,
    required this.shift,
    required this.subjectName,
    required this.facultyName,
    required this.status,
    required this.timestamp,
  });

  factory AttendanceSession.fromMap(Map<dynamic, dynamic> map) {
    return AttendanceSession(
      sessionPath: '',
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
      locationAccuracy: (map['locationAccuracy'] as num?)?.toDouble() ?? 0.0,
      radiusMeters: (map['radiusMeters'] as num?)?.toDouble() ?? 20.0,
      department: map['department']?.toString() ?? '',
      semester: map['semester']?.toString() ?? '',
      shift: map['shift']?.toString() ?? '',
      subjectName: map['subjectName']?.toString() ?? '',
      facultyName: map['facultyName']?.toString() ?? '',
      status: map['status']?.toString() ?? 'set',
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'latitude': latitude,
        'longitude': longitude,
        'locationAccuracy': locationAccuracy,
        'radiusMeters': radiusMeters,
        'department': department,
        'semester': semester,
        'shift': shift,
        'subjectName': subjectName,
        'facultyName': facultyName,
        'status': status,
        'timestamp': timestamp,
      };
}

class AttendanceRecord {
  final String studentUid;
  final String studentName;
  final String status; // "Present" | "Absent"
  final int timestamp;
  final String verification;

  AttendanceRecord({
    required this.studentUid,
    required this.studentName,
    required this.status,
    required this.timestamp,
    this.verification = 'Face+GPS',
  });

  factory AttendanceRecord.fromMap(Map<dynamic, dynamic> map, String uid) {
    return AttendanceRecord(
      studentUid: uid,
      studentName: '',
      status: map['status']?.toString() ?? 'Absent',
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      verification: map['verification']?.toString() ?? 'Face+GPS',
    );
  }

  Map<String, dynamic> toMap() => {
        'status': status,
        'timestamp': timestamp,
        'verification': verification,
      };
}

// Monthly report model — per student per date
class MonthlyReport {
  final String uid;
  final String name;
  final Map<String, String> dateStatus; // date -> "P" or "A"

  MonthlyReport({
    required this.uid,
    required this.name,
    required this.dateStatus,
  });

  int get presentCount => dateStatus.values.where((s) => s == 'P').length;
  int get totalDays => dateStatus.length;
  double get percentage =>
      totalDays > 0 ? (presentCount / totalDays) * 100 : 0.0;
}