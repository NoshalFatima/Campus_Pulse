// lib/services/error_handler.dart
//
// CHANGE: Sirf missing error codes add kiye enum mein:
//   sessionNotActive, sessionExpired, classMismatch,
//   lowGpsAccuracy, locationError, cameraError
// displayTitle mein bhi inke cases add kiye.
// Baaki sab ORIGINAL SAME hai.

/// Enumeration of every possible failure domain in the attendance pipeline.
enum AttendanceErrorCode {
  // ── Model / ML ────────────────────────────────────────────────────────────
  modelNotLoaded,
  embeddingExtractionFailed,
  faceNotDetected,

  // ── Liveness ──────────────────────────────────────────────────────────────
  livenessTimeout,
  spoofingDetected,

  // ── GPS ───────────────────────────────────────────────────────────────────
  locationServiceDisabled,
  locationPermissionDenied,
  locationMocked,
  locationAccuracyTooLow,
  locationOutOfRange,
  locationTimeout,
  lowGpsAccuracy,   // NEW: non-fatal low accuracy (user can proceed)
  locationError,    // NEW: generic GPS error

  // ── Firebase / Session ────────────────────────────────────────────────────
  sessionNotFound,
  sessionClosed,
  sessionNotActive, // NEW: session exists but status != 'allowed'
  sessionExpired,   // NEW: teacher stopped session mid-verification
  classMismatch,    // NEW: student dept/sem/shift != session dept/sem/shift
  profileNotFound,
  faceDataMissing,
  duplicateAttendance,
  uploadFailed,
  transactionFailed,

  // ── Camera ────────────────────────────────────────────────────────────────
  cameraPermissionDenied,
  cameraInitFailed,
  cameraStreamFailed,
  cameraError,      // NEW: generic camera error

  // ── Generic ───────────────────────────────────────────────────────────────
  unknown,
  sessionTimeout,
}

/// Typed exception thrown by every service in the attendance pipeline.
class AttendanceException implements Exception {
  const AttendanceException(this.code, this.message, {this.cause});

  final AttendanceErrorCode code;
  final String message;
  final Object? cause;

  /// Whether the user can retry after seeing this error.
  bool get isRetryable => const {
        AttendanceErrorCode.locationAccuracyTooLow,
        AttendanceErrorCode.lowGpsAccuracy,       // NEW
        AttendanceErrorCode.locationError,         // NEW
        AttendanceErrorCode.locationTimeout,
        AttendanceErrorCode.faceNotDetected,
        AttendanceErrorCode.embeddingExtractionFailed,
        AttendanceErrorCode.cameraStreamFailed,
        AttendanceErrorCode.cameraError,           // NEW
        AttendanceErrorCode.livenessTimeout,
        AttendanceErrorCode.uploadFailed,
      }.contains(code);

  /// Human-readable title shown in the status card.
  String get displayTitle {
    switch (code) {
      case AttendanceErrorCode.modelNotLoaded:
        return '⚠️ System Error';
      case AttendanceErrorCode.spoofingDetected:
        return '⛔ Spoof Detected';
      case AttendanceErrorCode.locationMocked:
        return '⛔ Fake GPS Detected';
      case AttendanceErrorCode.locationOutOfRange:
        return '📍 Out of Range';
      case AttendanceErrorCode.sessionNotFound:
      case AttendanceErrorCode.sessionClosed:
        return '🔒 No Active Session';
      case AttendanceErrorCode.duplicateAttendance:
        return '✅ Already Marked';
      case AttendanceErrorCode.sessionTimeout:
        return '⏱ Session Timed Out';
      // ── NEW cases ──────────────────────────────────────────────────────
      case AttendanceErrorCode.sessionNotActive:
        return '🔒 Session Not Started';
      case AttendanceErrorCode.sessionExpired:
        return '⛔ Session Closed';
      case AttendanceErrorCode.classMismatch:
        return '❌ Wrong Class Session';
      case AttendanceErrorCode.lowGpsAccuracy:
        return '📡 Weak GPS Signal';
      case AttendanceErrorCode.locationError:
        return '📍 GPS Error';
      case AttendanceErrorCode.cameraError:
        return '📷 Camera Error';
      default:
        return '❌ Verification Failed';
    }
  }

  @override
  String toString() =>
      'AttendanceException(${code.name}): $message'
      '${cause != null ? ' [caused by: $cause]' : ''}';
}

/// Static helper — wraps any closure and converts raw exceptions into
/// [AttendanceException] with [AttendanceErrorCode.unknown].
class AttendanceErrorHandler {
  const AttendanceErrorHandler._();

  static Future<T> guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on AttendanceException {
      rethrow;
    } catch (e) {
      throw AttendanceException(
        AttendanceErrorCode.unknown,
        'Unexpected error: $e',
        cause: e,
      );
    }
  }
}