// hook/build.dart — native_assets_cli build hook for quickjs_dart.
//
// Compiles Bellard's QuickJS C source + our thin shim into a shared library.
// Invoked automatically by `dart run` / `flutter run` / `dart test`.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final targetOS = input.config.code.targetOS;

    const quickjsDir = 'src/quickjs';
    final sources = [
      '$quickjsDir/quickjs.c',
      '$quickjsDir/cutils.c',
      '$quickjsDir/dtoa.c',
      '$quickjsDir/libregexp.c',
      '$quickjsDir/libunicode.c',
      '$quickjsDir/qjs_shim.c',
    ];

    final defines = <String, String?>{
      '_GNU_SOURCE': null,
      'CONFIG_VERSION': '"2026-06-04"',
    };

    // Platform-specific symbol visibility
    if (targetOS == OS.windows) {
      defines['WIN32_LEAN_AND_MEAN'] = null;
      defines['JS_EXTERN'] = '__declspec(dllexport)';
    } else {
      defines['JS_EXTERN'] = '__attribute__((visibility("default")))';
    }

    // Disable computed goto on Linux and Android to prevent SIGSEGV
    if (targetOS == OS.linux || targetOS == OS.android) {
      defines['DIRECT_DISPATCH'] = '0';
    }

    final flags = <String>[];
    final libraries = <String>[];

    if (targetOS != OS.windows) {
      flags.addAll([
        '-Wno-implicit-fallthrough',
        '-Wno-sign-compare',
        '-Wno-missing-field-initializers',
        '-Wno-unused-parameter',
        '-Wno-unused-but-set-variable',
      ]);

      if (targetOS == OS.linux || targetOS == OS.android) {
        libraries.add('m');
        flags.addAll([
          '-fPIC',
          '-fno-strict-aliasing',
          '-fwrapv',
          // QuickJS exports generic names (js_free, js_malloc, …) that collide
          // with other process-global JS engines. media_kit → libmpv → libmujs
          // also exports js_free/js_malloc; without symbolic binding, this DSO's
          // PLT resolves to mujs and SIGSEGVs inside JS_Eval/js_create_function.
          '-Wl,-Bsymbolic-functions',
        ]);
      }
    } else {
      flags.add('/experimental:c11atomics');
    }

    final builder = CBuilder.library(
      name: 'quickjs_dart',
      assetName: 'src/bindings.dart',
      sources: sources,
      includes: [quickjsDir],
      defines: defines,
      flags: flags,
      libraries: libraries,
      // gnu11 (not c11) on clang/gcc: QuickJS 2026-06-04 cpu_pause() uses the
      // GNU `asm` keyword for Atomics.pause. MSVC keeps c11 for /experimental:c11atomics
      // (its x86 cpu_pause branch is empty — __x86_64__/__i386__ aren't MSVC macros).
      std: targetOS == OS.windows ? 'c11' : 'gnu11',
    );

    await builder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.ALL
        ..onRecord.listen((record) => stderr.writeln(record.message)),
    );
  });
}
