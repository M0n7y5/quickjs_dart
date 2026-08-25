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

    // Disable computed goto: MSVC has no labels-as-values, and it SIGSEGVs on
    // Linux and Android (see -Bsymbolic-functions below).
    if (targetOS == OS.linux ||
        targetOS == OS.android ||
        targetOS == OS.windows) {
      defines['DIRECT_DISPATCH'] = '0';
    }

    // Generated on every platform so a bindings parse failure surfaces on a
    // Linux run too, not only when someone builds for Windows.
    final exportDirectives = await _writeExportDirectives(input);

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
      // src/msvc holds a <sys/time.h> MSVC lacks; msvc_compat.h maps the GNU
      // spellings cutils.h and quickjs.c are written against.
      flags.addAll([
        '/experimental:c11atomics',
        '/FI${input.packageRoot.resolve('src/msvc_compat.h').toFilePath()}',
        '/FI${exportDirectives.toFilePath()}',
        // Diagnostic knob for the MSVC bring-up: lets CI compare builds
        // (allocator choice, /GS) without editing this file per run.
        ...?Platform.environment['QJS_MSVC_EXTRA']?.split(' ').where(
          (flag) => flag.isNotEmpty,
        ),
      ]);
    }

    final builder = CBuilder.library(
      name: 'quickjs_dart',
      assetName: 'src/bindings.dart',
      sources: sources,
      includes: [quickjsDir, if (targetOS == OS.windows) 'src/msvc'],
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

/// Writes the `/EXPORT:` linker directives the Windows DLL needs.
///
/// MSVC exports nothing unless asked and this quickjs.h annotates no
/// declaration, so a symbol `bindings.dart` resolves is absent from the DLL
/// (`Failed to lookup symbol ...` error 127) unless it is named here. The list
/// is read from the bindings so a new one cannot ship without its export, and
/// `/EXPORT` of a name that no longer exists fails the link.
Future<Uri> _writeExportDirectives(BuildInput input) async {
  final bindings = File.fromUri(
    input.packageRoot.resolve('lib/src/bindings.dart'),
  );
  final symbols = <String>[];
  // The annotation spans lines, and `symbol:` sits on its closing one, so it
  // has to be accumulated before the `external` declaration is read.
  final annotation = StringBuffer();
  var inAnnotation = false;
  for (final raw in await bindings.readAsLines()) {
    final line = raw.trim();
    if (line.startsWith('@ffi.Native')) {
      inAnnotation = true;
      annotation
        ..clear()
        ..write(line);
      continue;
    }
    if (!inAnnotation) {
      continue;
    }
    if (!line.startsWith('external')) {
      annotation.write(' $line');
      continue;
    }
    final renamed = RegExp(
      "symbol: *'([A-Za-z0-9_]+)'",
    ).firstMatch(annotation.toString());
    final declared = RegExp(r'([A-Za-z0-9_]+) *\(').firstMatch(line);
    symbols.add(renamed?.group(1) ?? declared!.group(1)!);
    inAnnotation = false;
  }
  if (symbols.isEmpty) {
    throw StateError('No @ffi.Native symbols found in ${bindings.path}');
  }

  final header = File.fromUri(input.outputDirectory.resolve('msvc_exports.h'));
  await header.writeAsString(
    [
      '/* Generated by hook/build.dart from lib/src/bindings.dart. */',
      '#ifdef _MSC_VER',
      for (final symbol in symbols)
        '#pragma comment(linker, "/EXPORT:$symbol")',
      '#endif',
      '',
    ].join('\n'),
  );
  return header.uri;
}
