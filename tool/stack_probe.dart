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

  mark('JS_SetModuleLoaderFunc');
  JS_SetModuleLoaderFunc(
    runtime,
    ffi.Pointer.fromFunction(_normalize),
    ffi.Pointer.fromFunction(_load),
    runtime.cast(),
  );
  mark('eval after loader install');
  _eval(context, '2 + 2');

  mark('qjs_timeout_install');
  qjs_timeout_install(runtime, timeout);
  mark('eval under interrupt handler');
  _eval(context, '3 + 3');

  const snippets = <String, String>{
    'function expression': 'var f = function (a, b) { return 0; }; f(1, 2);',
    'globalThis assignment': 'globalThis.g = function (a) { return a; }; g(1);',
    'array literal in ctor': 'class A { constructor(i) { this.p = []; } } 1;',
    'getter': 'class B { get x() { return 1; } } new B().x;',
    'method named get': 'class C { get(n) { return null; } } new C().get(1);',
    'full polyfill shape': '''
      globalThis.setTimeout = function (fn, ms) { return 0; };
      globalThis.clearTimeout = function (id) {};
      class URLSearchParams {
        constructor(init) { this._pairs = []; }
        get(name) { return null; }
      }
      globalThis.URLSearchParams = URLSearchParams;
      1;
    ''',
  };
  for (final snippet in snippets.entries) {
    mark('eval ${snippet.key}');
    _eval(context, snippet.value);
  }

  mark('--- probe finished');
  print(File('probe.log').readAsStringSync());
}

void _eval(ffi.Pointer<JSContext> context, String code) {
  final source = code.toNativeUtf8();
  final filename = '<probe>'.toNativeUtf8();
  final value = JS_Eval(context, source, source.length, filename, 0);
  mark('  tag ${value.tag}');
  qjs_free_value(context, value);
  calloc
    ..free(source)
    ..free(filename);
}

ffi.Pointer<Utf8> _normalize(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<Utf8> base,
  ffi.Pointer<Utf8> name,
  ffi.Pointer<ffi.Void> opaque,
) => js_strdup(ctx, name);

ffi.Pointer<JSModuleDef> _load(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<Utf8> name,
  ffi.Pointer<ffi.Void> opaque,
) => ffi.nullptr;
