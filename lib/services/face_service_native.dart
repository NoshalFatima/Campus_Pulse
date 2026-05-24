// lib/services/face_service_native.dart

import 'package:tflite_flutter/tflite_flutter.dart';

Interpreter? _interp;

Future<Interpreter> delegateInterpreterFromAsset(String path, int threads) async {
  // Close stale interpreter
  try { _interp?.close(); } catch (_) {}
  _interp = null;

  // threads = CPU threads only, NOT batch size
  final options = InterpreterOptions()..threads = threads;
  _interp = await Interpreter.fromAsset(path, options: options);

  // Step 1: resize input to batch=1 BEFORE allocateTensors
  _interp!.resizeInputTensor(0, [1, 112, 112, 3]);

  // Step 2: allocate AFTER resize
  _interp!.allocateTensors();

  // Step 3: verify
  final inShape  = _interp!.getInputTensor(0).shape;
  final outShape = _interp!.getOutputTensor(0).shape;
  print('   Input  tensor: $inShape');
  print('   Output tensor: $outShape');

  return _interp!;
}

void delegateRunInterpreter(dynamic interpreter, Object input, Object output) {
  (interpreter as Interpreter).run(input, output);
}