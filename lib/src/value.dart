/// JSValue helpers — type checking, creation, and Dart ↔ JS conversion.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'constants.dart';

/// Extension on [JSValue] for type inspection without calling into C.
///
/// Since JSValue is a 16-byte struct with a `tag` field, we can check
/// types directly in Dart by reading the tag.
extension JsValueExtension on JSValue {
  bool get isException => tag == JsTag.exception;
  bool get isUndefined => tag == JsTag.undefined;
  bool get isNull => tag == JsTag.null_;
  bool get isInt => tag == JsTag.int_;
  bool get isBool => tag == JsTag.bool_;
  bool get isFloat64 => tag == JsTag.float64;
  bool get isString => tag == JsTag.string || tag == JsTag.stringRope;
  bool get isObject => tag == JsTag.object;
  bool get isBigInt => tag == JsTag.bigInt || tag == JsTag.shortBigInt;
  bool get isSymbol => tag == JsTag.symbol;
  bool get isNumber => tag == JsTag.int_ || tag == JsTag.float64;

  /// Whether this value has a reference count (negative tag).
  /// Values with ref counts must be freed with [kjs_free_value].
  bool get hasRefCount => tag < 0;

  /// Extract int32 from the union (lower 32 bits).
  int get intValue => (u & 0xFFFFFFFF).toSigned(32);

  /// Extract bool from the union.
  bool get boolValue => (u & 0xFFFFFFFF) != 0;

  /// Extract float64 from the union by reinterpreting the bits.
  double get floatValue {
    final buf = ByteData(8)..setInt64(0, u, Endian.host);
    return buf.getFloat64(0, Endian.host);
  }
}

/// Converts a [JSValue] to a Dart object.
///
/// Handles recursive conversion of arrays and objects.
/// If [freeValue] is true, the JSValue is freed after conversion.
dynamic jsValueToDart(
  ffi.Pointer<JSContext> ctx,
  JSValue value, {
  required bool freeValue,
}) {
  try {
    if (value.isException) {
      throw _extractJsException(ctx);
    }

    switch (value.tag) {
      case JsTag.int_:
        return value.intValue;

      case JsTag.bool_:
        return value.boolValue;

      case JsTag.null_:
      case JsTag.undefined:
        return null;

      case JsTag.string:
      case JsTag.stringRope:
        return _jsStringToDart(ctx, value);

      case JsTag.shortBigInt:
      case JsTag.bigInt:
        return _jsBigIntToDart(ctx, value);

      case JsTag.object:
        if (JS_IsArray(ctx, value) == 1) {
          return _jsArrayToList(ctx, value);
        }
        return _jsObjectToMap(ctx, value);

      default:
        // float64 tag or higher
        if (value.tag >= JsTag.float64) {
          return value.floatValue;
        }
        return null;
    }
  } finally {
    if (freeValue && value.hasRefCount) {
      kjs_free_value(ctx, value);
    }
  }
}

/// Converts a Dart object to a [JSValue].
JSValue dartToJsValue(ffi.Pointer<JSContext> ctx, Object? value) {
  if (value == null) {
    return kjs_null();
  }
  if (value is bool) {
    return kjs_new_bool(ctx, value ? 1 : 0);
  }
  if (value is int) {
    return kjs_new_int64(ctx, value);
  }
  if (value is double) {
    return kjs_new_float64(ctx, value);
  }
  if (value is String) {
    final encoded = utf8.encode(value);
    final len = encoded.length;
    final ptr = calloc<ffi.Uint8>(len + 1);
    ptr.asTypedList(len).setAll(0, encoded);
    ptr[len] = 0;
    final result = JS_NewStringLen(ctx, ptr.cast<Utf8>(), len);
    calloc.free(ptr);
    return result;
  }
  if (value is List) {
    final arr = JS_NewArray(ctx);
    for (var i = 0; i < value.length; i++) {
      final elem = dartToJsValue(ctx, value[i]);
      JS_SetPropertyUint32(ctx, arr, i, elem);
    }
    return arr;
  }
  if (value is Map) {
    final obj = JS_NewObject(ctx);
    for (final entry in value.entries) {
      final key = entry.key.toString().toNativeUtf8();
      final val = dartToJsValue(ctx, entry.value);
      JS_SetPropertyStr(ctx, obj, key, val);
      calloc.free(key);
    }
    return obj;
  }
  if (value is BigInt) {
    return JS_NewBigInt64(ctx, value.toInt());
  }

  throw ArgumentError('Unsupported value type: ${value.runtimeType}');
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

String _jsStringToDart(ffi.Pointer<JSContext> ctx, JSValue value) {
  final plen = calloc<ffi.Size>();
  final cstr = JS_ToCStringLen2(ctx, plen, value);
  if (cstr == ffi.nullptr) {
    calloc.free(plen);
    throw StateError('Failed to convert JS string');
  }
  try {
    return cstr.toDartString(length: plen.value);
  } finally {
    calloc.free(plen);
    JS_FreeCString(ctx, cstr);
  }
}

BigInt _jsBigIntToDart(ffi.Pointer<JSContext> ctx, JSValue value) {
  final pres = calloc<ffi.Int64>();
  try {
    if (JS_ToBigInt64(ctx, pres, value) < 0) {
      throw StateError('Failed to convert JS BigInt');
    }
    return BigInt.from(pres.value);
  } finally {
    calloc.free(pres);
  }
}

List<dynamic> _jsArrayToList(ffi.Pointer<JSContext> ctx, JSValue value) {
  // Get array length via property
  final lenProp = 'length'.toNativeUtf8();
  final lenVal = JS_GetPropertyStr(ctx, value, lenProp);
  calloc.free(lenProp);

  final len = jsValueToDart(ctx, lenVal, freeValue: true) as int? ?? 0;

  final list = <dynamic>[];
  for (var i = 0; i < len; i++) {
    final elem = JS_GetPropertyUint32(ctx, value, i);
    list.add(jsValueToDart(ctx, elem, freeValue: true));
  }
  return list;
}

Map<String, dynamic> _jsObjectToMap(ffi.Pointer<JSContext> ctx, JSValue value) {
  // Use JSON.stringify → parse for reliable conversion.
  final undef = kjs_undefined();
  final json = JS_JSONStringify(ctx, value, undef, undef);

  if (json.isException || json.isUndefined) {
    if (json.hasRefCount) {
      kjs_free_value(ctx, json);
    }
    return {};
  }

  final jsonStr = _jsStringToDart(ctx, json);
  kjs_free_value(ctx, json);

  final parsed = jsonDecode(jsonStr);
  if (parsed is Map) {
    return Map<String, dynamic>.from(parsed);
  }
  return {};
}

/// Extracts the current JS exception as a Dart [Exception].
Exception _extractJsException(ffi.Pointer<JSContext> ctx) {
  final exception = JS_GetException(ctx);

  var message = 'Unknown JS error';
  String? stack;

  try {
    // Try getting .message property
    final msgKey = 'message'.toNativeUtf8();
    final msgVal = JS_GetPropertyStr(ctx, exception, msgKey);
    calloc.free(msgKey);

    if (!msgVal.isUndefined) {
      final plen = calloc<ffi.Size>();
      final cstr = JS_ToCStringLen2(ctx, plen, msgVal);
      if (cstr != ffi.nullptr) {
        message = cstr.toDartString(length: plen.value);
        JS_FreeCString(ctx, cstr);
      }
      calloc.free(plen);
    }
    if (msgVal.hasRefCount) {
      kjs_free_value(ctx, msgVal);
    }

    // Try getting .stack property
    final stackKey = 'stack'.toNativeUtf8();
    final stackVal = JS_GetPropertyStr(ctx, exception, stackKey);
    calloc.free(stackKey);

    if (!stackVal.isUndefined) {
      final plen = calloc<ffi.Size>();
      final cstr = JS_ToCStringLen2(ctx, plen, stackVal);
      if (cstr != ffi.nullptr) {
        stack = cstr.toDartString(length: plen.value);
        JS_FreeCString(ctx, cstr);
      }
      calloc.free(plen);
    }
    if (stackVal.hasRefCount) {
      kjs_free_value(ctx, stackVal);
    }
  } finally {
    if (exception.hasRefCount) {
      kjs_free_value(ctx, exception);
    }
  }

  if (stack != null) {
    return Exception('$message\n$stack');
  }
  return Exception(message);
}
