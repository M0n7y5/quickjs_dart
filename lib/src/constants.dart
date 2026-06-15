/// QuickJS constants — JS_TAG_*, JS_EVAL_*, etc.
///
/// Matches the values in quickjs.h for the non-NaN-boxing (64-bit) mode.
library;

/// JavaScript value type tags.
///
/// Tags with negative values have reference counts and need `JS_FreeValue`.
abstract final class JsTag {
  // Reference-counted tags (negative)
  static const bigInt = -9;
  static const symbol = -8;
  static const string = -7;
  static const stringRope = -6;
  static const module = -3;
  static const functionBytecode = -2;
  static const object = -1;

  // Non-reference-counted tags (non-negative)
  static const int_ = 0;
  static const bool_ = 1;
  static const null_ = 2;
  static const undefined = 3;
  static const uninitialized = 4;
  static const catchOffset = 5;
  static const exception = 6;
  static const shortBigInt = 7;
  static const float64 = 8;

  /// First negative tag — all tags >= this with negative values are ref-counted.
  static const first = -9;
}

/// Flags for `JS_Eval`.
abstract final class JsEvalFlag {
  static const typeGlobal = 0;
  static const typeModule = 1;
  static const typeDirect = 2;
  static const typeIndirect = 3;
  static const typeMask = 3;

  static const int strict = 1 << 3;
  static const int compileOnly = 1 << 5;
  static const int backtraceBarrier = 1 << 6;
  static const int async = 1 << 7;
}

/// Property flags.
abstract final class JsProp {
  static const int configurable = 1 << 0;
  static const int writable = 1 << 1;
  static const int enumerable = 1 << 2;
  static const int cwe = configurable | writable | enumerable;
}
