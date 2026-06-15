// Tests for QjsEngine — high-level isolate-based async engine.
//
// These exercise the full stack: native build, isolate spawning,
// message passing, bridge handler, promise resolution, and module system.

import 'package:quickjs_dart/quickjs_dart.dart';
import 'package:test/test.dart';

void main() {
  group('QjsEngine lifecycle', () {
    test('creates and disposes without error', () async {
      final engine = await QjsEngine.create();
      engine.dispose();
    });

    test('double dispose is safe', () async {
      final engine = await QjsEngine.create();
      engine
        ..dispose()
        ..dispose(); // should not throw
    });

    test('throws after dispose', () async {
      final engine = await QjsEngine.create();
      engine.dispose();
      // Small delay to let dispose propagate to isolate
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(() => engine.eval('1'), throwsStateError);
    });
  });

  group('eval — primitives', () {
    late QjsEngine engine;

    setUp(() async {
      engine = await QjsEngine.create();
    });

    tearDown(() {
      engine.dispose();
    });

    test('returns int', () async {
      expect(await engine.eval('1 + 2'), equals(3));
    });

    test('returns float', () async {
      expect(await engine.eval('3.14'), closeTo(3.14, 0.001));
    });

    test('returns bool', () async {
      expect(await engine.eval('true'), isTrue);
      expect(await engine.eval('false'), isFalse);
    });

    test('returns null', () async {
      expect(await engine.eval('null'), isNull);
    });

    test('returns undefined as null', () async {
      expect(await engine.eval('undefined'), isNull);
    });

    test('returns string', () async {
      expect(await engine.eval('"hello"'), equals('hello'));
    });
  });

  group('eval — compound types', () {
    late QjsEngine engine;

    setUp(() async {
      engine = await QjsEngine.create();
    });

    tearDown(() {
      engine.dispose();
    });

    test('returns array', () async {
      expect(await engine.eval('[1, 2, 3]'), equals([1, 2, 3]));
    });

    test('returns object', () async {
      final result =
          await engine.eval('({a: 1, b: "two"})') as Map<String, dynamic>;
      expect(result['a'], equals(1));
      expect(result['b'], equals('two'));
    });
  });

  group('eval — promises', () {
    late QjsEngine engine;

    setUp(() async {
      engine = await QjsEngine.create();
    });

    tearDown(() {
      engine.dispose();
    });

    test('resolves simple promise', () async {
      expect(await engine.eval('Promise.resolve(42)'), equals(42));
    });

    test('resolves chained promises', () async {
      final result = await engine.eval(
        'Promise.resolve(10).then(x => x * 2).then(x => x + 1)',
      );
      expect(result, equals(21));
    });

    test('rejects promise throws', () {
      expect(
        () => engine.eval('Promise.reject("oops")'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('oops'),
          ),
        ),
      );
    });

    test('async function resolves', () async {
      final result = await engine.eval(
        '(async () => { const x = await Promise.resolve(5); return x * 3; })()',
      );
      expect(result, equals(15));
    });
  });

  group('eval — error handling', () {
    late QjsEngine engine;

    setUp(() async {
      engine = await QjsEngine.create();
    });

    tearDown(() {
      engine.dispose();
    });

    test('syntax error throws', () {
      expect(() => engine.eval('function{'), throwsA(isA<Exception>()));
    });

    test('reference error throws', () {
      expect(() => engine.eval('undefinedVar.foo'), throwsA(isA<Exception>()));
    });

    test('throw statement throws', () {
      expect(
        () => engine.eval('throw new Error("boom")'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('boom'),
          ),
        ),
      );
    });
  });

  group('declareModule + evalModule', () {
    late QjsEngine engine;

    setUp(() async {
      engine = await QjsEngine.create();
    });

    tearDown(() {
      engine.dispose();
    });

    test('evalModule executes module code', () async {
      await engine.evalModule('mod', 'globalThis.testVal = 99;');
      expect(await engine.eval('globalThis.testVal'), equals(99));
    });

    test('declareModule + import resolves', () async {
      await engine.declareModule('mylib', 'export const answer = 42;');
      await engine.evalModule('main', '''
import { answer } from 'mylib';
globalThis.imported = answer;
''');
      expect(await engine.eval('globalThis.imported'), equals(42));
    });

    test('dynamic import resolves', () async {
      await engine.evalModule(
        'mymod',
        'export function greet(name) { return "hello " + name; }',
      );

      final result = await engine.eval(
        'import("mymod").then(m => m.greet("world"))',
      );
      expect(result, equals('hello world'));
    });

    test('module syntax error throws', () {
      expect(
        () => engine.evalModule('bad', 'export {{{'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('bridge handler', () {
    test('bridge receives payload and returns result', () async {
      final engine = await QjsEngine.create(
        bridge: (payload) async {
          final action = payload['action'] as String;
          if (action == 'greet') {
            final name = (payload['args'] as Map)['name'];
            return {'greeting': 'hello $name'};
          }
          return {'error': 'unknown action'};
        },
      );

      try {
        final result = await engine.eval(
          'fjs.bridge_call({action: "greet", args: {name: "world"}})'
          ' .then(r => r.greeting)',
        );
        expect(result, equals('hello world'));
      } finally {
        engine.dispose();
      }
    });

    // Note: This test may flake when run alongside other isolate-heavy tests
    // due to dart test runner isolate cleanup timing. Passes reliably in
    // isolation: dart test --name "bridge handles multiple"
    test('bridge handles multiple sequential calls', () async {
      var callCount = 0;
      final engine = await QjsEngine.create(
        bridge: (payload) async {
          callCount++;
          return {'count': callCount};
        },
      );

      try {
        final result = await engine.eval('''
          (async () => {
            const r1 = await fjs.bridge_call({action: "a"});
            const r2 = await fjs.bridge_call({action: "b"});
            const r3 = await fjs.bridge_call({action: "c"});
            return [r1.count, r2.count, r3.count];
          })()
        ''');
        expect(result, equals([1, 2, 3]));
      } finally {
        engine.dispose();
      }
    });

    test('bridge error returns error object', () async {
      final engine = await QjsEngine.create(
        bridge: (payload) {
          throw Exception('bridge error');
        },
      );

      try {
        // The bridge handler throws, which gets caught and sent back as an
        // error JSON object (with _error: true).
        final result = await engine.eval('fjs.bridge_call({action: "fail"})')
            as Map<String, dynamic>;
        expect(result['_error'], isTrue);
      } finally {
        engine.dispose();
      }
    });

    test('no bridge handler returns error', () async {
      // No bridge handler provided
      final engine = await QjsEngine.create();

      try {
        final result = await engine.eval('fjs.bridge_call({action: "test"})')
            as Map<String, dynamic>;
        expect(result['_error'], isTrue);
        expect(result['message'], contains('No bridge handler'));
      } finally {
        engine.dispose();
      }
    });
  });

  group('bridge + modules (plugin-like scenario)', () {
    test('SDK module uses bridge for storage', () async {
      // Simulate a simple key-value storage via bridge
      final store = <String, Object?>{};

      final engine = await QjsEngine.create(
        bridge: (payload) async {
          final action = payload['action'] as String;
          final args = (payload['args'] as Map?)?.cast<String, dynamic>() ?? {};
          switch (action) {
            case 'storage.get':
              return store[args['key'] as String];
            case 'storage.set':
              store[args['key'] as String] = args['value'];
              return null;
            default:
              return {'_error': true, 'message': 'Unknown: $action'};
          }
        },
      );

      try {
        // Declare an SDK module that wraps bridge calls
        await engine.declareModule('sdk', '''
          export async function setItem(key, value) {
            await fjs.bridge_call({action: "storage.set", args: {key, value}});
          }
          export async function getItem(key) {
            return await fjs.bridge_call({action: "storage.get", args: {key}});
          }
        ''');

        // Plugin module that uses the SDK
        await engine.evalModule('plugin', '''
          import { setItem, getItem } from 'sdk';

          export async function init() {
            await setItem("color", "blue");
            const val = await getItem("color");
            return val;
          }
        ''');

        final result = await engine.eval(
          'import("plugin").then(m => m.init())',
        );
        expect(result, equals('blue'));
        expect(store['color'], equals('blue'));
      } finally {
        engine.dispose();
      }
    });
  });

  group('custom config', () {
    test('custom memory config works', () async {
      final engine = await QjsEngine.create(
        config: const QjsRuntimeConfig(
          memoryLimit: 16 * 1024 * 1024,
          maxStackSize: 256 * 1024,
          gcThreshold: 4 * 1024 * 1024,
        ),
      );

      try {
        expect(await engine.eval('1 + 1'), equals(2));
      } finally {
        engine.dispose();
      }
    });
  });

  group('execution timeout', () {
    test('infinite loop in eval throws', () async {
      final engine = await QjsEngine.create(
        config: const QjsRuntimeConfig(
          executionTimeout: Duration(milliseconds: 500),
        ),
      );

      try {
        await expectLater(
          () => engine.eval('while(true) {}'),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('interrupted'),
            ),
          ),
        );
      } finally {
        engine.dispose();
      }
    });

    test('engine is usable after timeout', () async {
      final engine = await QjsEngine.create(
        config: const QjsRuntimeConfig(
          executionTimeout: Duration(milliseconds: 500),
        ),
      );

      try {
        // Trigger timeout
        try {
          await engine.eval('while(true) {}');
        } on Exception {
          // expected
        }

        // Engine should still work
        expect(await engine.eval('1 + 1'), equals(2));
      } finally {
        engine.dispose();
      }
    });

    test('timeout does not fire during bridge wait', () async {
      final engine = await QjsEngine.create(
        config: const QjsRuntimeConfig(
          executionTimeout: Duration(seconds: 1),
        ),
        bridge: (payload) async {
          // Simulate slow I/O — longer than the execution timeout
          await Future<void>.delayed(const Duration(seconds: 2));
          return {'ok': true};
        },
      );

      try {
        // This should NOT time out because the 2s bridge wait
        // doesn't count against the 1s execution timeout.
        final result = await engine.eval(
          'fjs.bridge_call({action: "slow"}).then(r => r.ok)',
        );
        expect(result, isTrue);
      } finally {
        engine.dispose();
      }
    });

    test('infinite loop after bridge call is caught', () async {
      final engine = await QjsEngine.create(
        config: const QjsRuntimeConfig(
          executionTimeout: Duration(milliseconds: 500),
        ),
        bridge: (payload) async => {'value': 42},
      );

      try {
        await expectLater(
          () => engine.eval('''
          (async () => {
            const r = await fjs.bridge_call({action: "get"});
            while(true) {}
          })()
        '''),
          throwsA(isA<Exception>()),
        );
      } finally {
        engine.dispose();
      }
    });
  });
}
