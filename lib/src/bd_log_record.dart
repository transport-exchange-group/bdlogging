import 'dart:developer' as developer;

import 'package:bdlogging/src/bd_level.dart';
import 'package:meta/meta.dart';

const String _logName = 'bdlogging';

/// Logging record.
@immutable
class BDLogRecord {
  /// Create a new Logging record.
  /// Logging record's [level] is required.
  /// Logging record's [message] is required.
  /// Logging record's [time] can be provided to preserve timestamps.
  BDLogRecord(
    this.level,
    this.message, {
    this.error,
    this.stackTrace,
    this.isFatal = false,
    DateTime? time,
  })  : time = time ?? DateTime.now(),
        assert(
          !isFatal || error != null,
          'isFatal can only be used with error',
        );

  /// Logging record's logging Level.
  final BDLevel level;

  /// Logging record's message.
  final String message;

  /// Logging record's Error.
  ///
  /// **Security Warning:** This field is not encrypted and may contain
  /// sensitive information. Avoid including sensitive data in error objects
  /// as they will be logged in plaintext by most handlers.
  final Object? error;

  /// Logging record's time of creation.
  final DateTime time;

  /// Logging record's stacktrace.
  final StackTrace? stackTrace;

  /// Logging record's error's fatal.
  final bool isFatal;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BDLogRecord &&
          runtimeType == other.runtimeType &&
          level == other.level &&
          message == other.message &&
          error == other.error &&
          time == other.time &&
          stackTrace == other.stackTrace &&
          isFatal == other.isFatal;

  @override
  int get hashCode => Object.hash(
        level,
        message,
        error,
        time,
        stackTrace,
        isFatal,
      );

  /// Serialize this log record to a map.
  ///
  /// **Note:** The [error] field is serialized via `toString()`, so the
  /// original error type is lost during serialization. After deserialization
  /// with [BDLogRecord.fromMap], the error will be a [String].
  Map<String, dynamic> toMap() => <String, dynamic>{
        'level': level.importance,
        'message': message,
        'error': error?.toString(),
        'time': time.toIso8601String(),
        'stackTrace': stackTrace?.toString(),
        'isFatal': isFatal,
      };

  /// Construct a log record from a map.
  ///
  /// If the level importance value does not match any known [BDLevel],
  /// defaults to [BDLevel.debug] and logs a warning.
  factory BDLogRecord.fromMap(Map<String, dynamic> map) => BDLogRecord(
        BDLevel.values.firstWhere(
          (BDLevel lvl) => lvl.importance == map['level'] as int,
          orElse: () {
            developer.log(
              'BDLogRecord.fromMap: unknown level importance '
              '${map['level']}, defaulting to debug',
              name: _logName,
            );
            return BDLevel.debug;
          },
        ),
        map['message'] as String,
        error: map['error'],
        stackTrace: map['stackTrace'] != null
            ? StackTrace.fromString(map['stackTrace'] as String)
            : null,
        isFatal: map['isFatal'] as bool? ?? false,
        time:
            map['time'] != null ? DateTime.parse(map['time'] as String) : null,
      );

  @override
  String toString() {
    return 'LogRecord{level: $level, message: $message, error: $error, '
        'time: $time, stackTrace: $stackTrace, isFatal: $isFatal}';
  }
}
