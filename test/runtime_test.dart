// Tests for QjsRuntime — low-level QuickJS wrapper.
//
// These run on the main isolate, exercising the native build, FFI bindings,
// value conversion, module system, and bridge queue.

import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:quickjs_dart/src/bindings.dart';
import 'package:quickjs_dart/src/constants.dart';
import 'package:quickjs_dart/src/runtime.dart';
import 'package:quickjs_dart/src/value.dart';
import 'package:test/test.dart';

void main() {
  group('QjsRuntime lifecycle', () {
    test('creates and disposes without error', () {
      QjsRuntime(const QjsRuntimeConfig()).dispose();
    });

    test('double dispose is safe', () {
      (QjsRuntime(const QjsRuntimeConfig())..dispose()).dispose();
    });

    test('throws after dispose', () {
      final runtime = QjsRuntime(const QjsRuntimeConfig())..dispose();
      expect(() => runtime.evalSync('1'), throwsStateError);
    });
  });

  group('evalSync — primitive types', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('returns int', () {
      expect(runtime.evalSync('1 + 2'), equals(3));
    });

    test('returns negative int', () {
      expect(runtime.evalSync('-42'), equals(-42));
    });

    test('returns float64', () {
      expect(runtime.evalSync('3.14'), closeTo(3.14, 0.001));
    });

    test('returns bool true', () {
      expect(runtime.evalSync('true'), isTrue);
    });

    test('returns bool false', () {
      expect(runtime.evalSync('false'), isFalse);
    });

    test('returns null', () {
      expect(runtime.evalSync('null'), isNull);
    });

    test('returns undefined as null', () {
      expect(runtime.evalSync('undefined'), isNull);
    });

    test('returns string', () {
      expect(runtime.evalSync('"hello world"'), equals('hello world'));
    });

    test('returns empty string', () {
      expect(runtime.evalSync('""'), equals(''));
    });

    test('returns string with unicode', () {
      expect(runtime.evalSync(r'"\u00e9"'), equals('é'));
    });
  });

  group('evalSync — compound types', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('returns array', () {
      final result = runtime.evalSync('[1, 2, 3]');
      expect(result, equals([1, 2, 3]));
    });

    test('returns nested array', () {
      final result = runtime.evalSync('[[1, 2], [3, 4]]');
      expect(
        result,
        equals([
          [1, 2],
          [3, 4],
        ]),
      );
    });

    test('returns empty array', () {
      final result = runtime.evalSync('[]');
      expect(result, equals([]));
    });

    test('returns object as Map', () {
      final result =
          runtime.evalSync('({a: 1, b: "two"})') as Map<String, dynamic>;
      expect(result['a'], equals(1));
      expect(result['b'], equals('two'));
    });

    test('returns nested object', () {
      final result =
          runtime.evalSync('({x: {y: 42}})') as Map<String, dynamic>;
      expect((result['x'] as Map<String, dynamic>)['y'], equals(42));
    });

    test('returns empty object', () {
      final result = runtime.evalSync('({})') as Map<String, dynamic>;
      expect(result.isEmpty, isTrue);
    });
  });

  group('evalSync — expressions and statements', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('string concatenation', () {
      expect(runtime.evalSync('"hello" + " " + "world"'), 'hello world');
    });

    test('template literal', () {
      expect(runtime.evalSync('`${1 + 2}`'), '3');
    });

    test('ternary expression', () {
      expect(runtime.evalSync('true ? "yes" : "no"'), 'yes');
    });

    test('arrow function execution', () {
      expect(runtime.evalSync('(() => 42)()'), 42);
    });

    test('multi-statement with var', () {
      expect(runtime.evalSync('var x = 10; x * 3'), 30);
    });

    test('array methods', () {
      expect(runtime.evalSync('[1,2,3].map(x => x * 2)'), [2, 4, 6]);
    });

    test('JSON.parse', () {
      final result = runtime.evalSync('JSON.parse(\'{"key":"val"}\')')
          as Map<String, dynamic>;
      expect(result['key'], 'val');
    });

    test('JSON.stringify', () {
      expect(runtime.evalSync('JSON.stringify({a: 1})'), '{"a":1}');
    });
  });

  group('evalSync — error handling', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('syntax error throws Exception', () {
      expect(() => runtime.evalSync('function{'), throwsA(isA<Exception>()));
    });

    test('reference error throws Exception', () {
      expect(
        () => runtime.evalSync('undefinedVariable.foo'),
        throwsA(isA<Exception>()),
      );
    });

    test('throw statement throws Exception', () {
      expect(
        () => runtime.evalSync('throw new Error("boom")'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('boom'),
          ),
        ),
      );
    });

    test('type error throws Exception', () {
      expect(() => runtime.evalSync('null.foo'), throwsA(isA<Exception>()));
    });
  });

  group('evalRaw — raw JSValue handling', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('returns JSValue with correct tag for int', () {
      final result = runtime.evalRaw('42');
      expect(result.tag, equals(JsTag.int_));
      expect(result.intValue, equals(42));
    });

    test('returns JSValue with correct tag for string', () {
      final result = runtime.evalRaw('"test"');
      expect(result.isString, isTrue);
      // Must free since strings are ref-counted
      kjs_free_value(runtime.context, result);
    });

    test('returns JSValue with correct tag for null', () {
      final result = runtime.evalRaw('null');
      expect(result.isNull, isTrue);
    });

    test('returns JSValue with correct tag for undefined', () {
      final result = runtime.evalRaw('undefined');
      expect(result.isUndefined, isTrue);
    });

    test('returns JSValue with correct tag for bool', () {
      final result = runtime.evalRaw('true');
      expect(result.isBool, isTrue);
      expect(result.boolValue, isTrue);
    });

    test('returns JSValue with correct tag for object', () {
      final result = runtime.evalRaw('({})');
      expect(result.isObject, isTrue);
      kjs_free_value(runtime.context, result);
    });

    test('exception flag set for errors', () {
      final result = runtime.evalRaw('throw new Error("x")');
      expect(result.isException, isTrue);
      // Clear the exception from the context
      final exc = JS_GetException(runtime.context);
      if (exc.hasRefCount) {
        kjs_free_value(runtime.context, exc);
      }
    });
  });

  group('dartToJsValue — round-trip conversion', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('null round-trips', () {
      final jsVal = dartToJsValue(runtime.context, null);
      final dartVal = jsValueToDart(runtime.context, jsVal, freeValue: true);
      expect(dartVal, isNull);
    });

    test('bool round-trips', () {
      final jsVal = dartToJsValue(runtime.context, true);
      final dartVal = jsValueToDart(runtime.context, jsVal, freeValue: true);
      expect(dartVal, isTrue);
    });

    test('int round-trips', () {
      final jsVal = dartToJsValue(runtime.context, 42);
      final dartVal = jsValueToDart(runtime.context, jsVal, freeValue: true);
      expect(dartVal, equals(42));
    });

    test('double round-trips', () {
      final jsVal = dartToJsValue(runtime.context, 3.14);
      final dartVal = jsValueToDart(runtime.context, jsVal, freeValue: true);
      expect(dartVal, closeTo(3.14, 0.001));
    });

    test('string round-trips', () {
      final jsVal = dartToJsValue(runtime.context, 'hello');
      final dartVal = jsValueToDart(runtime.context, jsVal, freeValue: true);
      expect(dartVal, equals('hello'));
    });

    test('list round-trips', () {
      final jsVal = dartToJsValue(runtime.context, [1, 'two', true]);
      final dartVal = jsValueToDart(runtime.context, jsVal, freeValue: true);
      expect(dartVal, equals([1, 'two', true]));
    });

    test('map round-trips', () {
      final jsVal = dartToJsValue(runtime.context, {'a': 1, 'b': 'two'});
      final dartVal = jsValueToDart(runtime.context, jsVal, freeValue: true)
          as Map<String, dynamic>;
      expect(dartVal['a'], equals(1));
      expect(dartVal['b'], equals('two'));
    });
  });

  group('module system', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('evalModule executes module code', () {
      // A module that sets a global variable
      runtime.evalModule('test_mod', 'globalThis.testValue = 42;');
      expect(runtime.evalSync('globalThis.testValue'), equals(42));
    });

    test('declareModule + import resolves', () {
      // Declare a module that exports a value
      runtime
        ..declareModule('mylib', 'export const answer = 42;')
        // Evaluate a module that imports from it
        ..evalModule('main', '''
import { answer } from 'mylib';
globalThis.importedAnswer = answer;
''');

      expect(runtime.evalSync('globalThis.importedAnswer'), equals(42));
    });

    test('module syntax error throws', () {
      expect(
        () => runtime.evalModule('bad', 'export {{{'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('promise support', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('isPromise detects promise', () {
      final result = runtime.evalRaw('Promise.resolve(42)');
      expect(runtime.isPromise(result), isTrue);
      kjs_free_value(runtime.context, result);
    });

    test('isPromise returns false for non-promise', () {
      final result = runtime.evalRaw('42');
      expect(runtime.isPromise(result), isFalse);
    });

    test('resolved promise state is fulfilled after pumping', () {
      final result = runtime.evalRaw('Promise.resolve(42)');
      runtime.executePendingJobs();

      final state = runtime.promiseState(result);
      expect(state, equals(1)); // 1 = fulfilled

      final value = runtime.extractPromiseResult(result);
      expect(value, equals(42));

      kjs_free_value(runtime.context, result);
    });

    test('rejected promise state is rejected after pumping', () {
      final result = runtime.evalRaw('Promise.reject("oops")');
      runtime.executePendingJobs();

      final state = runtime.promiseState(result);
      expect(state, equals(2)); // 2 = rejected

      expect(
        () => runtime.extractPromiseResult(result),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('oops'),
          ),
        ),
      );

      kjs_free_value(runtime.context, result);
    });

    test('chained promise resolves', () {
      final result = runtime.evalRaw(
        'Promise.resolve(10).then(x => x * 2).then(x => x + 1)',
      );
      runtime.executePendingJobs();

      expect(runtime.promiseState(result), equals(1));
      expect(runtime.extractPromiseResult(result), equals(21));

      kjs_free_value(runtime.context, result);
    });
  });

  group('bridge queue', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('initially has no pending bridge requests', () {
      expect(runtime.pendingBridgeCount, equals(0));
    });

    test('peekBridgePayload returns null when empty', () {
      expect(runtime.peekBridgePayload(), isNull);
    });

    test('bridge_call creates a pending request', () {
      // Call fjs.bridge_call() from JS — this should queue a bridge request
      final result = runtime.evalRaw(
        'fjs.bridge_call({action: "test", args: {key: "val"}})',
      );

      // Should be a promise
      expect(runtime.isPromise(result), isTrue);

      // Should have a pending bridge request
      expect(runtime.pendingBridgeCount, equals(1));

      // Peek at the payload
      final payload = runtime.peekBridgePayload();
      expect(payload, isNotNull);

      final decoded = jsonDecode(payload!) as Map<String, dynamic>;
      expect(decoded['action'], equals('test'));
      expect((decoded['args'] as Map)['key'], equals('val'));

      // Resolve the bridge request
      runtime
        ..resolveBridge('{"result":"ok"}')
        // Pump jobs to settle the promise
        ..executePendingJobs();

      // Promise should be fulfilled
      expect(runtime.promiseState(result), equals(1));
      final value =
          runtime.extractPromiseResult(result) as Map<String, dynamic>;
      expect(value['result'], equals('ok'));

      kjs_free_value(runtime.context, result);
    });

    test('bridge_call reject produces rejected promise', () {
      final result = runtime.evalRaw('fjs.bridge_call({action: "fail"})');

      expect(runtime.pendingBridgeCount, equals(1));

      // Reject the bridge request
      runtime
        ..rejectBridge('something went wrong')
        ..executePendingJobs();

      expect(runtime.promiseState(result), equals(2)); // rejected

      kjs_free_value(runtime.context, result);
    });
  });

  group('hasPendingJobs', () {
    late QjsRuntime runtime;

    setUp(() {
      runtime = QjsRuntime(const QjsRuntimeConfig());
    });

    tearDown(() {
      runtime.dispose();
    });

    test('returns false when no jobs pending', () {
      runtime.evalSync('1 + 1');
      expect(runtime.hasPendingJobs, isFalse);
    });

    test('returns true when promise callbacks pending', () {
      // Create a promise that schedules microtasks
      runtime.evalRaw('Promise.resolve().then(() => 42)');
      expect(runtime.hasPendingJobs, isTrue);
      runtime.executePendingJobs();
      expect(runtime.hasPendingJobs, isFalse);
    });
  });

  group('context getter', () {
    test('returns non-null pointer', () {
      final runtime = QjsRuntime(const QjsRuntimeConfig());
      expect(runtime.context, isNot(equals(ffi.nullptr)));
      runtime.dispose();
    });
  });

  group('memory configuration', () {
    test('custom config does not crash', () {
      final runtime = QjsRuntime(
        const QjsRuntimeConfig(
          memoryLimit: 16 * 1024 * 1024,
          maxStackSize: 256 * 1024,
          gcThreshold: 4 * 1024 * 1024,
        ),
      );
      expect(runtime.evalSync('1 + 1'), equals(2));
      runtime.dispose();
    });
  });

  group('execution timeout', () {
    test('infinite loop is interrupted', () {
      final runtime = QjsRuntime(
        const QjsRuntimeConfig(executionTimeout: Duration(milliseconds: 500)),
      );
      try {
        runtime.setDeadline();
        final result = runtime.evalRaw('while(true) {}');
        expect(result.isException, isTrue);
        // Clear the exception from the context
        final exc = JS_GetException(runtime.context);
        if (exc.hasRefCount) {
          kjs_free_value(runtime.context, exc);
        }
      } finally {
        runtime
          ..clearDeadline()
          ..dispose();
      }
    });

    test('fast code is not interrupted', () {
      final runtime = QjsRuntime(
        const QjsRuntimeConfig(executionTimeout: Duration(seconds: 5)),
      );
      try {
        runtime.setDeadline();
        expect(runtime.evalSync('1 + 2'), equals(3));
      } finally {
        runtime
          ..clearDeadline()
          ..dispose();
      }
    });

    test('timeout can be cleared', () {
      final runtime = QjsRuntime(
        const QjsRuntimeConfig(executionTimeout: Duration(milliseconds: 100)),
      );
      try {
        runtime
          ..setDeadline()
          ..clearDeadline();
        // Should NOT be interrupted because deadline was cleared
        expect(runtime.evalSync('1 + 2'), equals(3));
      } finally {
        runtime.dispose();
      }
    });

    test('runtime is usable after timeout', () {
      final runtime = QjsRuntime(
        const QjsRuntimeConfig(executionTimeout: Duration(milliseconds: 500)),
      );
      try {
        // First: trigger a timeout
        runtime.setDeadline();
        final result = runtime.evalRaw('while(true) {}');
        expect(result.isException, isTrue);
        final exc = JS_GetException(runtime.context);
        if (exc.hasRefCount) {
          kjs_free_value(runtime.context, exc);
        }
        runtime.clearDeadline();

        // Second: runtime should still work
        expect(runtime.evalSync('42'), equals(42));
      } finally {
        runtime.dispose();
      }
    });
  });
}
