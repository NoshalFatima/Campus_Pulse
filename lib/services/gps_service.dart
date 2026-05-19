// lib/attendance/gps_service.dart
//
// GPS validation service for the attendance pipeline.
//
// Security gates (all must pass):
//   1. Location services enabled
//   2. Permission granted
//   3. position.isMocked == false   ← fake-GPS detection
//   4. position.accuracy ≤ 30 m     ← weak-fix rejection
//   5. distance ≤ teacher radius    ← geo-fence

import 'package:geolocator/geolocator.dart';
import 'error_handler.dart';

/// Result returned by a successful GPS validation.
class GpsValidationResult {
  const GpsValidationResult({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.distanceMetres,
  });

  final double latitude;
  final double longitude;

  /// Horizontal accuracy of the fix in metres.
  final double accuracy;

  /// Distance to the teacher/session anchor point in metres.
  final double distanceMetres;
}

class GpsService {
  // ── Constants ─────────────────────────────────────────────────────────────
  static const double _maxAccuracyMetres = 30.0;
  static const Duration _positionTimeout = Duration(seconds: 15);

  /// Validates the student's current position against the session anchor.
  ///
  /// [teacherLat] / [teacherLon] — anchor coordinates from RTDB session node.
  /// [allowedRadiusMetres]       — geo-fence radius from RTDB session node.
  ///
  /// Returns [GpsValidationResult] on success.
  /// Throws [AttendanceException] on any security or hardware failure.
  Future<GpsValidationResult> validate({
    required double teacherLat,
    required double teacherLon,
    required double allowedRadiusMetres,
  }) async {
    return AttendanceErrorHandler.guard(() async {
      // ── 1. Services enabled ────────────────────────────────────────────
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw const AttendanceException(
          AttendanceErrorCode.locationServiceDisabled,
          'GPS is disabled. Enable Location (High Accuracy mode) and retry.',
        );
      }

      // ── 2. Permission ──────────────────────────────────────────────────
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw const AttendanceException(
          AttendanceErrorCode.locationPermissionDenied,
          'Location permission is required for attendance.',
        );
      }

      // ── 3. Obtain fix (with timeout) ───────────────────────────────────
      late Position position;
      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
        ).timeout(_positionTimeout);
      } catch (e) {
        throw AttendanceException(
          AttendanceErrorCode.locationTimeout,
          'GPS timed out. Move to an open area and retry.',
          cause: e,
        );
      }

      // ── 4. [SECURITY] Mock / fake GPS detection ────────────────────────
      if (position.isMocked) {
        throw const AttendanceException(
          AttendanceErrorCode.locationMocked,
          '⚠️ Mock location detected. Disable any fake-GPS app and retry.',
        );
      }

      // ── 5. [SECURITY] Accuracy gate ────────────────────────────────────
      if (position.accuracy > _maxAccuracyMetres) {
        throw AttendanceException(
          AttendanceErrorCode.locationAccuracyTooLow,
          'GPS accuracy is too low (${position.accuracy.toStringAsFixed(0)} m). '
          'Enable High Accuracy mode and retry.',
        );
      }

      // ── 6. [SECURITY] Geo-fence distance check ─────────────────────────
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        teacherLat,
        teacherLon,
      );

      if (distance > allowedRadiusMetres) {
        throw AttendanceException(
          AttendanceErrorCode.locationOutOfRange,
          'You are ${distance.toStringAsFixed(0)} m from the classroom '
          '(limit: ${allowedRadiusMetres.toStringAsFixed(0)} m).',
        );
      }

      return GpsValidationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        distanceMetres: distance,
      );
    });
  }
}