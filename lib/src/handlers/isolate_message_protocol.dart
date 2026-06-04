import 'dart:isolate';

import 'package:bdlogging/src/bd_log_record.dart';
import 'package:meta/meta.dart';

/// Enum representing all worker message types for type-safe dispatch.
///
/// Used in switch statements to route messages in both shared and
/// dedicated worker isolates.
///
/// {@category Internal}
@internal
enum WorkerMessageType {
  /// Health check ping (shared worker).
  workerHealthCheck,

  /// Register a new handler (shared worker).
  handlerRegistration,

  /// Log record routed to a specific handler (shared worker).
  logRecordMessage,

  /// Cleanup and remove a handler (shared worker).
  handlerCleanup,

  /// Shut down the worker isolate.
  shutdown,

  /// Log record for the dedicated worker.
  logRecord,

  /// Configuration message for the dedicated worker.
  configure,

  /// Clean command for the dedicated worker.
  clean;

  /// Safely resolves a [name] to a [WorkerMessageType] value,
  /// returning `null` if no match is found.
  static WorkerMessageType? tryByName(String? name) {
    if (name == null) {
      return null;
    }
    for (final WorkerMessageType value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }
}

/// Request to register a new handler with the shared worker.
///
/// The worker will create a FileLogHandler instance with the provided
/// configuration and associate it with the given handler ID.
///
/// {@category Internal}
@internal
class HandlerRegistration {
  static const WorkerMessageType type = WorkerMessageType.handlerRegistration;
  final String handlerId;
  final FileLogHandlerOptions config;
  final SendPort replyPort;

  HandlerRegistration({
    required this.handlerId,
    required this.config,
    required this.replyPort,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'type': type.name,
        'handlerId': handlerId,
        'config': config.toMap(),
        'replyPort': replyPort,
      };

  factory HandlerRegistration.fromMap(Map<String, dynamic> map) =>
      HandlerRegistration(
        handlerId: map['handlerId'] as String,
        config: FileLogHandlerOptions.fromMap(
            map['config'] as Map<String, dynamic>),
        replyPort: map['replyPort'] as SendPort,
      );
}

/// Log record to be processed by a specific handler.
///
/// The worker routes this message to the FileLogHandler instance
/// identified by [handlerId].
///
/// {@category Internal}
@internal
class LogRecordMessage {
  static const WorkerMessageType type = WorkerMessageType.logRecordMessage;
  final String handlerId;
  final BDLogRecord record;

  LogRecordMessage({
    required this.handlerId,
    required this.record,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'type': type.name,
        'handlerId': handlerId,
        'record': record.toMap(),
      };

  factory LogRecordMessage.fromMap(Map<String, dynamic> map) =>
      LogRecordMessage(
        handlerId: map['handlerId'] as String,
        record: BDLogRecord.fromMap(map['record'] as Map<String, dynamic>),
      );
}

/// Request to cleanup and remove a handler from the shared worker.
///
/// The worker will call clean() on the FileLogHandler instance,
/// remove it from the registry, and decrement the reference count.
///
/// {@category Internal}
@internal
class HandlerCleanup {
  static const WorkerMessageType type = WorkerMessageType.handlerCleanup;
  final String handlerId;
  final SendPort replyPort;

  HandlerCleanup({
    required this.handlerId,
    required this.replyPort,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'type': type.name,
        'handlerId': handlerId,
        'replyPort': replyPort,
      };

  factory HandlerCleanup.fromMap(Map<String, dynamic> map) => HandlerCleanup(
        handlerId: map['handlerId'] as String,
        replyPort: map['replyPort'] as SendPort,
      );
}

/// Health check ping to verify the worker is alive.
///
/// Used to detect stale IsolateNameServer registrations when
/// a worker has crashed but the name mapping persists.
///
/// {@category Internal}
@internal
class WorkerHealthCheck {
  static const WorkerMessageType type = WorkerMessageType.workerHealthCheck;
  final SendPort replyPort;

  WorkerHealthCheck({required this.replyPort});

  Map<String, dynamic> toMap() => <String, dynamic>{
        'type': type.name,
        'replyPort': replyPort,
      };

  factory WorkerHealthCheck.fromMap(Map<String, dynamic> map) =>
      WorkerHealthCheck(replyPort: map['replyPort'] as SendPort);

  static bool isMap(dynamic message) =>
      message is Map<String, dynamic> && message['type'] == type.name;
}

/// Configuration options for a FileLogHandler instance.
///
/// This is sent as part of [HandlerRegistration] to configure
/// handler-specific behavior in the worker isolate.
///
/// {@category Internal}
@internal
class FileLogHandlerOptions {
  final String logFileDirectoryPath;
  final int maxFilesCount;
  final String logNamePrefix;
  final int maxLogSize;
  final List<int> supportedLevels;

  const FileLogHandlerOptions({
    required this.logFileDirectoryPath,
    required this.maxFilesCount,
    required this.logNamePrefix,
    required this.maxLogSize,
    required this.supportedLevels,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'logFileDirectoryPath': logFileDirectoryPath,
        'maxFilesCount': maxFilesCount,
        'logNamePrefix': logNamePrefix,
        'maxLogSize': maxLogSize,
        'supportedLevels': supportedLevels,
      };

  factory FileLogHandlerOptions.fromMap(Map<String, dynamic> map) =>
      FileLogHandlerOptions(
        logFileDirectoryPath: map['logFileDirectoryPath'] as String,
        maxFilesCount: map['maxFilesCount'] as int,
        logNamePrefix: map['logNamePrefix'] as String,
        maxLogSize: map['maxLogSize'] as int,
        supportedLevels:
            List<int>.from(map['supportedLevels'] as List<dynamic>),
      );
}
