// A diagnostic whose whole output is its printed report.
// ignore_for_file: avoid_print

import 'dart:isolate';

import 'package:quickjs_dart/src/runtime.dart';

int deepestJsRecursion(int maxStackSize) {
  final runtime = QjsRuntime(QjsRuntimeConfig(maxStackSize: maxStackSize));
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
  for (final kb in [32, 64, 128, 192, 256, 384, 512]) {
    print('main $kb KB -> depth ${deepestJsRecursion(kb * 1024)}');
  }
  for (final kb in [32, 64, 128, 192, 256, 384, 512]) {
    final depth = await Isolate.run(() => deepestJsRecursion(kb * 1024));
    print('spawned $kb KB -> depth $depth');
  }
  print('probe finished');
}
