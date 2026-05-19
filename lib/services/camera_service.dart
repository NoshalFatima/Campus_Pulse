// lib/attendance/camera_service.dart
//
// Camera stream management service.
//
// Responsibilities:
//   • Enumerate cameras and select the front camera
//   • Initialize CameraController at medium resolution / NV21 format
//   • Provide image stream with built-in frame-drop protection
//   • Convert CameraImage → ML Kit InputImage
//   • Clean teardown

import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'error_handler.dart';

/// Callback type for processed camera frames.
typedef FrameCallback = Future<void> Function(CameraImage image);

class CameraService {
  CameraController? _controller;
  List<CameraDescription>? _cameras;

  /// The initialized [CameraController]; null before [init] completes.
  CameraController? get controller => _controller;

bool get isInitialized {
  try {
    return _controller != null && _controller!.value.isInitialized;
  } catch (_) {
    return false;
  }
}

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Enumerates available cameras. Call once at app startup or service creation.
  Future<void> loadCameras() async {
    try {
      _cameras = await availableCameras();
    } catch (e) {
      throw AttendanceException(
        AttendanceErrorCode.cameraInitFailed,
        'Failed to enumerate cameras.',
        cause: e,
      );
    }
  }

  /// Initialises the front camera at medium resolution with NV21 format.
  ///
  /// Throws [AttendanceException] on failure.
  Future<void> init() async {
    if (_cameras == null) await loadCameras();
    if (_cameras!.isEmpty) {
      throw const AttendanceException(
        AttendanceErrorCode.cameraInitFailed,
        'No cameras found on this device.',
      );
    }

    final front = _cameras!.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras!.first,
    );

    try {
      _controller = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await _controller!.initialize();
    } catch (e) {
      throw AttendanceException(
        AttendanceErrorCode.cameraInitFailed,
        'Camera initialization failed.',
        cause: e,
      );
    }
  }

  // ── Stream ─────────────────────────────────────────────────────────────────

  /// Starts the image stream, calling [onFrame] for each frame.
  ///
  /// Built-in frame-drop protection:
  ///   • [minIntervalMs] — minimum milliseconds between processed frames
  ///     (defaults to 250 ms → ~4 fps processing regardless of camera fps).
  ///   • [_busy] flag prevents concurrent async frame processing.
  ///
  /// Throws [AttendanceException] if the controller is not initialized.
  void startStream(
    FrameCallback onFrame, {
    int minIntervalMs = 250,
  }) {
    if (!isInitialized) {
      throw const AttendanceException(
        AttendanceErrorCode.cameraInitFailed,
        'Camera is not initialized. Call init() first.',
      );
    }

    bool busy = false;
    int lastMs = 0;

    _controller!.startImageStream((CameraImage image) async {
      // ── Rate limiter ───────────────────────────────────────────────
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastMs < minIntervalMs) return;

      // ── Concurrency guard ──────────────────────────────────────────
      if (busy) return;
      busy = true;
      lastMs = now;

      try {
        await onFrame(image);
      } catch (e) {
        debugPrint('[CameraService] Frame callback error: $e');
      } finally {
        busy = false;
      }
    });
  }

  /// Stops the image stream without disposing the controller.
  Future<void> stopStream() async {
    try {
      if (_controller?.value.isStreamingImages ?? false) {
        await _controller!.stopImageStream();
      }
    } catch (e) {
      debugPrint('[CameraService] stopStream error: $e');
    }
  }

  /// Stops the stream and fully disposes the controller.
  Future<void> dispose() async {
  final ctrl = _controller;
  _controller = null; // Pehle null karo
  try {
    if (ctrl?.value.isStreamingImages ?? false) {
      await ctrl!.stopImageStream();
    }
  } catch (_) {}
  try {
    await ctrl?.dispose();
  } catch (_) {}
}
  // ── ML Kit conversion ──────────────────────────────────────────────────────

  /// Converts a [CameraImage] (NV21) to a [InputImage] for ML Kit.
  /// Returns null if the camera list or format metadata is unavailable.
  InputImage? toInputImage(CameraImage image) {
    if (_cameras == null || _cameras!.isEmpty) return null;
    try {
      final camera = _cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras!.first,
      );

      final rotation =
          InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
              InputImageRotation.rotation0deg;

      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;

      final bytes = Uint8List.fromList(
        image.planes.expand((p) => p.bytes).toList(),
      );

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      debugPrint('[CameraService] toInputImage error: $e');
      return null;
    }
  }
}