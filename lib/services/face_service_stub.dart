// lib/services/face_service_stub.dart
// Web only — no TFLite available, returns zeros silently

import 'dart:async';

class Interpreter {
  void close() {}
  void run(Object input, Object output) {
    // Fill output[0] with zeros — web cannot do real inference
    if (output is List && output.isNotEmpty && output[0] is List<double>) {
      final inner = output[0] as List<double>;
      for (int i = 0; i < inner.length; i++) inner[i] = 0.0;
    }
  }
}

class InterpreterOptions {
  int threads = 1;
}

Future<dynamic> delegateInterpreterFromAsset(String path, int threads) async {
  return Interpreter();
}

void delegateRunInterpreter(dynamic interpreter, Object input, Object output) {
  (interpreter as Interpreter).run(input, output);
}