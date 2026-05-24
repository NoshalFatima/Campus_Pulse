// lib/Student/face_capture_screen.dart
//
// Manual face capture — user taps the capture button 5 times.
// No auto-detection stream = no RangeError, no blocking, no "move closer" loop.
// Works exactly like Android screen lock face enrollment.

import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'dart:math' show pi;
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/face_service.dart';

const int    kRequiredCaptures = 5;
const Color  kPrimary          = Color(0xFF8B0A1A);

class FaceCaptureScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const FaceCaptureScreen({super.key, required this.cameras});

  @override
  State<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends State<FaceCaptureScreen> {
  CameraController? _ctrl;
  bool _cameraReady  = false;
  bool _processing   = false;   // true while a single capture is running
  bool _done         = false;   // true after all 5 captured & embedding computed

  int                 _count   = 0;
  final List<img.Image> _faces = [];
  Uint8List?          _lastThumb;
  String              _status  = 'Position your face inside the circle\nthen tap Capture';

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    // Prefer front camera
    final cam = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => widget.cameras.first,
    );
    _ctrl = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      // YUV420 is more universally supported — avoids NV21 plane RangeError
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await _ctrl!.initialize();
      if (mounted) setState(() => _cameraReady = true);
    } catch (e) {
      if (mounted) setState(() => _status = 'Camera error: $e');
    }
  }

  // ── Called when user taps the capture button ────────────────
  Future<void> _captureOne() async {
    if (_processing || _done || !_cameraReady) return;
    if (_ctrl == null || !_ctrl!.value.isInitialized) return;

    setState(() {
      _processing = true;
      _status     = 'Capturing ${_count + 1}/$kRequiredCaptures...';
    });

    try {
      // Take a still picture — avoids raw plane indexing entirely
      final xFile = await _ctrl!.takePicture();
      final bytes = await xFile.readAsBytes();

      // Decode raw JPEG
      final rawDecoded = img.decodeImage(bytes);
      if (rawDecoded == null) throw Exception('Could not decode image');

      // MLKit on raw file — bbox coords are in raw image space
      final inputImage = InputImage.fromFilePath(xFile.path);
      final detector   = FaceDetector(
        options: FaceDetectorOptions(minFaceSize: 0.15),
      );
      final faces = await detector.processImage(inputImage);
      await detector.close();

      if (faces.isEmpty) {
        setState(() {
          _processing = false;
          _status     = 'No face found — make sure your face\nis clearly visible and try again';
        });
        return;
      }

      // KEY FIX: crop from RAW image first (MLKit coords match raw)
      // then bakeOrientation on cropped face only
      final face    = faces.first;
      final rawCrop = _cropFace(rawDecoded, face);
      if (rawCrop == null) {
        setState(() {
          _processing = false;
          _status     = 'Face too small — move closer and try again';
        });
        return;
      }
      final cropped = img.bakeOrientation(rawCrop);
      // dummy to satisfy null check below
      final _ = cropped;
      // null check already done above

      _faces.add(cropped);
      _count++;

      // Thumbnail for UI
      final thumb = img.copyResize(cropped, width: 80, height: 80);
      _lastThumb  = Uint8List.fromList(img.encodeJpg(thumb, quality: 75));

      if (_count >= kRequiredCaptures) {
        // All captures done — compute average embedding
        setState(() => _status = 'Processing face data...');
        if (!FaceService.instance.isReady) await FaceService.instance.init();
        final embedding = FaceService.instance.averageEmbeddings(_faces);

        setState(() {
          _done    = true;
          _status  = 'Face enrolled successfully!';
        });

        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) {
          Navigator.of(context).pop({
            'embedding':    embedding,
            'previewBytes': _lastThumb,
          });
        }
      } else {
        setState(() {
          _processing = false;
          _status     = 'Good! Tap Capture again\n(${_count}/$kRequiredCaptures done)';
        });
      }
    } catch (e) {
      debugPrint('Capture error: $e');
      setState(() {
        _processing = false;
        _status     = 'Error capturing — please try again';
      });
    }
  }

  img.Image? _cropFace(img.Image src, Face face) {
    final b = face.boundingBox;
    final L = (b.left   - b.width  * 0.2).clamp(0.0, src.width  - 1.0).toInt();
    final T = (b.top    - b.height * 0.2).clamp(0.0, src.height - 1.0).toInt();
    final R = (b.right  + b.width  * 0.2).clamp(0.0, src.width  - 1.0).toInt();
    final B = (b.bottom + b.height * 0.2).clamp(0.0, src.height - 1.0).toInt();
    if (R - L < 20 || B - T < 20) return null;
    return img.copyCrop(src, x: L, y: T, width: R - L, height: B - T);
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [

        // ── Camera preview ──────────────────────────────────
        if (_cameraReady && _ctrl != null)
          CameraPreview(_ctrl!)
        else
          const Center(child: CircularProgressIndicator(color: kPrimary)),

        // ── Dark oval overlay ───────────────────────────────
        CustomPaint(
          painter: _OvalOverlayPainter(
            progress: _count / kRequiredCaptures,
            done: _done,
          ),
        ),

        // ── Top bar ─────────────────────────────────────────
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Close
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(null),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.close, color: Colors.white, size: 22),
                    ),
                  ),
                  // Title
                  const Text('Face Enrollment',
                    style: TextStyle(color: Colors.white, fontSize: 16,
                        fontWeight: FontWeight.bold)),
                  // Last captured thumb
                  if (_lastThumb != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(_lastThumb!,
                          width: 44, height: 44, fit: BoxFit.cover),
                    )
                  else
                    const SizedBox(width: 44),
                ],
              ),
            ),
          ),
        ),

        // ── Bottom panel ────────────────────────────────────
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [

              // Dot progress indicators
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(kRequiredCaptures, (i) {
                  final filled = i < _count;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width:  filled ? 16 : 10,
                    height: filled ? 16 : 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? kPrimary : Colors.white30,
                      boxShadow: filled ? [BoxShadow(
                        color: kPrimary.withOpacity(0.5),
                        blurRadius: 6,
                      )] : null,
                    ),
                  );
                }),
              ),

              const SizedBox(height: 16),

              // Status text
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _status,
                  key: ValueKey(_status),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white, fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Capture button  — big round button like screen lock
              _done
                ? const Icon(Icons.check_circle_rounded,
                    color: Colors.green, size: 64)
                : GestureDetector(
                    onTap: _processing ? null : _captureOne,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width:  _processing ? 68 : 76,
                      height: _processing ? 68 : 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _processing
                            ? Colors.white24
                            : Colors.white,
                        border: Border.all(color: kPrimary, width: 4),
                        boxShadow: [BoxShadow(
                          color: kPrimary.withOpacity(0.4),
                          blurRadius: 16,
                        )],
                      ),
                      child: _processing
                          ? const Padding(
                              padding: EdgeInsets.all(18),
                              child: CircularProgressIndicator(
                                  strokeWidth: 3, color: kPrimary),
                            )
                          : const Icon(Icons.camera_alt_rounded,
                              color: kPrimary, size: 32),
                    ),
                  ),

              const SizedBox(height: 12),

              if (!_done && !_processing)
                Text('Tap the button to capture',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ── Oval overlay painter ────────────────────────────────────────
class _OvalOverlayPainter extends CustomPainter {
  final double progress;
  final bool   done;
  const _OvalOverlayPainter({required this.progress, required this.done});

  @override
  void paint(Canvas canvas, Size size) {
    final cx   = size.width / 2;
    final cy   = size.height * 0.40;
    final oval = Rect.fromCenter(
      center: Offset(cx, cy),
      width:  size.width  * 0.74,
      height: size.height * 0.52,
    );

    // Dark surround
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(oval)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withOpacity(0.55));

    // Idle ring
    canvas.drawOval(oval,
      Paint()
        ..color = Colors.white30
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Progress arc
    if (progress > 0) {
      canvas.drawArc(
        oval.inflate(5),
        -pi / 2,
        pi * 2 * progress,
        false,
        Paint()
          ..color = done ? Colors.green : kPrimary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_OvalOverlayPainter old) =>
      old.progress != progress || old.done != done;
}