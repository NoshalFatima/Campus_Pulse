// lib/services/face_service_native.dart
// Mobile only — uses real TFLite interpreter
// run(input, output) — EXACT same as StudentSignupActivity

import 'package:tflite_flutter/tflite_flutter.dart';

Future<dynamic> delegateInterpreterFromAsset(String path, int threads) async {
  final options = InterpreterOptions()..threads = threads;
  return await Interpreter.fromAsset(path, options: options);
}

void delegateRunInterpreter(dynamic interpreter, Object input, Object output) {
  // EXACT same as signup: _interpreter!.run(input, output)
  (interpreter as Interpreter).run(input, output);
}