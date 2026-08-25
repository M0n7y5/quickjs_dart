// ignore_for_file: avoid_print

import 'dart:isolate';

import 'package:quickjs_dart/src/runtime.dart';

int deepestJsRecursion() {
  final runtime = QjsRuntime(const QjsRuntimeConfig());
  try {
    return runtime.evalSync('''
      let depth = 0;
      function recurse() { depth++; recurse(); }
      try { recurse(); } catch (e) {}
      depth;
    ''') as int;
  } finally {
    runtime.dispose();
  }
}

Future<void> main() async {
  print('main isolate depth: ${deepestJsRecursion()}');
  print('spawned isolate depth: ${await Isolate.run(deepestJsRecursion)}');
  print('probe finished');
}
