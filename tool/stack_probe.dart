// A diagnostic whose whole output is its printed report.
// ignore_for_file: avoid_print

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:quickjs_dart/src/bindings.dart';

/// Appended with `flush: true` so the hard crash this measures (0xC0000409 on
/// Windows) cannot swallow the last marker, which is the one that names it.
void mark(String line) {
  File('probe.log').writeAsStringSync(
    '$line\n',
    mode: FileMode.append,
    flush: true,
  );
}

void reportThreadStack() {
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
    mark('thread stack reserve ${(limits[1] - limits[0]) ~/ 1024} KB');
  } finally {
    calloc.free(limits);
  }
}

void main() {
  mark('--- probe start');
  reportThreadStack();

  mark('JS_NewRuntime');
  final runtime = JS_NewRuntime();
  mark('runtime = ${runtime.address}');

  mark('JS_SetMemoryLimit');
  JS_SetMemoryLimit(runtime, 64 * 1024 * 1024);
  mark('JS_SetMaxStackSize');
  JS_SetMaxStackSize(runtime, 512 * 1024);
  mark('JS_SetGCThreshold');
  JS_SetGCThreshold(runtime, 16 * 1024 * 1024);

  mark('JS_NewContext');
  final context = JS_NewContext(runtime);
  mark('context = ${context.address}');

  mark('qjs_bridge_init');
  final queue = qjs_bridge_init(runtime, context);
  mark('queue = ${queue.address}');

  mark('qjs_timeout_new');
  final timeout = qjs_timeout_new();
  mark('timeout = ${timeout.address}');

  mark('eval 1+1');
  final source = '1 + 1'.toNativeUtf8();
  final filename = '<probe>'.toNativeUtf8();
  final value = JS_Eval(context, source, source.length, filename, 0);
  mark('eval tag ${value.tag}');
  qjs_free_value(context, value);
  calloc
    ..free(source)
    ..free(filename);

  mark('--- probe finished');
  print(File('probe.log').readAsStringSync());
}
