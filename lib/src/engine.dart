/// High-level QuickJS engine with isolate-based async bridge.
///
/// Each [QjsEngine] spawns a dedicated Dart [Isolate] running a [QjsRuntime].
/// JS evaluation and bridge callbacks flow between isolates via [SendPort].
///
/// All JSValue handling stays within the isolate — only Dart-native types
/// cross the isolate boundary.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'bindings.dart';
import 'runtime.dart';
import 'value.dart';

/// Callback type for handling bridge requests from JS.
///
/// Receives a decoded payload map (from JSON) and returns a result that
/// will be JSON-encoded and sent back to JS as the resolved promise value.
typedef BridgeHandler = Future<Object?> Function(Map<String, dynamic> payload);

/// High-level QuickJS engine.
///
/// Runs JS on a dedicated isolate. All public methods are async and
/// communicate with the isolate via message passing.
///
/// Usage:
/// ```dart
/// final engine = await QjsEngine.create(
///   config: QjsRuntimeConfig(memoryLimit: 32 * 1024 * 1024),
///   bridge: (payload) async {
///     return {'status': 200};
///   },
/// );
///
/// engine.declareModule('kirahe', sdkSource);
/// await engine.evalModule('plugin', pluginSource);
/// final result = await engine.eval('import("plugin").then(m => m.run())');
///
/// engine.dispose();
/// ```
class QjsEngine {
  QjsEngine._({
    required Isolate isolate,
    required SendPort commandPort,
    required ReceivePort responsePort,
    required _MessageQueue messageQueue,
    BridgeHandler? bridge,
  }) : _isolate = isolate,
       _commandPort = commandPort,
       _responsePort = responsePort,
       _messageQueue = messageQueue,
       _bridge = bridge;

  final Isolate _isolate;
  final SendPort _commandPort;
  final ReceivePort _responsePort;
  final _MessageQueue _messageQueue;
  final BridgeHandler? _bridge;
  var _disposed = false;

  /// Serializes all engine operations so only one eval/command runs at a time.
  ///
  /// Without this, concurrent `eval()` calls would race on `_messageQueue`,
  /// causing bridge responses to be delivered to the wrong caller.
  Future<void> _operationLock = Future.value();

  /// Creates a new [QjsEngine] with a dedicated isolate.
  static Future<QjsEngine> create({
    QjsRuntimeConfig config = const QjsRuntimeConfig(),
    BridgeHandler? bridge,
  }) async {
    final responsePort = ReceivePort();
    final messageQueue = _MessageQueue(responsePort);

    final isolate = await Isolate.spawn(
      _isolateMain,
      _IsolateStartup(sendPort: responsePort.sendPort, config: config),
    );

    // Wait for the isolate to send back its command port
    final commandPort = (await messageQueue.next)! as SendPort;

    return QjsEngine._(
      isolate: isolate,
      commandPort: commandPort,
      responsePort: responsePort,
      messageQueue: messageQueue,
      bridge: bridge,
    );
  }

  /// Registers a module source without executing it.
  Future<void> declareModule(String name, String source) =>
      _serialized(() => _sendCommand(_CmdDeclareModule(name, source)));

  /// Evaluates JS code as an ES module (executed immediately).
  Future<void> evalModule(String name, String source) =>
      _serialized(() => _sendCommand(_CmdEvalModule(name, source)));

  /// Evaluates JS code and returns the result as a Dart value.
  ///
  /// Handles the full async lifecycle:
  /// - JS eval may return a Promise (e.g. `import(...).then(...)`)
  /// - Bridge callbacks are processed (HTTP fetch, storage, etc.)
  /// - Promises are resolved and the final value is returned
  ///
  /// Calls are serialized — concurrent `eval()` calls on the same engine
  /// will execute one at a time in FIFO order. This is required because the
  /// underlying isolate processes one eval at a time, and the bridge
  /// response routing assumes a single active caller.
  Future<dynamic> eval(String code) => _serialized(() {
    _assertNotDisposed();
    _commandPort.send(_CmdEval(code));
    return _processResponses();
  });

  /// Disposes the engine and kills the isolate.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _commandPort.send(const _CmdDispose());
    _messageQueue.dispose();
    unawaited(Future<void>.delayed(const Duration(milliseconds: 100), () {
      _isolate.kill(priority: Isolate.immediate);
      _responsePort.close();
    }));
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  /// Sends a command and waits for a simple ok/error response.
  Future<void> _sendCommand(Object command) async {
    _assertNotDisposed();
    _commandPort.send(command);

    while (true) {
      final message = await _messageQueue.next;
      if (message is _ResultOk) {
        return;
      }
      if (message is _ResultError) {
        throw Exception(message.error);
      }
      // Ignore unexpected messages (shouldn't happen)
    }
  }

  /// Processes response stream, handling bridge requests along the way.
  Future<dynamic> _processResponses() async {
    while (true) {
      final message = await _messageQueue.next;
      if (message is _ResultOk) {
        return message.value;
      }
      if (message is _ResultError) {
        throw Exception(message.error);
      }
      if (message is _BridgeRequest) {
        await _handleBridgeRequest(message);
      }
      if (message is _BridgeBatchRequest) {
        _handleBridgeBatch(message);
      }
    }
  }

  Future<void> _handleBridgeRequest(_BridgeRequest request) async {
    final responseJson = await _dispatchBridgePayload(request.payloadJson);
    _commandPort.send(_BridgeResponse(responseJson));
  }

  /// Dispatches a batch of bridge requests **concurrently** and sends back
  /// each response individually as it completes (as [_BridgeIndexedResponse]).
  ///
  /// Unlike the previous `Future.wait` approach, this ensures that fast
  /// responses (e.g. a completed HTTP fetch) are delivered to the isolate
  /// immediately — not held up by slower items in the same batch (e.g. a
  /// `setTimeout` timer).  The isolate resolves them in FIFO order, pumping
  /// promise jobs between each, so `Promise.race` semantics work correctly.
  void _handleBridgeBatch(_BridgeBatchRequest batch) {
    for (var i = 0; i < batch.payloads.length; i++) {
      final index = i;
      unawaited(
        _dispatchBridgePayload(batch.payloads[i]).then((json) {
          _commandPort.send(_BridgeIndexedResponse(index, json));
        }),
      );
    }
  }

  /// Dispatches a single bridge payload JSON string and returns the
  /// response JSON string.
  Future<String> _dispatchBridgePayload(String payloadJson) async {
    try {
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;

      // Handle internal timer action from the setTimeout polyfill.
      // Delays for the requested duration so that setTimeout semantics are
      // honoured.  Combined with streamed batch responses (each response is
      // sent back individually as it completes, rather than waiting for the
      // entire batch), this allows bridge requests queued before the timer
      // to resolve first — preserving natural Promise.race behaviour.
      if (payload['action'] == '_timer') {
        final args = payload['args'] as Map<String, dynamic>? ?? {};
        final ms = ((args['ms'] as num?)?.toInt() ?? 0).clamp(0, 60000);
        if (ms > 0) {
          await Future<void>.delayed(Duration(milliseconds: ms));
        }
        return 'null';
      } else if (_bridge == null) {
        return jsonEncode({'_error': true, 'message': 'No bridge handler'});
      } else {
        final result = await _bridge(payload);
        return jsonEncode(result);
      }
    } on Object catch (e) {
      return jsonEncode({'_error': true, 'code': '$e', 'message': '$e'});
    }
  }

  /// Serializes an async operation so that only one runs at a time.
  ///
  /// Each call waits for the previous operation to complete (or fail) before
  /// starting. This prevents concurrent `eval()` calls from racing on
  /// `_messageQueue`.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _operationLock;
    final completer = Completer<T>();

    _operationLock = completer.future.then((_) {}, onError: (_) {});

    unawaited(() async {
      // Wait for previous operation to finish (ignore its errors).
      try {
        await previous;
      } on Object {
        // Previous operation failed — that's OK, we proceed.
      }

      try {
        completer.complete(await operation());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    }());

    return completer.future;
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('QjsEngine has been disposed');
    }
  }
}

// =============================================================================
// Message queue — buffers isolate messages so none are lost
// =============================================================================

/// A simple message queue backed by a [ReceivePort].
///
/// Unlike a broadcast stream, this guarantees no messages are lost between
/// sequential async operations. Each call to [next] returns the next message
/// in FIFO order.
class _MessageQueue {
  _MessageQueue(ReceivePort port) {
    _subscription = port.listen(_onMessage);
  }

  final _queue = Queue<Object?>();
  final _waiters = Queue<Completer<Object?>>();
  late final StreamSubscription<dynamic> _subscription;

  /// Returns the next message, waiting if necessary.
  Future<Object?> get next {
    if (_queue.isNotEmpty) {
      return Future.value(_queue.removeFirst());
    }
    final c = Completer<Object?>();
    _waiters.add(c);
    return c.future;
  }

  void _onMessage(dynamic message) {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(message);
    } else {
      _queue.add(message);
    }
  }

  void dispose() {
    unawaited(_subscription.cancel());
    for (final c in _waiters) {
      c.completeError(StateError('QjsEngine disposed'));
    }
    _waiters.clear();
  }
}

// =============================================================================
// Message types (all must be Dart-native, no FFI types)
// =============================================================================

class _IsolateStartup {
  const _IsolateStartup({required this.sendPort, required this.config});
  final SendPort sendPort;
  final QjsRuntimeConfig config;
}

class _CmdDeclareModule {
  const _CmdDeclareModule(this.name, this.source);
  final String name;
  final String source;
}

class _CmdEvalModule {
  const _CmdEvalModule(this.name, this.source);
  final String name;
  final String source;
}

class _CmdEval {
  const _CmdEval(this.code);
  final String code;
}

class _CmdDispose {
  const _CmdDispose();
}

class _BridgeResponse {
  const _BridgeResponse(this.responseJson);
  final String responseJson;
}

class _ResultOk {
  const _ResultOk([this.value]);
  final dynamic value;
}

class _ResultError {
  const _ResultError(this.error);
  final String error;
}

class _BridgeRequest {
  const _BridgeRequest(this.payloadJson);
  final String payloadJson;
}

/// Batch of bridge requests sent from isolate to main for concurrent dispatch.
class _BridgeBatchRequest {
  const _BridgeBatchRequest(this.payloads);
  final List<String> payloads;
}

/// A single bridge response from a batch, identified by its index within the
/// batch.  Sent from the main isolate back to the JS isolate as each
/// dispatched payload completes (rather than waiting for the entire batch).
class _BridgeIndexedResponse {
  const _BridgeIndexedResponse(this.index, this.responseJson);
  final int index;
  final String responseJson;
}

// =============================================================================
// Isolate entry point
// =============================================================================

void _isolateMain(_IsolateStartup startup) {
  final commandPort = ReceivePort();
  final sendPort = startup.sendPort
    // Send our command port back.
    ..send(commandPort.sendPort);

  late final QjsRuntime runtime;
  try {
    runtime = QjsRuntime(startup.config);
  } on Object catch (e) {
    sendPort.send(_ResultError('Failed to create runtime: $e'));
    return;
  }

  // Completer for awaiting bridge responses during eval pump loop.
  // Single-request path (used when only one bridge request is pending).
  Completer<String>? pendingBridgeResponse;

  // Batch-request path: one completer per batch item, indexed by position.
  // Responses arrive individually as each dispatch completes.
  List<Completer<String>>? pendingIndexedCompleters;

  commandPort.listen((message) {
    if (message is _CmdDeclareModule) {
      try {
        runtime.declareModule(message.name, message.source);
        sendPort.send(const _ResultOk());
      } on Object catch (e) {
        sendPort.send(_ResultError('$e'));
      }
    } else if (message is _CmdEvalModule) {
      try {
        runtime.evalModule(message.name, message.source);
        sendPort.send(const _ResultOk());
      } on Object catch (e) {
        sendPort.send(_ResultError('$e'));
      }
    } else if (message is _CmdEval) {
      // Handle eval with async bridge pump loop
      unawaited(
        _handleEval(
          runtime,
          sendPort,
          message.code,
          waitForSingle: () {
            final c = Completer<String>();
            pendingBridgeResponse = c;
            return c.future;
          },
          setupBatchCompleters: (count) {
            final completers = List.generate(count, (_) => Completer<String>());
            pendingIndexedCompleters = completers;
            return completers;
          },
        ),
      );
    } else if (message is _BridgeResponse) {
      pendingBridgeResponse?.complete(message.responseJson);
      pendingBridgeResponse = null;
    } else if (message is _BridgeIndexedResponse) {
      pendingIndexedCompleters?[message.index].complete(message.responseJson);
    } else if (message is _CmdDispose) {
      runtime.dispose();
      commandPort.close();
    }
  });
}

/// Handles eval with the async bridge pump loop.
///
/// All JSValue handling stays within the isolate. Only Dart-native types
/// are sent back via [sendPort].
///
/// Bridge requests are batched: when multiple JS Promises are awaiting bridge
/// results simultaneously (e.g. `Promise.allSettled([fetch(...), fetch(...)])`),
/// all pending requests are sent to the main isolate as a single batch and
/// dispatched concurrently.  Each response is streamed back individually
/// (via [_BridgeIndexedResponse]) as it completes, and resolved in FIFO
/// order with job pumping between each.  This ensures fast responses (e.g. a
/// completed HTTP fetch) are not held up by slower items in the same batch
/// (e.g. a `setTimeout` timer with a real delay).
Future<void> _handleEval(
  QjsRuntime runtime,
  SendPort sendPort,
  String code, {
  required Future<String> Function() waitForSingle,
  required List<Completer<String>> Function(int count) setupBatchCompleters,
}) async {
  try {
    // Step 1: Evaluate the code
    runtime.setDeadline();
    final result = runtime.evalRaw(code);

    if (result.isException) {
      runtime.clearDeadline();
      final err = runtime.extractException();
      kjs_free_value(runtime.context, result);
      sendPort.send(_ResultError(err.toString()));
      return;
    }

    // Step 2: If not a promise, convert and return immediately
    if (!runtime.isPromise(result)) {
      runtime.clearDeadline();
      final dartValue = jsValueToDart(runtime.context, result, freeValue: true);
      sendPort.send(_ResultOk(dartValue));
      return;
    }

    // Step 3: Promise pump loop
    const maxIterations = 10000;
    try {
      for (var i = 0; i < maxIterations; i++) {
        // Drain ALL pending bridge requests and dispatch them as a batch
        // so the main isolate can process them concurrently.
        while (runtime.pendingBridgeCount > 0) {
          final count = runtime.pendingBridgeCount;

          if (count == 1) {
            // Fast path: single request — use lightweight single message.
            final payload = runtime.peekBridgePayload();
            if (payload == null) {
              break;
            }

            sendPort.send(_BridgeRequest(payload));
            final responseJson = await waitForSingle();

            runtime
              ..setDeadline()
              ..resolveBridge(responseJson);
          } else {
            // Batch path: read all pending payloads and send as one message.
            // The main isolate dispatches them concurrently and streams back
            // each response individually (as _BridgeIndexedResponse) as it
            // completes.  We await completers in FIFO order so that fast
            // responses are resolved immediately — not held up by slower
            // items in the same batch (e.g. a setTimeout timer).
            final payloads = runtime.peekAllBridgePayloads();
            if (payloads.isEmpty) {
              break;
            }

            sendPort.send(_BridgeBatchRequest(payloads));
            final completers = setupBatchCompleters(payloads.length);

            // Resolve each in FIFO order, pumping jobs between each so that
            // promise continuations run before the next bridge promise is
            // settled.  Because we await completers[i] in order, a fetch at
            // index 0 that finishes at 2 s is resolved at 2 s even if a
            // setTimeout timer at index 1 won't finish for 10 s.
            for (var ci = 0; ci < completers.length; ci++) {
              final responseJson = await completers[ci].future;
              runtime
                ..setDeadline()
                ..resolveBridge(responseJson)
                ..executePendingJobs();
            }
          }
        }

        // Final pump for any remaining jobs
        runtime
          ..setDeadline()
          ..executePendingJobs();

        // Check if more bridge requests appeared
        if (runtime.pendingBridgeCount > 0) {
          continue;
        }

        // Check promise state: 0=pending, 1=fulfilled, 2=rejected
        final state = runtime.promiseState(result);

        if (state == 1) {
          // Fulfilled — extract result
          runtime.clearDeadline();
          final promiseResult = runtime.promiseResult(result);
          final dartValue = jsValueToDart(
            runtime.context,
            promiseResult,
            freeValue: true,
          );
          kjs_free_value(runtime.context, result);
          sendPort.send(_ResultOk(dartValue));
          return;
        }

        if (state == 2) {
          // Rejected — extract error.
          // Error objects serialize to {} via JSON.stringify because their
          // .message and .stack properties are non-enumerable.  We use
          // extractErrorString to read .message/.stack directly.
          runtime.clearDeadline();
          final promiseResult = runtime.promiseResult(result);
          final errMsg = runtime.extractErrorString(promiseResult);
          kjs_free_value(runtime.context, promiseResult);
          kjs_free_value(runtime.context, result);
          sendPort.send(_ResultError('JS Promise rejected: $errMsg'));
          return;
        }

        // Still pending but no jobs and no bridge requests — deadlock check
        if (!runtime.hasPendingJobs) {
          // One more pump attempt then give up
          runtime.executePendingJobs();
          if (runtime.pendingBridgeCount == 0 && !runtime.hasPendingJobs) {
            runtime.clearDeadline();
            kjs_free_value(runtime.context, result);
            sendPort.send(
              const _ResultError(
                'Promise stuck: no pending jobs or bridge requests',
              ),
            );
            return;
          }
        }
      }

      runtime.clearDeadline();
      kjs_free_value(runtime.context, result);
      sendPort.send(
        const _ResultError(
          'Promise resolution exceeded $maxIterations pump iterations. '
          'This usually means the plugin has an infinite async loop or '
          'is making too many sequential bridge calls in a single handler.',
        ),
      );
    } on Object {
      // Ensure the result JSValue is freed even if an exception is thrown
      // during bridge processing or job pumping.
      runtime.clearDeadline();
      kjs_free_value(runtime.context, result);
      rethrow;
    }
  } on Object catch (e) {
    sendPort.send(_ResultError('$e'));
  }
}
