// lib/attendance/liveness_service.dart
//
// Liveness detection service.
//
// Primary check  : ML Kit eye-blink classification
//                  (leftEyeOpenProbability / rightEyeOpenProbability < 0.30)
//
// Anti-spoofing fallback (secondary):
//   • Brightness check — image mean luminance must be in [40, 220]
//     (too dark → shadowed face / blank screen; too bright → photo held up)
//   • Face-size check  — bounding-box area must be ≥ 10 % of frame area
//     (tiny / distant face rejected to prevent printed-photo attacks)

import 'dart:typed_data';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:camera/camera.dart';
import 'error_handler.dart';

/// Result of a single liveness frame evaluation.
class LivenessFrameResult {
  const LivenessFrameResult({
    required this.blinkDetected,
    required this.passedAntiSpoof,
    required this.leftEyeOpen,
    required this.rightEyeOpen,
    required this.brightnessScore,
    required this.faceSizeRatio,
  });

  final bool blinkDetected;
  final bool passedAntiSpoof;
  final double leftEyeOpen;
  final double rightEyeOpen;

  /// Mean Y-plane luminance in [0, 255].
  final double brightnessScore;

  /// Face bounding-box area / frame area (0–1).
  final double faceSizeRatio;
}

class LivenessService {
  // ── Blink thresholds ──────────────────────────────────────────────────────
  static const double _eyeClosedThreshold = 0.30;

  // ── Anti-spoofing thresholds ──────────────────────────────────────────────
  static const double _minBrightness = 40.0;
  static const double _maxBrightness = 220.0;
  static const double _minFaceSizeRatio = 0.10; // face must be ≥ 10% of frame

  bool _blinkConfirmed = false;

  /// Whether liveness has been confirmed in this session.
  bool get isLivenessConfirmed => _blinkConfirmed;

  /// Resets liveness state — call when starting a new verification attempt.
  void reset() => _blinkConfirmed = false;

  /// Evaluates a single camera frame for liveness and anti-spoofing.
  ///
  /// [image]   — raw NV21 camera frame (Y-plane used for brightness).
  /// [face]    — ML Kit [Face] with classification enabled.
  ///
  /// Returns [LivenessFrameResult] — never throws; caller decides action.
  LivenessFrameResult evaluate(CameraImage image, Face face) {
    // ── Eye-blink classification ───────────────────────────────────────────
    final leftOpen = face.leftEyeOpenProbability ?? 1.0;
    final rightOpen = face.rightEyeOpenProbability ?? 1.0;
    final blinkNow = leftOpen < _eyeClosedThreshold || rightOpen < _eyeClosedThreshold;
    if (blinkNow) _blinkConfirmed = true;

    // ── Anti-spoofing: brightness ──────────────────────────────────────────
    final brightness = _computeMeanBrightness(image);
    final brightnessOk =
        brightness >= _minBrightness && brightness <= _maxBrightness;

    // ── Anti-spoofing: face size ───────────────────────────────────────────
    final frameArea = image.width * image.height;
    final bbox = face.boundingBox;
    final faceArea = bbox.width * bbox.height;
    final faceSizeRatio = frameArea > 0 ? faceArea / frameArea : 0.0;
    final faceSizeOk = faceSizeRatio >= _minFaceSizeRatio;

    final passedAntiSpoof = brightnessOk && faceSizeOk;

    return LivenessFrameResult(
      blinkDetected: blinkNow,
      passedAntiSpoof: passedAntiSpoof,
      leftEyeOpen: leftOpen,
      rightEyeOpen: rightOpen,
      brightnessScore: brightness,
      faceSizeRatio: faceSizeRatio,
    );
  }

  /// Computes the mean luminance from the NV21 Y-plane.
  /// Fast — samples every 8th pixel to reduce CPU load.
  double _computeMeanBrightness(CameraImage image) {
    try {
      final Uint8List yPlane = image.planes[0].bytes;
      final int total = yPlane.length;
      if (total == 0) return 128.0;

      double sum = 0;
      int count = 0;
      const int step = 8; // sample every 8th byte → ~12× faster than full scan
      for (int i = 0; i < total; i += step) {
        sum += yPlane[i] & 0xFF;
        count++;
      }
      return count > 0 ? sum / count : 128.0;
    } catch (_) {
      return 128.0; // neutral fallback
    }
  }

  /// Validates the anti-spoof result and throws [AttendanceException] if
  /// the frame should be rejected due to a spoofing signal.
  ///
  /// Call this after [evaluate] in the main verification pipeline if you want
  /// hard rejection (vs. soft warning).
  void assertAntiSpoof(LivenessFrameResult result) {
    if (!result.passedAntiSpoof) {
      throw AttendanceException(
        AttendanceErrorCode.spoofingDetected,
        result.brightnessScore < _minBrightness
            ? 'Too dark — improve lighting and try again.'
            : result.brightnessScore > _maxBrightness
                ? 'Too bright — avoid direct light behind you.'
                : 'Face too small or far from camera — move closer.',
      );
    }
  }
}