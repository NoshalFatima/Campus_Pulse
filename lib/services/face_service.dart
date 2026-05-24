// lib/services/face_service.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'face_service_platform.dart';
import 'error_handler.dart';

const int    kFaceInputSize       = 112;
const int    kEmbeddingDim        = 192;
const double kSimilarityThreshold = 0.55; // lowered: L2-norm dot product range is tighter

class FaceService {
  FaceService._();
  static FaceService? _instance;
  static FaceService get instance => _instance ??= FaceService._();

  dynamic _interpreter;
  bool get isReady => kIsWeb ? true : _interpreter != null;

  Future<void> init({
    String assetPath = 'assets/models/mobilefacenet.tflite',
  }) async {
    if (kIsWeb) {
      print('ℹ️ FaceService: Web mode — TFLite skipped');
      return;
    }
    await _closeInterpreter();
    try {
      _interpreter = await loadInterpreter(assetPath, 1);
      print('✅ FaceService: Model loaded successfully');
    } catch (e) {
      _interpreter = null;
      print('❌ FaceService init: $e');
      throw AttendanceException(
        AttendanceErrorCode.modelNotLoaded,
        'Face model could not be loaded.',
        cause: e,
      );
    }
  }

  Future<void> _closeInterpreter() async {
    try { (_interpreter as dynamic)?.close(); } catch (_) {}
    _interpreter = null;
    await Future.delayed(const Duration(milliseconds: 100));
  }

  void closeModel() {
    if (kIsWeb) return;
    try { (_interpreter as dynamic)?.close(); } catch (_) {}
    _interpreter = null;
  }

  List<double> extractEmbeddingFromImage(img.Image image) {
    // ── Debug logs ──
    print('🔍 extractEmbeddingFromImage called');
    print('   kIsWeb       : $kIsWeb');
    print('   interpreter  : ${_interpreter != null ? "LOADED" : "NULL"}');

    if (kIsWeb) {
      print('⚠️ Web mode — returning zeros');
      return List.filled(kEmbeddingDim, 0.0);
    }

    if (_interpreter == null) {
      print('❌ Interpreter is null — model not loaded!');
      throw const AttendanceException(
        AttendanceErrorCode.modelNotLoaded,
        'Model not loaded.',
      );
    }

    final resized = img.copyResize(
      image,
      width:  kFaceInputSize,
      height: kFaceInputSize,
      interpolation: img.Interpolation.linear,
    );

    final input = List.generate(1, (_) =>
      List.generate(kFaceInputSize, (y) =>
        List.generate(kFaceInputSize, (x) =>
          List.generate(3, (c) {
            final p = resized.getPixel(x, y);
            if (c == 0) return (p.r - 127.5) / 127.5;
            if (c == 1) return (p.g - 127.5) / 127.5;
            return       (p.b - 127.5) / 127.5;
          })
        )
      )
    );

    final output = List.generate(1, (_) => List.filled(kEmbeddingDim, 0.0));

    try {
      print('▶ Running inference...');
      executeInference(_interpreter!, input, output);
      final result = List<double>.from(output[0]);
      // Check if output is all zeros (model didn't run properly)
      final nonZero = result.where((v) => v != 0.0).length;
      print('✅ Inference done — non-zero values: $nonZero / $kEmbeddingDim');
      return _l2Normalize(result);
    } catch (e) {
      print('❌ Inference error: $e');
      try { (_interpreter as dynamic)?.close(); } catch (_) {}
      _interpreter = null;
      throw AttendanceException(
        AttendanceErrorCode.embeddingExtractionFailed,
        'Inference failed. Please try again.',
        cause: e,
      );
    }
  }

  List<double> extractEmbeddingFromBytes(Uint8List bytes) {
    if (kIsWeb) return List.filled(kEmbeddingDim, 0.0);
    final raw = img.decodeImage(bytes);
    if (raw == null) {
      throw const AttendanceException(
        AttendanceErrorCode.embeddingExtractionFailed,
        'Could not decode image bytes.',
      );
    }
    // Fix EXIF orientation before inference
    final image = img.bakeOrientation(raw);
    return extractEmbeddingFromImage(image);
  }

  List<double> averageEmbeddings(List<img.Image> images) {
    print('📊 averageEmbeddings — images count: ${images.length}');
    if (kIsWeb) return List.filled(kEmbeddingDim, 0.0);
    if (images.isEmpty) return List.filled(kEmbeddingDim, 0.0);

    final embeddings = <List<double>>[];
    for (final image in images) {
      try {
        embeddings.add(extractEmbeddingFromImage(image));
      } catch (e) {
        print('⚠️ Skipping image: $e');
      }
    }
    if (embeddings.isEmpty) return List.filled(kEmbeddingDim, 0.0);

    final sum = List<double>.filled(kEmbeddingDim, 0.0);
    for (final e in embeddings) {
      for (int i = 0; i < kEmbeddingDim; i++) sum[i] += e[i];
    }
    final avg = _l2Normalize(sum);
    print('✅ Average embedding computed — first 5 values: ${avg.take(5).toList()}');
    return avg;
  }

  double cosineSimilarity(List<double> e1, List<double> e2) {
    if (e1.length != e2.length) {
      print('❌ cosineSimilarity: length mismatch ${e1.length} vs ${e2.length}');
      return 0.0;
    }

    // Check if either embedding is all zeros
    final e1zeros = e1.every((v) => v == 0.0);
    final e2zeros = e2.every((v) => v == 0.0);
    if (e1zeros || e2zeros) {
      print('⚠️ cosineSimilarity: one embedding is all zeros!'
            ' e1_zeros=$e1zeros e2_zeros=$e2zeros');
      return 0.0;
    }

    double dot = 0, n1 = 0, n2 = 0;
    for (int i = 0; i < e1.length; i++) {
      dot += e1[i] * e2[i];
      n1  += e1[i] * e1[i];
      n2  += e2[i] * e2[i];
    }
    final denom = math.sqrt(n1) * math.sqrt(n2);
    if (denom == 0) return 0.0;
    // L2-normalized embeddings: cosine = dot product directly
    // Do NOT use (dot+1)/2 — that artificially halves the score
    final sim = (dot / denom).clamp(0.0, 1.0);
    print('🎯 Cosine similarity: ${(sim * 100).toStringAsFixed(1)}%');
    return sim;
  }

  List<double> parseStoredEmbedding(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      print('⚠️ parseStoredEmbedding: raw is null or empty!');
      return [];
    }
    try {
      final result = raw.split(',').map((s) => double.parse(s.trim())).toList();
      print('✅ parseStoredEmbedding: parsed ${result.length} values');
      return result;
    } catch (e) {
      print('❌ parseStoredEmbedding error: $e');
      return [];
    }
  }

  List<double> _l2Normalize(List<double> v) {
    final norm = math.sqrt(v.fold(0.0, (s, x) => s + x * x));
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }

  img.Image nv21ToRgb(CameraImage c) {
    final w        = c.width;
    final h        = c.height;
    final yPlane   = c.planes[0].bytes;
    final uvPlane  = c.planes[1].bytes;
    final yStride  = c.planes[0].bytesPerRow;
    final uvStride = c.planes[1].bytesPerRow;

    final out = img.Image(width: w, height: h);
    for (int row = 0; row < h; row++) {
      for (int col = 0; col < w; col++) {
        final yIdx  = row * yStride + col;
        final uvIdx = (row ~/ 2) * uvStride + (col ~/ 2) * 2;
        final yV = yIdx  < yPlane.length  ? yPlane[yIdx]  & 0xFF : 0;
        final vV = uvIdx < uvPlane.length
            ? (uvPlane[uvIdx]     & 0xFF) - 128 : 0;
        final uV = (uvIdx + 1) < uvPlane.length
            ? (uvPlane[uvIdx + 1] & 0xFF) - 128 : 0;
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

  Future<List<double>> extractEmbedding(CameraImage c, Face face) async {
    if (kIsWeb) return List.filled(kEmbeddingDim, 0.0);
    final rgb = nv21ToRgb(c);
    final cr  = _cropFace(rgb, face);
    if (cr == null) {
      throw const AttendanceException(
        AttendanceErrorCode.embeddingExtractionFailed,
        'Face region too small.',
      );
    }
    return extractEmbeddingFromImage(cr);
  }

  // ── Match stored embedding against live embedding ─────────────
  // Returns true if similarity >= threshold
  // Use this in attendance screen instead of raw cosineSimilarity
  bool matchFace(List<double> liveEmbedding, List<double> storedEmbedding) {
    if (liveEmbedding.isEmpty || storedEmbedding.isEmpty) {
      print('⚠️ matchFace: empty embedding!');
      return false;
    }
    // Re-normalize both just in case storage introduced drift
    final e1  = _l2Normalize(liveEmbedding);
    final e2  = _l2Normalize(storedEmbedding);
    final sim = cosineSimilarity(e1, e2);
    print('🎯 matchFace: ${(sim * 100).toStringAsFixed(1)}% '
          '(threshold: ${(kSimilarityThreshold * 100).toStringAsFixed(0)}%)');
    return sim >= kSimilarityThreshold;
  }
}