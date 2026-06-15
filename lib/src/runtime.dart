/// Low-level QuickJS runtime + context wrapper.
///
/// This class manages the lifecycle of a JSRuntime and JSContext pair.
/// It runs on the QuickJS isolate — not directly used by application code.
/// The high-level [QjsEngine] wraps this with an isolate boundary.
library;

import 'dart:convert' show utf8;
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../quickjs_dart.dart' show QjsEngine;
import 'bindings.dart';
import 'constants.dart';
import 'engine.dart' show QjsEngine;
import 'value.dart';

/// Configuration for creating a [QjsRuntime].
class QjsRuntimeConfig {
  const QjsRuntimeConfig({
    this.memoryLimit = 32 * 1024 * 1024,
    this.maxStackSize = 512 * 1024,
    this.gcThreshold = 8 * 1024 * 1024,
    this.executionTimeout = const Duration(seconds: 30),
  });

  /// Memory limit in bytes (default: 32 MB).
  final int memoryLimit;

  /// Max stack size in bytes (default: 512 KB).
  final int maxStackSize;

  /// GC threshold in bytes (default: 8 MB).
  final int gcThreshold;

  /// Max wall-clock time for a single JS execution burst.
  ///
  /// The interrupt handler checks this every ~10,000 branch operations.
  /// Set to [Duration.zero] to disable.
  final Duration executionTimeout;
}

/// Low-level wrapper around a QuickJS runtime and context.
///
/// Manages:
/// - Runtime + context lifecycle
/// - Module loading via source registry
/// - Bridge queue (for async Dart ↔ JS communication)
/// - Promise job pumping
class QjsRuntime {
  QjsRuntime(QjsRuntimeConfig config) {
    _runtime = JS_NewRuntime();
    if (_runtime == ffi.nullptr) {
      throw StateError('Failed to create QuickJS runtime');
    }

    JS_SetMemoryLimit(_runtime, config.memoryLimit);
    JS_SetMaxStackSize(_runtime, config.maxStackSize);
    JS_SetGCThreshold(_runtime, config.gcThreshold);

    _context = JS_NewContext(_runtime);
    if (_context == ffi.nullptr) {
      JS_FreeRuntime(_runtime);
      throw StateError('Failed to create QuickJS context');
    }

    // Set up module loader
    _installModuleLoader();

    // Set up bridge (fjs.bridge_call on globalThis)
    _bridgeQueue = kjs_bridge_init(_runtime, _context);
    if (_bridgeQueue == ffi.nullptr) {
      JS_FreeContext(_context);
      JS_FreeRuntime(_runtime);
      throw StateError('Failed to initialize bridge queue');
    }

    // Inject polyfills for APIs that quickjs-ng (fjs) provided but Bellard's
    // original QuickJS does not: setTimeout, setInterval, URLSearchParams.
    _injectPolyfills();

    _timeoutState = kjs_timeout_new();
    if (_timeoutState == ffi.nullptr) {
      kjs_bridge_cleanup(_bridgeQueue);
      JS_FreeContext(_context);
      JS_FreeRuntime(_runtime);
      throw StateError('Failed to allocate timeout state');
    }
    kjs_timeout_install(_runtime, _timeoutState);
    _executionTimeoutMs = config.executionTimeout.inMilliseconds;
  }

  late final ffi.Pointer<JSRuntime> _runtime;
  late final ffi.Pointer<JSContext> _context;
  late final ffi.Pointer<KjsBridgeQueue> _bridgeQueue;
  var _disposed = false;
  late final ffi.Pointer<KjsTimeoutState> _timeoutState;
  late final int _executionTimeoutMs;

  /// Reusable size pointer for bridge payload peeks — avoids allocating
  /// `calloc<ffi.Size>()` on every call in the hot pump loop path.
  final ffi.Pointer<ffi.Size> _bridgeSizePtr = calloc<ffi.Size>();

  /// The raw JSContext pointer.
  ///
  /// Exposed for the isolate-side code in [QjsEngine] that needs to call
  /// [jsValueToDart] and [kjs_free_value] directly. Throws [StateError] if
  /// the runtime has been disposed — defends against use-after-free if a
  /// future refactor breaks the message-ordering invariants that currently
  /// keep `resolveBridge` / `rejectBridge` from firing post-dispose.
  ffi.Pointer<JSContext> get context {
    _assertNotDisposed();
    return _context;
  }

  /// Whether the JS runtime has pending jobs (promise continuations, etc.).
  bool get hasPendingJobs => JS_IsJobPending(_runtime);

  /// Registry of module source code, keyed by module name.
  /// Used by the module loader callback.
  final Map<String, String> _moduleRegistry = {};

  /// Global static registry — maps runtime pointer to QjsRuntime instance.
  /// Needed because the module loader callback is a static function.
  static final Map<int, QjsRuntime> _instances = {};

  // ---------------------------------------------------------------------------
  // Polyfills
  // ---------------------------------------------------------------------------

  /// Injects polyfills for web APIs not provided by Bellard's QuickJS.
  ///
  /// - `setTimeout` / `clearTimeout` — implemented via bridge call to Dart,
  ///   which delays for the requested duration using `Future.delayed`.
  /// - `setInterval` / `clearInterval` — not implemented (throws).
  /// - `URLSearchParams` — minimal implementation covering toString/get/set.
  void _injectPolyfills() {
    final result = evalRaw(_polyfillSource, filename: '<polyfill>');
    if (result.isException) {
      // Non-fatal — log and continue. Plugins that need these will fail at
      // call-site with a clear error.
      if (result.hasRefCount) {
        kjs_free_value(_context, result);
      }
      return;
    }
    if (result.hasRefCount) {
      kjs_free_value(_context, result);
    }
  }

  // ---------------------------------------------------------------------------
  // Module management
  // ---------------------------------------------------------------------------

  /// Registers a module source for the loader without evaluating it.
  ///
  /// When JS code does `import ... from 'name'`, the module loader will
  /// find this source and compile it.
  void declareModule(String name, String source) {
    _assertNotDisposed();
    _moduleRegistry[name] = source;
  }

  /// Evaluates JS code as an ES module.
  ///
  /// The module is registered under [name] and executed immediately.
  void evalModule(String name, String source) {
    _assertNotDisposed();
    _updateStackTop();

    // Also register so it can be imported later
    _moduleRegistry[name] = source;

    final (codePtr, codeLen) = _toNativeUtf8WithLength(source);
    final namePtr = name.toNativeUtf8();

    try {
      final result = JS_Eval(
        _context,
        codePtr,
        codeLen,
        namePtr,
        JsEvalFlag.typeModule,
      );

      if (result.isException) {
        throw extractException();
      }

      if (result.hasRefCount) {
        kjs_free_value(_context, result);
      }
    } finally {
      calloc
        ..free(codePtr)
        ..free(namePtr);
    }
  }

  // ---------------------------------------------------------------------------
  // Evaluation
  // ---------------------------------------------------------------------------

  /// Evaluates JS code as a global script. Returns the result as a Dart value.
  ///
  /// Does NOT pump the job queue — call [executePendingJobs] for promise resolution.
  JSValue evalRaw(String code, {String filename = '<eval>'}) {
    _assertNotDisposed();
    _updateStackTop();

    final (codePtr, codeLen) = _toNativeUtf8WithLength(code);
    final namePtr = filename.toNativeUtf8();

    try {
      return JS_Eval(
        _context,
        codePtr,
        codeLen,
        namePtr,
        JsEvalFlag.typeGlobal,
      );
    } finally {
      calloc
        ..free(codePtr)
        ..free(namePtr);
    }
  }

  /// Evaluates JS code and converts the result to a Dart value.
  ///
  /// This does NOT handle promises. Use [QjsEngine.eval] for full async
  /// support with bridge call processing.
  dynamic evalSync(String code, {String filename = '<eval>'}) {
    final result = evalRaw(code, filename: filename);
    return jsValueToDart(_context, result, freeValue: true);
  }

  // ---------------------------------------------------------------------------
  // Promise / Bridge support
  // ---------------------------------------------------------------------------

  /// Returns the number of pending bridge requests.
  int get pendingBridgeCount => kjs_bridge_pending_count(_bridgeQueue);

  /// Peeks at the next bridge request payload as a JSON string.
  /// Returns null if no requests pending.
  String? peekBridgePayload() {
    final ptr = kjs_bridge_peek_payload(_bridgeQueue, _bridgeSizePtr);
    if (ptr == ffi.nullptr) {
      return null;
    }
    return ptr.toDartString(length: _bridgeSizePtr.value);
  }

  /// Peeks at ALL pending bridge request payloads as JSON strings.
  ///
  /// Returns them in FIFO order (index 0 = head of queue).
  List<String> peekAllBridgePayloads() {
    final count = pendingBridgeCount;
    if (count == 0) {
      return const [];
    }

    final payloads = <String>[];

    for (var i = 0; i < count; i++) {
      final ptr = kjs_bridge_peek_payload_at(_bridgeQueue, i, _bridgeSizePtr);
      if (ptr == ffi.nullptr) {
        break;
      }
      payloads.add(ptr.toDartString(length: _bridgeSizePtr.value));
    }

    return payloads;
  }

  /// Resolves the next pending bridge request with a result.
  ///
  /// [resultJson] is the JSON-encoded result value.
  ///
  /// Throws [StateError] if the runtime has been disposed. The current
  /// engine protocol prevents this from happening (see [dispose] sequencing
  /// in `engine.dart`), but the guard hardens against future drift.
  void resolveBridge(String resultJson) {
    _assertNotDisposed();
    _updateStackTop();
    final ptr = resultJson.toNativeUtf8();
    kjs_bridge_resolve(_bridgeQueue, ptr);
    calloc.free(ptr);
  }

  /// Rejects the next pending bridge request with an error message.
  ///
  /// Throws [StateError] if the runtime has been disposed.
  void rejectBridge(String errorMessage) {
    _assertNotDisposed();
    final ptr = errorMessage.toNativeUtf8();
    kjs_bridge_reject(_bridgeQueue, ptr);
    calloc.free(ptr);
  }

  /// Pumps pending JS jobs (promise continuations, etc.).
  ///
  /// Returns the number of jobs executed.
  int executePendingJobs() {
    _updateStackTop();
    final pctx = calloc<ffi.Pointer<JSContext>>();
    var count = 0;

    try {
      while (JS_IsJobPending(_runtime)) {
        final ret = JS_ExecutePendingJob(_runtime, pctx);
        if (ret < 0) {
          // Job threw an exception — extract and rethrow
          throw extractException();
        }
        count++;
      }
    } finally {
      calloc.free(pctx);
    }

    return count;
  }

  /// Checks if a JSValue is a promise (by checking for PromiseState).
  bool isPromise(JSValue value) {
    if (!value.isObject) {
      return false;
    }
    // JS_PromiseState returns 0 (pending), 1 (fulfilled), 2 (rejected)
    // for promises, but for non-promises it returns... we need to check.
    // Actually, we check if the object has a .then property that is a function.
    final thenProp = 'then'.toNativeUtf8();
    final thenVal = JS_GetPropertyStr(_context, value, thenProp);
    calloc.free(thenProp);

    final isFn = JS_IsFunction(_context, thenVal);
    if (thenVal.hasRefCount) {
      kjs_free_value(_context, thenVal);
    }
    return isFn;
  }

  /// Gets the promise state: 0=pending, 1=fulfilled, 2=rejected.
  int promiseState(JSValue promise) => JS_PromiseState(_context, promise);

  /// Gets the promise result (only valid if fulfilled or rejected).
  JSValue promiseResult(JSValue promise) => JS_PromiseResult(_context, promise);

  /// Extracts a human-readable error message from a JS value.
  ///
  /// JS `Error` objects have non-enumerable `.message` and `.stack` properties,
  /// so `JSON.stringify(error)` produces `"{}"`. This reads those properties
  /// directly. Falls back to [jsValueToDart] for non-Error values.
  ///
  /// Does NOT free [value] — caller is responsible for cleanup.
  String extractErrorString(JSValue value) {
    // Try reading .message property
    final msgKey = 'message'.toNativeUtf8();
    final msgVal = JS_GetPropertyStr(_context, value, msgKey);
    calloc.free(msgKey);

    if (!msgVal.isUndefined && !msgVal.isNull) {
      final plen = calloc<ffi.Size>();
      final cstr = JS_ToCStringLen2(_context, plen, msgVal);
      if (msgVal.hasRefCount) {
        kjs_free_value(_context, msgVal);
      }

      if (cstr != ffi.nullptr) {
        final message = cstr.toDartString(length: plen.value);
        calloc.free(plen);
        JS_FreeCString(_context, cstr);

        // Also try .stack
        final stackKey = 'stack'.toNativeUtf8();
        final stackVal = JS_GetPropertyStr(_context, value, stackKey);
        calloc.free(stackKey);

        if (!stackVal.isUndefined && !stackVal.isNull) {
          final slen = calloc<ffi.Size>();
          final scstr = JS_ToCStringLen2(_context, slen, stackVal);
          if (stackVal.hasRefCount) {
            kjs_free_value(_context, stackVal);
          }
          if (scstr != ffi.nullptr) {
            final stack = scstr.toDartString(length: slen.value);
            calloc.free(slen);
            JS_FreeCString(_context, scstr);
            return '$message\n$stack';
          }
          calloc.free(slen);
        } else if (stackVal.hasRefCount) {
          kjs_free_value(_context, stackVal);
        }

        return message;
      }
      calloc.free(plen);
    } else if (msgVal.hasRefCount) {
      kjs_free_value(_context, msgVal);
    }

    // Not an Error object — fall back to generic conversion.
    return '${jsValueToDart(_context, value, freeValue: false)}';
  }

  /// Extracts a resolved/settled value from a promise.
  dynamic extractPromiseResult(JSValue promise) {
    final state = promiseState(promise);
    if (state == 0) {
      throw StateError('Promise is still pending');
    }

    final result = promiseResult(promise);
    if (state == 2) {
      // Rejected — extract error
      final msg = jsValueToDart(_context, result, freeValue: true);
      throw Exception('JS Promise rejected: $msg');
    }

    return jsValueToDart(_context, result, freeValue: true);
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Disposes the runtime and frees all resources.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;

    _instances.remove(_runtime.address);

    calloc.free(_bridgeSizePtr);
    kjs_timeout_free(_timeoutState);
    kjs_bridge_cleanup(_bridgeQueue);
    JS_FreeContext(_context);
    JS_FreeRuntime(_runtime);
  }

  // ---------------------------------------------------------------------------
  // Module loader
  // ---------------------------------------------------------------------------

  void _installModuleLoader() {
    // Register this instance for the static callback
    _instances[_runtime.address] = this;

    // Set the module loader. We pass the runtime pointer as opaque data
    // so the static callback can look up the QjsRuntime instance.
    JS_SetModuleLoaderFunc(
      _runtime,
      ffi.Pointer.fromFunction(_moduleNormalize),
      ffi.Pointer.fromFunction(_moduleLoader),
      _runtime.cast(),
    );
  }

  /// Static module normalize callback.
  ///
  /// Returns the module name as-is (no path resolution needed).
  /// Uses [js_strdup] to allocate with the JS allocator — QuickJS will
  /// free the returned string with `js_free`.
  static ffi.Pointer<Utf8> _moduleNormalize(
    ffi.Pointer<JSContext> ctx,
    ffi.Pointer<Utf8> moduleBaseName,
    ffi.Pointer<Utf8> moduleName,
    ffi.Pointer<ffi.Void> opaque,
  ) => js_strdup(ctx, moduleName);

  /// Static module loader callback.
  ///
  /// Called when JS encounters an `import` for a module name.
  /// Looks up the source in the module registry and compiles it.
  static ffi.Pointer<JSModuleDef> _moduleLoader(
    ffi.Pointer<JSContext> ctx,
    ffi.Pointer<Utf8> moduleName,
    ffi.Pointer<ffi.Void> opaque,
  ) {
    final name = moduleName.toDartString();
    final rt = opaque.cast<JSRuntime>();
    final instance = _instances[rt.address];

    if (instance == null) {
      return ffi.nullptr;
    }

    final source = instance._moduleRegistry[name];
    if (source == null) {
      return ffi.nullptr;
    }

    // Compile the module (compile-only, don't execute)
    final (codePtr, codeLen) = _toNativeUtf8WithLength(source);
    final namePtr = name.toNativeUtf8();

    final funcVal = JS_Eval(
      ctx,
      codePtr,
      codeLen,
      namePtr,
      JsEvalFlag.typeModule | JsEvalFlag.compileOnly,
    );

    calloc
      ..free(codePtr)
      ..free(namePtr);

    if (funcVal.isException) {
      return ffi.nullptr;
    }

    // The compiled module is a function bytecode object.
    // JS_EvalFunction will instantiate and evaluate it, returning the module def.
    // But the module loader should return JSModuleDef*, not evaluate.
    // The trick: JS_VALUE_GET_PTR extracts the pointer from the JSValue.
    // For a module bytecode object, the ptr IS the JSModuleDef*.
    final modulePtr = ffi.Pointer<JSModuleDef>.fromAddress(funcVal.u);

    return modulePtr;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('QjsRuntime has been disposed');
    }
  }

  /// Encodes [s] to a null-terminated native UTF-8 buffer, returning both the
  /// pointer and the **byte length** (excluding the null terminator).
  ///
  /// This avoids the double-encoding that occurs when calling `toNativeUtf8()`
  /// (which encodes once) followed by `utf8.encode(s).length` (which encodes
  /// again just to get the byte count).
  static (ffi.Pointer<Utf8>, int) _toNativeUtf8WithLength(String s) {
    final encoded = utf8.encode(s);
    final len = encoded.length;
    final ptr = calloc<ffi.Uint8>(len + 1); // +1 for null terminator
    ptr.asTypedList(len).setAll(0, encoded);
    ptr[len] = 0;
    return (ptr.cast<Utf8>(), len);
  }

  /// Updates the stack top pointer for stack overflow detection.
  ///
  /// Required when the runtime is used from a different call-stack depth
  /// than where it was created (e.g. inside an isolate message handler
  /// callback vs the top-level isolate entry point).
  void _updateStackTop() => JS_UpdateStackTop(_runtime);

  /// Sets the execution deadline to [timeoutMs] milliseconds from now.
  ///
  /// If [timeoutMs] is 0, uses the default from [QjsRuntimeConfig].
  /// If the config timeout is also 0 (disabled), does nothing.
  void setDeadline([int timeoutMs = 0]) {
    final ms = timeoutMs > 0 ? timeoutMs : _executionTimeoutMs;
    if (ms > 0) {
      kjs_timeout_set(_timeoutState, ms);
    }
  }

  /// Clears the execution deadline (disables timeout).
  void clearDeadline() => kjs_timeout_clear(_timeoutState);

  /// Extracts the current pending exception from the JS context.
  ///
  /// Reads the `.message` and `.stack` properties from the exception object
  /// and returns a Dart [Exception]. The JS exception value is freed.
  Exception extractException() {
    final exception = JS_GetException(_context);
    var message = 'Unknown JS error';
    String? stack;

    final msgKey = 'message'.toNativeUtf8();
    final msgVal = JS_GetPropertyStr(_context, exception, msgKey);
    calloc.free(msgKey);

    if (!msgVal.isUndefined && msgVal.isString) {
      final plen = calloc<ffi.Size>();
      final cstr = JS_ToCStringLen2(_context, plen, msgVal);
      if (cstr != ffi.nullptr) {
        message = cstr.toDartString(length: plen.value);
        JS_FreeCString(_context, cstr);
      }
      calloc.free(plen);
    }
    if (msgVal.hasRefCount) {
      kjs_free_value(_context, msgVal);
    }

    final stackKey = 'stack'.toNativeUtf8();
    final stackVal = JS_GetPropertyStr(_context, exception, stackKey);
    calloc.free(stackKey);

    if (!stackVal.isUndefined && stackVal.isString) {
      final plen = calloc<ffi.Size>();
      final cstr = JS_ToCStringLen2(_context, plen, stackVal);
      if (cstr != ffi.nullptr) {
        stack = cstr.toDartString(length: plen.value);
        JS_FreeCString(_context, cstr);
      }
      calloc.free(plen);
    }
    if (stackVal.hasRefCount) {
      kjs_free_value(_context, stackVal);
    }

    if (exception.hasRefCount) {
      kjs_free_value(_context, exception);
    }

    if (stack != null) {
      return Exception('$message\n$stack');
    }
    return Exception(message);
  }
}

// =============================================================================
// Polyfill source for web APIs not available in Bellard's QuickJS.
// =============================================================================

/// Polyfill JS source injected into every QjsRuntime at construction time.
///
/// Provides:
/// - `setTimeout(fn, delay)` / `clearTimeout(id)` — via bridge call to Dart;
///   the Dart side delays for the requested duration (capped at 60 s).
/// - `setInterval(fn, delay)` / `clearInterval(id)` — stub that throws
///   (not needed by current plugins; can be implemented later).
/// - `URLSearchParams` — minimal implementation covering the subset used by
///   plugins: constructor from string/object/entries, `get`, `set`, `has`,
///   `append`, `delete`, `toString`, `keys`, `values`, `entries`, `forEach`.
const _polyfillSource = '''
// -- setTimeout / clearTimeout polyfill --
// Bellard's QuickJS has no real event loop. We implement setTimeout via
// fjs.bridge_call() so that timer resolution participates in the same
// async pump loop as fetch/storage calls. The Dart side delays for the
// requested duration using Future.delayed (capped at 60 s). Combined
// with streamed batch responses, this means a fetch at batch index 0
// that completes at 2 s is resolved immediately — not held up by a
// 10 s timer at index 1.
(function() {
  var _nextTimerId = 1;
  var _activeTimers = {};

  globalThis.setTimeout = function(fn, delay) {
    var id = _nextTimerId++;
    _activeTimers[id] = true;
    // Route through the bridge so the timer participates in the pump loop.
    // The Dart side will resolve this after `delay` milliseconds.
    fjs.bridge_call({ action: "_timer", args: { ms: delay || 0 } }).then(
      function() {
        if (_activeTimers[id]) {
          delete _activeTimers[id];
          fn();
        }
      }
    );
    return id;
  };

  globalThis.clearTimeout = function(id) {
    delete _activeTimers[id];
  };

  globalThis.setInterval = function() {
    throw new Error("setInterval is not supported in this runtime");
  };

  globalThis.clearInterval = function() {};
})();

// -- URLSearchParams polyfill --
(function() {
  function URLSearchParams(init) {
    this._entries = [];

    if (typeof init === "string") {
      var s = init;
      if (s.charAt(0) === "?") s = s.slice(1);
      var pairs = s.split("&");
      for (var i = 0; i < pairs.length; i++) {
        var pair = pairs[i];
        if (pair === "") continue;
        var eq = pair.indexOf("=");
        if (eq === -1) {
          this._entries.push([decodeURIComponent(pair), ""]);
        } else {
          this._entries.push([
            decodeURIComponent(pair.slice(0, eq)),
            decodeURIComponent(pair.slice(eq + 1))
          ]);
        }
      }
    } else if (init && typeof init === "object") {
      if (Array.isArray(init)) {
        for (var i = 0; i < init.length; i++) {
          this._entries.push([String(init[i][0]), String(init[i][1])]);
        }
      } else {
        var keys = Object.keys(init);
        for (var i = 0; i < keys.length; i++) {
          this._entries.push([keys[i], String(init[keys[i]])]);
        }
      }
    }
  }

  URLSearchParams.prototype.get = function(name) {
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === name) return this._entries[i][1];
    }
    return null;
  };

  URLSearchParams.prototype.set = function(name, value) {
    var found = false;
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === name) {
        if (!found) {
          this._entries[i][1] = String(value);
          found = true;
        } else {
          this._entries.splice(i, 1);
          i--;
        }
      }
    }
    if (!found) this._entries.push([name, String(value)]);
  };

  URLSearchParams.prototype.has = function(name) {
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === name) return true;
    }
    return false;
  };

  URLSearchParams.prototype.append = function(name, value) {
    this._entries.push([name, String(value)]);
  };

  URLSearchParams.prototype.delete = function(name) {
    for (var i = this._entries.length - 1; i >= 0; i--) {
      if (this._entries[i][0] === name) this._entries.splice(i, 1);
    }
  };

  URLSearchParams.prototype.toString = function() {
    return this._entries.map(function(e) {
      return encodeURIComponent(e[0]) + "=" + encodeURIComponent(e[1]);
    }).join("&");
  };

  URLSearchParams.prototype.keys = function() {
    return this._entries.map(function(e) { return e[0]; });
  };

  URLSearchParams.prototype.values = function() {
    return this._entries.map(function(e) { return e[1]; });
  };

  URLSearchParams.prototype.entries = function() {
    return this._entries.slice();
  };

  URLSearchParams.prototype.forEach = function(callback, thisArg) {
    for (var i = 0; i < this._entries.length; i++) {
      callback.call(thisArg, this._entries[i][1], this._entries[i][0], this);
    }
  };

  globalThis.URLSearchParams = URLSearchParams;
})();
''';
