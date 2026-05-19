// lib/services/face_service.dart
//
// FIXES:
//  1. "Bad state: failed precondition" — interpreter null check before every run
//  2. Interpreter recreated fresh if closed/null (no stale state)
//  3. extractEmbeddingFromImage is synchronous — no async timing issues
//  4. Multi-angle average utility added for signup

import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'face_service_platform.dart';
import 'error_handler.dart';

const int kFaceInputSize = 112;
const int kEmbeddingDim  = 192;
const double kSimilarityThreshold = 0.72; // slightly lower for real world

class FaceService {
  FaceService._();
  static FaceService? _instance;
  static FaceService get instance => _instance ??= FaceService._();

  dynamic _interpreter;
  String? _loadedAsset;
  bool get isReady => _interpreter != null;

  // ── Init ──────────────────────────────────────────────────────────────────
  Future<void> init({
    String assetPath = 'assets/models/mobilefacenet.tflite',
  }) async {
    if (_interpreter != null && _loadedAsset == assetPath) return;
    try {
      // Always close old one first
      try { (_interpreter as dynamic)?.close(); } catch (_) {}
      _interpreter = null;

      _interpreter  = await loadInterpreter(assetPath, 2); // 2 threads
      _loadedAsset  = assetPath;
      print('FaceService: Model loaded OK from $assetPath');
    } catch (e) {
      _interpreter = null;
      print('FaceService init error: $e');
      throw AttendanceException(
        AttendanceErrorCode.modelNotLoaded,
        'Face model could not be loaded.',
        cause: e,
      );
    }
  }

  void closeModel() {
    try { (_interpreter as dynamic)?.close(); } catch (_) {}
    _interpreter = null;
    _loadedAsset  = null;
  }

  // ── Embedding from decoded still image ────────────────────────────────────
  // FIX: checks interpreter state before every call
  List<double> extractEmbeddingFromImage(img.Image image) {
    if (_interpreter == null) {
      throw const AttendanceException(
        AttendanceErrorCode.modelNotLoaded,
        'Model not loaded. Call init() first.',
      );
    }

    final resized = img.copyResize(
      image,
      width: kFaceInputSize,
      height: kFaceInputSize,
      interpolation: img.Interpolation.linear,
    );

    // Build input [1][112][112][3] — same as signup
    final input = List.generate(1, (_) =>
      List.generate(kFaceInputSize, (y) =>
        List.generate(kFaceInputSize, (x) =>
          List.generate(3, (c) {
            final p = resized.getPixel(x, y);
            if (c == 0) return (p.r - 127.5) / 127.5;
            if (c == 1) return (p.g - 127.5) / 127.5;
            return (p.b - 127.5) / 127.5;
          })
        )
      )
    );

    final output = List.generate(1, (_) => List.filled(kEmbeddingDim, 0.0));

    try {
      executeInference(_interpreter!, input, output);
    } catch (e) {
      // FIX: reset interpreter on bad state so next attempt reloads fresh
      print('Inference error — resetting interpreter: $e');
      try { (_interpreter as dynamic)?.close(); } catch (_) {}
      _interpreter = null;
      throw AttendanceException(
        AttendanceErrorCode.embeddingExtractionFailed,
        'Inference failed. Please try again.',
        cause: e,
      );
    }

    return List<double>.from(output[0]);
  }

  // ── Average embedding from multiple images (for signup) ───────────────────
  // Takes list of decoded images, extracts embedding from each, averages them
  // This improves matching accuracy significantly
  List<double> averageEmbeddings(List<img.Image> images) {
    if (images.isEmpty) return List.filled(kEmbeddingDim, 0.0);

    final embeddings = <List<double>>[];
    for (final image in images) {
      try {
        embeddings.add(extractEmbeddingFromImage(image));
      } catch (e) {
        print('Skipping image in average: $e');
      }
    }

    if (embeddings.isEmpty) return List.filled(kEmbeddingDim, 0.0);

    // Average each dimension
    final avg = List<double>.filled(kEmbeddingDim, 0.0);
    for (final e in embeddings) {
      for (int i = 0; i < kEmbeddingDim; i++) {
        avg[i] += e[i];
      }
    }
    for (int i = 0; i < kEmbeddingDim; i++) {
      avg[i] /= embeddings.length;
    }

    // L2 normalize the average
    return _l2Normalize(avg);
  }

  List<double> _l2Normalize(List<double> v) {
    final norm = math.sqrt(v.fold(0.0, (s, x) => s + x * x));
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }

  // ── Embedding from CameraImage (kept for compatibility) ───────────────────
  Future<List<double>> extractEmbedding(
      CameraImage cameraImage, Face face) async {
    final rgb     = _nv21ToRgb(cameraImage);
    final cropped = _cropFace(rgb, face);
    if (cropped == null) {
      throw const AttendanceException(
        AttendanceErrorCode.embeddingExtractionFailed,
        'Face region too small.',
      );
    }
    return extractEmbeddingFromImage(cropped);
  }

  // ── Cosine similarity ─────────────────────────────────────────────────────
  double cosineSimilarity(List<double> e1, List<double> e2) {
    if (e1.length != e2.length) return 0.0;
    double dot = 0, n1 = 0, n2 = 0;
    for (int i = 0; i < e1.length; i++) {
      dot += e1[i] * e2[i];
      n1  += e1[i] * e1[i];
      n2  += e2[i] * e2[i];
    }
    final denom = math.sqrt(n1) * math.sqrt(n2);
    if (denom == 0) return 0.0;
    return (dot / denom + 1.0) / 2.0;
  }

  // ── Parse faceData string from Firestore ──────────────────────────────────
  List<double> parseStoredEmbedding(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      return raw.split(',').map((s) => double.parse(s.trim())).toList();
    } catch (_) {
      return [];
    }
  }

  // ── NV21 → RGB ────────────────────────────────────────────────────────────
  img.Image _nv21ToRgb(CameraImage c) {
    final w = c.width, h = c.height;
    final y = c.planes[0].bytes, uv = c.planes[1].bytes;
    final out = img.Image(width: w, height: h);
    for (int row = 0; row < h; row++) {
      for (int col = 0; col < w; col++) {
        final yV  = y[row * w + col] & 0xFF;
        final idx = (row ~/ 2) * w + (col ~/ 2) * 2;
        final vV  = idx < uv.length       ? (uv[idx] & 0xFF) - 128     : 0;
        final uV  = (idx + 1) < uv.length ? (uv[idx + 1] & 0xFF) - 128 : 0;
        out.setPixelRgb(col, row,
          (yV + 1.370705 * vV).round().clamp(0, 255),
          (yV - 0.698001 * vV - 0.337633 * uV).round().clamp(0, 255),
          (yV + 1.732446 * uV).round().clamp(0, 255),
        );
      }
    }
    return out;
  }

  img.Image? _cropFace(img.Image src, Face face) {
    final b = face.boundingBox;
    final L = (b.left   - b.width  * 0.2).clamp(0.0, src.width  - 1.0).toInt();
    final T = (b.top    - b.height * 0.2).clamp(0.0, src.height - 1.0).toInt();
    final R = (b.right  + b.width  * 0.2).clamp(0.0, src.width  - 1.0).toInt();
    final B = (b.bottom + b.height * 0.2).clamp(0.0, src.height - 1.0).toInt();
    if (R - L < 10 || B - T < 10) return null;
    return img.copyCrop(src, x: L, y: T, width: R - L, height: B - T);
  }
}