// lib/services/face_service_platform.dart
// Conditional import bridge:
//   Web    → face_service_stub.dart   (no dart:ffi, returns zeros)
//   Mobile → face_service_native.dart (real TFLite)

import 'face_service_stub.dart'
    if (dart.library.io) 'face_service_native.dart';

Future<dynamic> loadInterpreter(String path, int threads) {
  return delegateInterpreterFromAsset(path, threads);
}

void executeInference(dynamic interpreter, Object input, Object output) {
  delegateRunInterpreter(interpreter, input, output);
}