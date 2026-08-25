// A diagnostic whose whole output is its printed report.
// ignore_for_file: avoid_print

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:quickjs_dart/src/runtime.dart';

/// Appended with `flush: true` so a hard crash (the Windows probe dies with
/// 0xC0000409) cannot swallow the last marker, which is the one that matters.
void mark(String line) {
  File('probe.log').writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

void reportThreadStack(String where) {
  if (!Platform.isWindows) {
    return;
  }
  final limits = calloc<ffi.Uint64>(2);
  try {
    ffi.DynamicLibrary.open('kernel32.dll').lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Uint64>, ffi.Pointer<ffi.Uint64>),
        void Function(ffi.Pointer<ffi.Uint64>, ffi.Pointer<ffi.Uint64>)>(
      'GetCurrentThreadStackLimits',
    )(limits, limits + 1);
    final reserve = limits[1] - limits[0];
    mark('$where thread stack reserve ${reserve ~/ 1024} KB');
  } finally {
    calloc.free(limits);
  }
}

void sweep(String where) {
  reportThreadStack(where);
  for (final kb in [32, 64, 128, 192, 256, 384, 512]) {
    mark('$where $kb KB: creating');
    final runtime = QjsRuntime(QjsRuntimeConfig(maxStackSize: kb * 1024));
    mark('$where $kb KB: created');
    try {
      final depth = runtime.evalSync('''
        let depth = 0;
        function recurse() { depth++; recurse(); }
        try { recurse(); } catch (e) {}
        depth;
      ''');
      mark('$where $kb KB: depth $depth');
    } finally {
      runtime.dispose();
    }
  }
}

Future<void> main() async {
  mark('--- probe start');
  sweep('main');
  await Isolate.run(() => sweep('spawned'));
  mark('--- probe finished');
  print(File('probe.log').readAsStringSync());
}
