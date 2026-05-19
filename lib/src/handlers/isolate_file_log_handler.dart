import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:bdlogging/bdlogging.dart';
import 'package:bdlogging/src/handlers/isolate_coordination_stub.dart'
    if (dart.library.ui) 'package:bdlogging/src/handlers/isolate_coordination_flutter.dart'
    as coordination;
import 'package:bdlogging/src/handlers/isolate_message_protocol.dart';
import 'package:meta/meta.dart';

const String _logName = 'bdlogging';

/// A implementation of [BDCleanableLogHandler]
/// that write [BDLogRecord] to files in a different isolate.
class IsolateFileLogHandler implements BDCleanableLogHandler {
  /// Monotonically increasing counter for generating unique handler IDs.
  static int _nextHandlerId = 0;

  /// Create a new instance of [IsolateFileLogHandler].
  ///
  /// [logNamePrefix] will be used as prefix for each log file created by the
  /// instance of this [IsolateFileLogHandler].
  ///
  /// It's recommended that the [logNamePrefix] be unique in the app.
  ///
  /// [maxLogSizeInMb] is the maximum size of each log file in MB.
  /// When a log file exceeds this size, it is closed and a new one is created.
  ///
  /// [maxFilesCount] controls how many log files are kept.
  /// If in the [logFileDirectory] there are files with prefix [logNamePrefix]
  /// and the count of files is greater than [maxFilesCount], older files will
  /// be deleted.
  ///
  /// [logFileDirectory] is the directory where log files will be stored.
  ///
  /// We assume that the [logFileDirectory] provided exist in the file system.
  ///
  /// [supportedLevels] will be used to discard [BDLogRecord] with
  /// [BDLevel] lower than [supportedLevels].
  IsolateFileLogHandler(
    this.logFileDirectory, {
    this.maxFilesCount = 5,
    this.logNamePrefix = '_log',
    this.maxLogSizeInMb = 5,
    this.supportedLevels = const <BDLevel>[
      BDLevel.warning,
      BDLevel.success,
      BDLevel.error,
    ],
  })  : _handlerId = 'handler_${_nextHandlerId++}'
            '_${DateTime.now().microsecondsSinceEpoch}'
            '_${Isolate.current.hashCode}',
        assert(logNamePrefix.isNotEmpty, 'logNamePrefix should not be empty'),
        assert(
          maxLogSizeInMb > 0,
          'maxLogSizeInMb should not be lower than zero',
        ),
        assert(
          maxFilesCount > 0,
          'maxFilesCount should be greater than zero',
        ) {
    BDLogger.markHandlerCreated();
    _workerSendPort = _initializeWorker();
  }

  /// Directory where to store the log files.
  final Directory logFileDirectory;

  /// Maximum count of files to keep.
  ///
  /// Will be used to delete old log files.
  /// If in the [logFileDirectory] there are files with prefix [logNamePrefix]
  /// and the count of files is greater than [maxFilesCount],
  /// older files will be deleted.
  final int maxFilesCount;

  /// Prefix of each log files created by this [IsolateFileLogHandler].
  final String logNamePrefix;

  /// Maximum size of a log file in MB.
  final int maxLogSizeInMb;

  /// Supported [BDLevel] of [BDLogRecord].
  final List<BDLevel> supportedLevels;

  /// Unique identifier for this handler instance.
  /// Used for message routing in shared isolate mode.
  final String _handlerId;

  /// Whether this handler is using shared isolate mode.
  bool _isSharedMode = false;

  late final Future<SendPort> _workerSendPort;

  Completer<void>? _cleanCompleter;

  /// Getter for handler ID.
  /// Exposed for testing purposes only.
  @visibleForTesting
  String get handlerIdForTesting => _handlerId;

  /// Getter for shared mode status.
  /// Exposed for testing purposes only.
  @visibleForTesting
  bool get isSharedModeForTesting => _isSharedMode;

  @override
  Future<void> handleRecord(BDLogRecord record) async {
    final SendPort sendPort;
    try {
      sendPort = await _workerSendPort;
    } on Exception catch (error, stackTrace) {
      developer.log(
        'IsolateFileLogHandler: worker unavailable, dropping record',
        name: _logName,
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }

    if (_isSharedMode) {
      // Wrap in message envelope for routing
      sendPort.send(
        LogRecordMessage(handlerId: _handlerId, record: record).toMap(),
      );
    } else {
      // Send serialized record with type tag for worker dispatch
      final Map<String, dynamic> map = record.toMap();
      map['type'] = WorkerMessageType.logRecord.name;
      sendPort.send(map);
    }
  }

  /// Initializes the worker isolate using the coordination layer.
  Future<SendPort> _initializeWorker() async {
    _isSharedMode = BDLogger.isSharedModeEnabled;

    final FileLogHandlerOptions config = FileLogHandlerOptions(
      logFileDirectoryPath: logFileDirectory.path,
      maxFilesCount: maxFilesCount,
      logNamePrefix: logNamePrefix,
      maxLogSize: maxLogSizeInMb,
      supportedLevels:
          supportedLevels.map((BDLevel level) => level.importance).toList(),
    );

    return coordination.startLogging(
      handlerId: _handlerId,
      config: config,
      useShared: _isSharedMode,
    );
  }

  @override
  bool supportLevel(BDLevel level) => supportedLevels.contains(level);

  @override
  Future<void> clean() async {
    // Guard against calling clean() multiple times concurrently.
    // If a clean is already in progress, return the existing future.
    if (_cleanCompleter != null && !_cleanCompleter!.isCompleted) {
      return _cleanCompleter!.future;
    }
    _cleanCompleter = Completer<void>();

    try {
      final SendPort sendPort = await _workerSendPort;

      // Build message; _sendAndAwaitReply injects the real replyPort.
      final Map<String, dynamic> message = _isSharedMode
          ? <String, dynamic>{
              'type': HandlerCleanup.type.name,
              'handlerId': _handlerId,
            }
          : <String, dynamic>{'type': WorkerMessageType.clean.name};

      await _sendAndAwaitReply(sendPort, message);
      _cleanCompleter!.complete();
    } on Exception catch (error, stackTrace) {
      if (!_cleanCompleter!.isCompleted) {
        _cleanCompleter!.completeError(error, stackTrace);
      }
    }
    return _cleanCompleter!.future;
  }

  /// Sends a message and waits for a reply with a 10-second timeout.
  ///
  /// Guarantees that the [ReceivePort] is closed even on timeout.
  Future<void> _sendAndAwaitReply(
    SendPort sendPort,
    Map<String, dynamic> message,
  ) async {
    final ReceivePort replyPort = ReceivePort();
    try {
      // Replace the placeholder replyPort in the message with the real one
      message['replyPort'] = replyPort.sendPort;
      sendPort.send(message);
      await replyPort.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Cleanup timeout after 10 seconds');
        },
      );
    } finally {
      replyPort.close();
    }
  }
}
