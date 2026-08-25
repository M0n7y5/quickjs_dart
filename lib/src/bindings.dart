/// Low-level FFI bindings for QuickJS + qjs_shim.
///
/// Uses @ffi.Native with @DefaultAsset to automatically bind to the
/// compiled shared library (resolved by native_assets_cli).
///
/// Functions prefixed with `qjs_` are from our C shim (wrappers around
/// static-inline QuickJS functions). Functions without prefix are real
/// exported symbols from QuickJS.
// ignore_for_file: non_constant_identifier_names

@ffi.DefaultAsset('package:quickjs_dart/src/bindings.dart')
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'constants.dart' show JsTag;

// ============================================================
// Opaque types
// ============================================================

final class JSRuntime extends ffi.Opaque {}

final class JSContext extends ffi.Opaque {}

final class JSModuleDef extends ffi.Opaque {}

final class QjsBridgeQueue extends ffi.Opaque {}

final class QjsTimeoutState extends ffi.Opaque {}

// ============================================================
// JSValue — 16-byte struct on 64-bit (non-NaN-boxing mode)
//
// Layout: { JSValueUnion u (8 bytes), int64_t tag (8 bytes) }
// ============================================================

final class JSValue extends ffi.Struct {
  /// The union value — stores int32, float64, or pointer depending on tag.
  @ffi.Int64()
  external int u;

  /// The type tag (see [JsTag]).
  @ffi.Int64()
  external int tag;
}

// ============================================================
// Runtime management
// ============================================================

@ffi.Native<ffi.Pointer<JSRuntime> Function()>()
external ffi.Pointer<JSRuntime> JS_NewRuntime();

@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>)>()
external void JS_FreeRuntime(ffi.Pointer<JSRuntime> rt);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>, ffi.Size)>()
external void JS_SetMemoryLimit(ffi.Pointer<JSRuntime> rt, int limit);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>, ffi.Size)>()
external void JS_SetMaxStackSize(ffi.Pointer<JSRuntime> rt, int stackSize);

/// Updates the stack top pointer used for stack overflow detection.
///
/// Must be called when the runtime is used from a different call-stack depth
/// than where it was created (e.g. inside an isolate message handler).
@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>)>()
external void JS_UpdateStackTop(ffi.Pointer<JSRuntime> rt);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>, ffi.Size)>()
external void JS_SetGCThreshold(ffi.Pointer<JSRuntime> rt, int threshold);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>)>()
external void JS_RunGC(ffi.Pointer<JSRuntime> rt);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>, ffi.Pointer<ffi.Void>)>()
external void JS_SetRuntimeOpaque(
  ffi.Pointer<JSRuntime> rt,
  ffi.Pointer<ffi.Void> opaque,
);

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<JSRuntime>)>()
external ffi.Pointer<ffi.Void> JS_GetRuntimeOpaque(ffi.Pointer<JSRuntime> rt);

// ============================================================
// Context management
// ============================================================

@ffi.Native<ffi.Pointer<JSContext> Function(ffi.Pointer<JSRuntime>)>()
external ffi.Pointer<JSContext> JS_NewContext(ffi.Pointer<JSRuntime> rt);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_FreeContext(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Pointer<JSRuntime> Function(ffi.Pointer<JSContext>)>()
external ffi.Pointer<JSRuntime> JS_GetRuntime(ffi.Pointer<JSContext> ctx);

// ============================================================
// Evaluation
// ============================================================

@ffi.Native<
  JSValue Function(
    ffi.Pointer<JSContext>,
    ffi.Pointer<Utf8>,
    ffi.Size,
    ffi.Pointer<Utf8>,
    ffi.Int32,
  )
>()
external JSValue JS_Eval(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<Utf8> input,
  int inputLen,
  ffi.Pointer<Utf8> filename,
  int evalFlags,
);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, JSValue)>()
external JSValue JS_EvalFunction(ffi.Pointer<JSContext> ctx, JSValue funObj);

// ============================================================
// Global object
// ============================================================

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>)>()
external JSValue JS_GetGlobalObject(ffi.Pointer<JSContext> ctx);

// ============================================================
// Value creation (via C shim — these are static inline in quickjs.h)
// ============================================================

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, ffi.Int32)>()
external JSValue qjs_new_bool(ffi.Pointer<JSContext> ctx, int val);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, ffi.Int32)>()
external JSValue qjs_new_int32(ffi.Pointer<JSContext> ctx, int val);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, ffi.Int64)>()
external JSValue qjs_new_int64(ffi.Pointer<JSContext> ctx, int val);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, ffi.Double)>()
external JSValue qjs_new_float64(ffi.Pointer<JSContext> ctx, double val);

@ffi.Native<
  JSValue Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, ffi.Size)
>()
external JSValue JS_NewStringLen(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<Utf8> str,
  int len,
);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>)>()
external JSValue qjs_new_string(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<Utf8> str,
);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>)>()
external JSValue JS_NewObject(ffi.Pointer<JSContext> ctx);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>)>()
external JSValue JS_NewArray(ffi.Pointer<JSContext> ctx);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, ffi.Int64)>()
external JSValue JS_NewBigInt64(ffi.Pointer<JSContext> ctx, int val);

@ffi.Native<JSValue Function()>()
external JSValue qjs_null();

@ffi.Native<JSValue Function()>()
external JSValue qjs_undefined();

@ffi.Native<JSValue Function()>()
external JSValue qjs_exception();

// ============================================================
// Value memory management (via C shim)
// ============================================================

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>, JSValue)>()
external void qjs_free_value(ffi.Pointer<JSContext> ctx, JSValue val);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>, JSValue)>()
external void qjs_free_value_rt(ffi.Pointer<JSRuntime> rt, JSValue val);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, JSValue)>()
external JSValue qjs_dup_value(ffi.Pointer<JSContext> ctx, JSValue val);

// ============================================================
// Type checking (via C shim)
// ============================================================

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_value_get_tag(JSValue val);

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_value_get_norm_tag(JSValue val);

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_is_number(JSValue val);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<JSContext>, JSValue)>()
external int qjs_is_big_int(ffi.Pointer<JSContext> ctx, JSValue val);

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_is_bool(JSValue val);

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_is_null(JSValue val);

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_is_undefined(JSValue val);

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_is_exception(JSValue val);

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_is_string(JSValue val);

@ffi.Native<ffi.Int32 Function(JSValue)>()
external int qjs_is_object(JSValue val);

@ffi.Native<ffi.Bool Function(ffi.Pointer<JSContext>, JSValue)>()
external bool JS_IsFunction(ffi.Pointer<JSContext> ctx, JSValue val);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<JSContext>, JSValue)>()
external int JS_IsArray(ffi.Pointer<JSContext> ctx, JSValue val);

@ffi.Native<ffi.Bool Function(ffi.Pointer<JSContext>, JSValue)>()
external bool JS_IsError(ffi.Pointer<JSContext> ctx, JSValue val);

// ============================================================
// Type conversion — reading values
// ============================================================

@ffi.Native<
  ffi.Pointer<Utf8> Function(
    ffi.Pointer<JSContext>,
    ffi.Pointer<ffi.Size>,
    JSValue,
    ffi.Bool,
  )
>(symbol: 'JS_ToCStringLen2')
external ffi.Pointer<Utf8> _JS_ToCStringLen2(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<ffi.Size> plen,
  JSValue val,
  bool cesu8,
);

/// Dart-friendly wrapper around `_JS_ToCStringLen2` with a named [cesu8]
/// parameter (defaults to `false`).
ffi.Pointer<Utf8> JS_ToCStringLen2(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<ffi.Size> plen,
  JSValue val, {
  bool cesu8 = false,
}) => _JS_ToCStringLen2(ctx, plen, val, cesu8);

@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Pointer<JSContext>, JSValue)>()
external ffi.Pointer<Utf8> qjs_to_c_string(
  ffi.Pointer<JSContext> ctx,
  JSValue val,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>)>()
external void JS_FreeCString(ffi.Pointer<JSContext> ctx, ffi.Pointer<Utf8> ptr);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<JSContext>, JSValue)>()
external int JS_ToBool(ffi.Pointer<JSContext> ctx, JSValue val);

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int32>, JSValue)
>()
external int JS_ToInt32(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<ffi.Int32> pres,
  JSValue val,
);

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int64>, JSValue)
>()
external int JS_ToInt64(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<ffi.Int64> pres,
  JSValue val,
);

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Double>, JSValue)
>()
external int JS_ToFloat64(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<ffi.Double> pres,
  JSValue val,
);

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int64>, JSValue)
>()
external int JS_ToBigInt64(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<ffi.Int64> pres,
  JSValue val,
);

// ============================================================
// Property access
// ============================================================

@ffi.Native<
  JSValue Function(ffi.Pointer<JSContext>, JSValue, ffi.Pointer<Utf8>)
>()
external JSValue JS_GetPropertyStr(
  ffi.Pointer<JSContext> ctx,
  JSValue thisObj,
  ffi.Pointer<Utf8> prop,
);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, JSValue, ffi.Uint32)>()
external JSValue JS_GetPropertyUint32(
  ffi.Pointer<JSContext> ctx,
  JSValue thisObj,
  int idx,
);

@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<JSContext>,
    JSValue,
    ffi.Pointer<Utf8>,
    JSValue,
  )
>()
external int JS_SetPropertyStr(
  ffi.Pointer<JSContext> ctx,
  JSValue thisObj,
  ffi.Pointer<Utf8> prop,
  JSValue val,
);

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<JSContext>, JSValue, ffi.Uint32, JSValue)
>()
external int JS_SetPropertyUint32(
  ffi.Pointer<JSContext> ctx,
  JSValue thisObj,
  int idx,
  JSValue val,
);

// ============================================================
// Function calling
// ============================================================

@ffi.Native<
  JSValue Function(
    ffi.Pointer<JSContext>,
    JSValue,
    JSValue,
    ffi.Int32,
    ffi.Pointer<JSValue>,
  )
>()
external JSValue JS_Call(
  ffi.Pointer<JSContext> ctx,
  JSValue funcObj,
  JSValue thisObj,
  int argc,
  ffi.Pointer<JSValue> argv,
);

// ============================================================
// JSON
// ============================================================

@ffi.Native<
  JSValue Function(
    ffi.Pointer<JSContext>,
    ffi.Pointer<Utf8>,
    ffi.Size,
    ffi.Pointer<Utf8>,
  )
>()
external JSValue JS_ParseJSON(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<Utf8> buf,
  int bufLen,
  ffi.Pointer<Utf8> filename,
);

@ffi.Native<
  JSValue Function(ffi.Pointer<JSContext>, JSValue, JSValue, JSValue)
>()
external JSValue JS_JSONStringify(
  ffi.Pointer<JSContext> ctx,
  JSValue obj,
  JSValue replacer,
  JSValue space,
);

// ============================================================
// Exception handling
// ============================================================

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>)>()
external JSValue JS_GetException(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Bool Function(ffi.Pointer<JSContext>)>()
external bool JS_HasException(ffi.Pointer<JSContext> ctx);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, JSValue)>()
external JSValue JS_Throw(ffi.Pointer<JSContext> ctx, JSValue obj);

// ============================================================
// Promise / Job queue
// ============================================================

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, ffi.Pointer<JSValue>)>()
external JSValue JS_NewPromiseCapability(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<JSValue> resolvingFuncs,
);

@ffi.Native<ffi.Bool Function(ffi.Pointer<JSRuntime>)>()
external bool JS_IsJobPending(ffi.Pointer<JSRuntime> rt);

@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<JSRuntime>,
    ffi.Pointer<ffi.Pointer<JSContext>>,
  )
>()
external int JS_ExecutePendingJob(
  ffi.Pointer<JSRuntime> rt,
  ffi.Pointer<ffi.Pointer<JSContext>> pctx,
);

// ============================================================
// Module system
// ============================================================

/// Module loader callback type.
/// JSModuleDef* (*)(JSContext*, const char* module_name, void* opaque)
typedef JSModuleLoaderFuncNative =
    ffi.Pointer<JSModuleDef> Function(
      ffi.Pointer<JSContext> ctx,
      ffi.Pointer<Utf8> moduleName,
      ffi.Pointer<ffi.Void> opaque,
    );

/// Module normalize callback type.
/// char* (*)(JSContext*, const char* base, const char* name, void* opaque)
typedef JSModuleNormalizeFuncNative =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<JSContext> ctx,
      ffi.Pointer<Utf8> moduleBaseName,
      ffi.Pointer<Utf8> moduleName,
      ffi.Pointer<ffi.Void> opaque,
    );

@ffi.Native<
  ffi.Void Function(
    ffi.Pointer<JSRuntime>,
    ffi.Pointer<ffi.NativeFunction<JSModuleNormalizeFuncNative>>,
    ffi.Pointer<ffi.NativeFunction<JSModuleLoaderFuncNative>>,
    ffi.Pointer<ffi.Void>,
  )
>()
external void JS_SetModuleLoaderFunc(
  ffi.Pointer<JSRuntime> rt,
  ffi.Pointer<ffi.NativeFunction<JSModuleNormalizeFuncNative>> moduleNormalize,
  ffi.Pointer<ffi.NativeFunction<JSModuleLoaderFuncNative>> moduleLoader,
  ffi.Pointer<ffi.Void> opaque,
);

@ffi.Native<
  JSValue Function(ffi.Pointer<JSContext>, ffi.Pointer<JSModuleDef>)
>()
external JSValue JS_GetModuleNamespace(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<JSModuleDef> m,
);

// ============================================================
// Promise state inspection
// ============================================================

/// 0 = pending, 1 = fulfilled, 2 = rejected
@ffi.Native<ffi.Int32 Function(ffi.Pointer<JSContext>, JSValue)>()
external int JS_PromiseState(ffi.Pointer<JSContext> ctx, JSValue promise);

@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, JSValue)>()
external JSValue JS_PromiseResult(ffi.Pointer<JSContext> ctx, JSValue promise);

// ============================================================
// Bridge queue (from qjs_shim.c)
// ============================================================

@ffi.Native<
  ffi.Pointer<QjsBridgeQueue> Function(
    ffi.Pointer<JSRuntime>,
    ffi.Pointer<JSContext>,
  )
>()
external ffi.Pointer<QjsBridgeQueue> qjs_bridge_init(
  ffi.Pointer<JSRuntime> rt,
  ffi.Pointer<JSContext> ctx,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<QjsBridgeQueue>)>()
external void qjs_bridge_cleanup(ffi.Pointer<QjsBridgeQueue> q);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<QjsBridgeQueue>)>()
external int qjs_bridge_pending_count(ffi.Pointer<QjsBridgeQueue> q);

@ffi.Native<
  ffi.Pointer<Utf8> Function(ffi.Pointer<QjsBridgeQueue>, ffi.Pointer<ffi.Size>)
>()
external ffi.Pointer<Utf8> qjs_bridge_peek_payload(
  ffi.Pointer<QjsBridgeQueue> q,
  ffi.Pointer<ffi.Size> outLen,
);

@ffi.Native<
  ffi.Pointer<Utf8> Function(
    ffi.Pointer<QjsBridgeQueue>,
    ffi.Int32,
    ffi.Pointer<ffi.Size>,
  )
>()
external ffi.Pointer<Utf8> qjs_bridge_peek_payload_at(
  ffi.Pointer<QjsBridgeQueue> q,
  int index,
  ffi.Pointer<ffi.Size> outLen,
);

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<QjsBridgeQueue>, ffi.Pointer<Utf8>)
>()
external int qjs_bridge_resolve(
  ffi.Pointer<QjsBridgeQueue> q,
  ffi.Pointer<Utf8> resultJson,
);

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<QjsBridgeQueue>, ffi.Pointer<Utf8>)
>()
external int qjs_bridge_reject(
  ffi.Pointer<QjsBridgeQueue> q,
  ffi.Pointer<Utf8> errorMessage,
);

// ============================================================
// Execution timeout (from qjs_shim.c)
// ============================================================

@ffi.Native<ffi.Pointer<QjsTimeoutState> Function()>()
external ffi.Pointer<QjsTimeoutState> qjs_timeout_new();

@ffi.Native<ffi.Void Function(ffi.Pointer<QjsTimeoutState>)>()
external void qjs_timeout_free(ffi.Pointer<QjsTimeoutState> state);

@ffi.Native<ffi.Void Function(ffi.Pointer<QjsTimeoutState>, ffi.Int64)>()
external void qjs_timeout_set(
  ffi.Pointer<QjsTimeoutState> state,
  int timeoutMs,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<QjsTimeoutState>)>()
external void qjs_timeout_clear(ffi.Pointer<QjsTimeoutState> state);

@ffi.Native<
  ffi.Void Function(ffi.Pointer<JSRuntime>, ffi.Pointer<QjsTimeoutState>)
>()
external void qjs_timeout_install(
  ffi.Pointer<JSRuntime> rt,
  ffi.Pointer<QjsTimeoutState> state,
);

// ============================================================
// Memory allocation (JS allocator)
// ============================================================

/// Duplicates a string using the JS allocator.
///
/// Returns a pointer that QuickJS will free with `js_free`.
/// Used by the module normalize callback.
@ffi.Native<
  ffi.Pointer<Utf8> Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>)
>()
external ffi.Pointer<Utf8> js_strdup(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<Utf8> str,
);

// ============================================================
// Intrinsics (for JS_NewContextRaw + selective setup)
// ============================================================

@ffi.Native<ffi.Pointer<JSContext> Function(ffi.Pointer<JSRuntime>)>()
external ffi.Pointer<JSContext> JS_NewContextRaw(ffi.Pointer<JSRuntime> rt);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicBaseObjects(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicDate(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicEval(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicRegExp(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicJSON(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicProxy(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicMapSet(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicTypedArrays(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicPromise(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicStringNormalize(ffi.Pointer<JSContext> ctx);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>)>()
external void JS_AddIntrinsicWeakRef(ffi.Pointer<JSContext> ctx);
