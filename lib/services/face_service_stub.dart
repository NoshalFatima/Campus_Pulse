// lib/services/face_service_stub.dart
//
// WEB STUB — loaded when dart:io is NOT available (web).
// No tflite_flutter import — avoids dart:ffi error on web.

import 'dart:typed_data';

Future<dynamic> delegateInterpreterFromAsset(String path, int threads) async {
  // Web has no TFLite — return null, FaceService handles it
  return null;
}

void delegateRunInterpreter(dynamic interpreter, Object input, Object output) {
  // No-op on web
}