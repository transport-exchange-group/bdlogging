import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:bdlogging/src/handlers/isolate_message_protocol.dart';
import 'package:bdlogging/src/handlers/isolate_worker_common.dart'
    as worker_common;
import 'package:meta/meta.dart';

const String _logName = 'bdlogging';

/// Whether shared isolate mode is available on this platform.
///
/// Always false for Dart CLI (no IsolateNameServer).
const bool isSharedAvailable = false;

/// Entry point for starting a logging isolate in Dart CLI (non-Flutter) mode.
///
/// This stub always uses the dedicated isolate pattern (1:1) since
/// IsolateNameServer is unavailable in pure Dart environments.
///
/// The [useShared] parameter is ignored in this implementation.
///
/// {@category Internal}
@internal
Future<SendPort> startLogging({
  required String handlerId,
  required FileLogHandlerOptions config,
  required bool useShared,
}) async {
  // Dart CLI doesn't have IsolateNameServer, always use dedicated pattern
  if (useShared) {
    developer.log(
      'Shared isolate mode requires Flutter (IsolateNameServer), '
      'using dedicated isolate pattern',
      name: _logName,
    );
  }
  return worker_common.startDedicatedIsolate(config);
}
