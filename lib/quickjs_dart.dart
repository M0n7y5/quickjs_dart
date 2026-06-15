/// Pure Dart FFI wrapper around Bellard's QuickJS JavaScript engine.
///
/// Provides a high-level [QjsEngine] that runs JS on a dedicated isolate
/// with an async bridge for Dart ↔ JS communication.
library;

import 'quickjs_dart.dart' show QjsEngine;
import 'src/engine.dart' show QjsEngine;

export 'src/constants.dart' show JsEvalFlag, JsTag;
export 'src/engine.dart' show BridgeHandler, QjsEngine;
export 'src/runtime.dart' show QjsRuntimeConfig;
