// ignore_for_file: uri_does_not_exist, comment_references
// dart:ui is only available on Flutter - this file is conditionally imported

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:bdlogging/src/handlers/file_log_handler.dart';
import 'package:bdlogging/src/handlers/isolate_message_protocol.dart';
import 'package:bdlogging/src/handlers/isolate_worker_common.dart'
    as worker_common;
import 'package:file/local.dart';
import 'package:meta/meta.dart';

const String _logName = 'bdlogging';

/// Whether shared isolate mode is available on this platform.
///
/// Always true for Flutter (IsolateNameServer is available).
const bool isSharedAvailable = true;

/// Port name for the shared worker isolate in IsolateNameServer.
const String _sharedWorkerPortName = 'bdlogging_shared_worker';

/// Timeout for health check pings to detect stale registrations.
///
/// Set generously to avoid false positives when the worker is busy
/// processing a large batch of file writes.
const Duration _healthCheckTimeout = Duration(seconds: 10);

/// Response message for successful handler registration.
const String _registrationConfirmed = 'registration_confirmed';

/// Response message for successful handler cleanup.
const String _cleanupConfirmed = 'cleanup_confirmed';

/// Response message for health check pings.
const String _healthCheckOk = 'health_check_ok';

/// Tracks an in-flight worker resolution within this isolate.
///
/// When multiple `IsolateFileLogHandler` instances initialize concurrently,
/// only the first triggers the spawn/lookup cycle. Others await its result.
/// Once completed, subsequent handler creations perform their own resolution
/// (which typically just health-checks the existing worker).
Completer<SendPort>? _pendingWorkerResolution;

/// Entry point for starting a logging isolate.
///
/// This function decides whether to use a dedicated isolate (1:1 pattern)
/// or a shared isolate based on the [useShared] flag.
///
/// {@category Internal}
@internal
Future<SendPort> startLogging({
  required String handlerId,
  required FileLogHandlerOptions config,
  required bool useShared,
}) async {
  if (!useShared) {
    return worker_common.startDedicatedIsolate(config);
  }
  return _getOrCreateSharedWorker(handlerId, config);
}

/// Gets or creates the shared worker isolate, then registers this handler.
///
/// Uses a [Completer] to coalesce concurrent spawn attempts within the
/// same Dart isolate. Cross-isolate races are handled by
/// [IsolateNameServer]'s atomic registration.
Future<SendPort> _getOrCreateSharedWorker(
  String handlerId,
  FileLogHandlerOptions config,
) async {
  // If another resolution is in-flight within this isolate,
  // wait for it rather than spawning a redundant worker.
  final Completer<SendPort>? pending = _pendingWorkerResolution;
  if (pending != null && !pending.isCompleted) {
    try {
      final SendPort workerPort = await pending.future;
      return _registerHandlerWithWorker(handlerId, config, workerPort);
    } on Exception {
      // Previous resolution failed; fall through to try ourselves.
    }
  }

  final Completer<SendPort> resolution = Completer<SendPort>();
  _pendingWorkerResolution = resolution;

  try {
    final SendPort workerPort = await _resolveSharedWorkerPort(config);
    resolution.complete(workerPort);
    return _registerHandlerWithWorker(handlerId, config, workerPort);
  } on Exception catch (error, stackTrace) {
    if (!resolution.isCompleted) {
      resolution.completeError(error, stackTrace);
    }
    developer.log(
      'Shared worker resolution failed, '
      'falling back to dedicated isolate',
      name: _logName,
      error: error,
      stackTrace: stackTrace,
    );
    return worker_common.startDedicatedIsolate(config);
  }
}

/// Locates an existing shared worker or spawns a new one.
///
/// Handles [IsolateNameServer] lookup, health checking, isolate spawning,
/// and registration race retries. Throws if all retries are exhausted.
Future<SendPort> _resolveSharedWorkerPort(
  FileLogHandlerOptions config, {
  int retryCount = 0,
}) async {
  const int maxRetries = 3;
  // Try to lookup existing worker
  final SendPort? workerPort = IsolateNameServer.lookupPortByName(
    _sharedWorkerPortName,
  );

  if (workerPort != null) {
    // Verify worker is alive
    try {
      await _healthCheckWorker(workerPort);
      return workerPort;
    } on TimeoutException {
      // Worker is dead or unresponsive, cleanup stale registration
      developer.log(
        'Detected stale worker registration, removing...',
        name: _logName,
      );
      IsolateNameServer.removePortNameMapping(_sharedWorkerPortName);
      _sendShutdown(workerPort);
    } on Exception catch (error, stackTrace) {
      // Health check failed for other reason, assume worker is dead
      developer.log(
        'Worker health check failed, removing registration',
        name: _logName,
        error: error,
        stackTrace: stackTrace,
      );
      IsolateNameServer.removePortNameMapping(_sharedWorkerPortName);
      _sendShutdown(workerPort);
    }
  }

  // Spawn new worker
  final ReceivePort receivePort = ReceivePort();
  await Isolate.spawn(
    _sharedWorkerEntryPoint,
    receivePort.sendPort,
    debugName: 'bdlogging_shared_worker',
    errorsAreFatal: false,
  );

  // Wait for worker to be ready
  final SendPort newWorkerPort = await receivePort.first as SendPort;
  receivePort.close();

  // Try to register with IsolateNameServer
  final bool registered = IsolateNameServer.registerPortWithName(
    newWorkerPort,
    _sharedWorkerPortName,
  );

  if (!registered) {
    // Kill the orphaned worker we just spawned since another won the race
    newWorkerPort
        .send(<String, dynamic>{'type': WorkerMessageType.shutdown.name});

    if (retryCount >= maxRetries) {
      throw StateError(
        'Failed to register shared worker after $maxRetries retries',
      );
    }
    // Race condition: Another isolate won, use theirs
    developer.log(
      'Lost race to register worker, using existing one',
      name: _logName,
    );
    return _resolveSharedWorkerPort(
      config,
      retryCount: retryCount + 1,
    );
  }

  // Successfully registered
  return newWorkerPort;
}

/// Sends a health check ping to the worker.
///
/// Throws [TimeoutException] if worker doesn't respond within timeout.
Future<void> _healthCheckWorker(SendPort workerPort) async {
  final ReceivePort replyPort = ReceivePort();
  try {
    workerPort.send(
      WorkerHealthCheck(replyPort: replyPort.sendPort).toMap(),
    );

    await replyPort.first.timeout(
      _healthCheckTimeout,
      onTimeout: () => throw TimeoutException('Worker health check timeout'),
    );
  } finally {
    replyPort.close();
  }
}

/// Sends a best-effort shutdown to an orphaned worker.
///
/// This is fire-and-forget; if the worker is truly dead, the message
/// will simply be lost. If it's alive but slow, this ensures it
/// terminates rather than running forever as a zombie.
void _sendShutdown(SendPort workerPort) {
  try {
    workerPort.send(<String, dynamic>{'type': WorkerMessageType.shutdown.name});
  } on Exception {
    // Port may already be closed - ignore.
  }
}

/// Registers a handler with the shared worker.
///
/// Sends a registration message and waits for confirmation.
Future<SendPort> _registerHandlerWithWorker(
  String handlerId,
  FileLogHandlerOptions config,
  SendPort workerPort,
) async {
  final ReceivePort replyPort = ReceivePort();
  try {
    workerPort.send(HandlerRegistration(
      handlerId: handlerId,
      config: config,
      replyPort: replyPort.sendPort,
    ).toMap());

    final Object? response = await replyPort.first;

    if (response != _registrationConfirmed) {
      throw StateError('Handler registration failed: $response');
    }

    return workerPort;
  } finally {
    replyPort.close();
  }
}

/// Entry point for the shared worker isolate.
void _sharedWorkerEntryPoint(SendPort mainSendPort) {
  _SharedFileLoggerWorker(mainSendPort);
}

/// The shared worker that manages multiple FileLogHandler instances.
///
/// When multiple handlers register with the same file path
/// (`logFileDirectoryPath` + `logNamePrefix`), they share a single
/// [FileLogHandler] instance and write queue. This prevents file
/// contention and interleaved writes.
class _SharedFileLoggerWorker {
  _SharedFileLoggerWorker(SendPort mainSendPort) {
    _receivePort = ReceivePort();
    mainSendPort.send(_receivePort.sendPort);

    _receivePort.listen(_handleMessage);
  }

  late final ReceivePort _receivePort;
  final Map<String, FileLogHandler> _handlers = <String, FileLogHandler>{};

  /// Per-file sequential queues keyed by file path key.
  final Map<String, Future<void>> _handlerQueues = <String, Future<void>>{};

  /// The canonical FileLogHandler instance for each file path key.
  final Map<String, FileLogHandler> _fileKeyHandlers =
      <String, FileLogHandler>{};

  /// Reference count per file path key.
  final Map<String, int> _filePathRefCount = <String, int>{};

  /// Reverse lookup: handler ID → file path key.
  final Map<String, String> _handlerIdToFileKey = <String, String>{};

  /// Computes the canonical file path key for a handler config.
  String _fileKey(FileLogHandlerOptions config) =>
      '${config.logFileDirectoryPath}/${config.logNamePrefix}';

  Future<void> _handleMessage(dynamic message) async {
    try {
      // Map-based message dispatch for hot reload safety
      if (message is Map) {
        final WorkerMessageType? messageType =
            WorkerMessageType.tryByName(message['type'] as String?);
        switch (messageType) {
          case WorkerMessageType.workerHealthCheck:
            _handleHealthCheckMap(message as Map<String, dynamic>);
            return;
          case WorkerMessageType.handlerRegistration:
            await _handleRegistration(
                HandlerRegistration.fromMap(message as Map<String, dynamic>));
            return;
          case WorkerMessageType.logRecordMessage:
            await _handleLogRecord(
                LogRecordMessage.fromMap(message as Map<String, dynamic>));
            return;
          case WorkerMessageType.handlerCleanup:
            await _handleCleanup(
                HandlerCleanup.fromMap(message as Map<String, dynamic>));
            return;
          case WorkerMessageType.shutdown:
            _shutdown();
            return;
          case null:
            developer.log(
              'Shared worker received message with unknown type: '
              '${message['type']}',
              name: _logName,
            );
            return;
          case WorkerMessageType.logRecord:
          case WorkerMessageType.configure:
          case WorkerMessageType.clean:
            developer.log(
              'Shared worker received dedicated-worker message '
              'type: ${messageType.name}',
              name: _logName,
            );
            return;
        }
      }
      developer.log(
        'Shared worker received non-Map message: '
        '${message.runtimeType}',
        name: _logName,
      );
    } on Exception catch (error, stackTrace) {
      developer.log(
        'Shared worker error handling message',
        name: _logName,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _handleHealthCheckMap(Map<String, dynamic> message) {
    final SendPort? replyPort = message['replyPort'] as SendPort?;
    if (replyPort != null) {
      replyPort.send(_healthCheckOk);
    }
  }

  Future<void> _handleRegistration(HandlerRegistration message) async {
    try {
      final String fileKey = _fileKey(message.config);
      final FileLogHandler? existing = _fileKeyHandlers[fileKey];

      if (existing != null) {
        // Share the existing FileLogHandler instance.
        _handlers[message.handlerId] = existing;
        _filePathRefCount[fileKey] = (_filePathRefCount[fileKey] ?? 1) + 1;
        _handlerIdToFileKey[message.handlerId] = fileKey;

        _warnIfConfigDiffers(message.config, existing, fileKey);

        message.replyPort.send(_registrationConfirmed);
        developer.log(
          'Handler ${message.handlerId} sharing file key "$fileKey" '
          '(refCount: ${_filePathRefCount[fileKey]})',
          name: _logName,
        );
      } else {
        // First handler for this file path — create a new FileLogHandler.
        const LocalFileSystem fs = LocalFileSystem();
        final FileLogHandler handler = FileLogHandler(
          logNamePrefix: message.config.logNamePrefix,
          maxLogSizeInMb: message.config.maxLogSize,
          maxFilesCount: message.config.maxFilesCount,
          logFileDirectory: fs.directory(message.config.logFileDirectoryPath),
          supportedLevels:
              worker_common.mapLevels(message.config.supportedLevels),
        );
        _handlers[message.handlerId] = handler;
        _fileKeyHandlers[fileKey] = handler;
        _filePathRefCount[fileKey] = 1;
        _handlerIdToFileKey[message.handlerId] = fileKey;

        message.replyPort.send(_registrationConfirmed);
        developer.log(
          'Registered handler ${message.handlerId}, '
          'active count: ${_handlers.length}',
          name: _logName,
        );
      }
    } on Exception catch (error, stackTrace) {
      developer.log(
        'Failed to register handler ${message.handlerId}',
        name: _logName,
        error: error,
        stackTrace: stackTrace,
      );
      message.replyPort.send('registration_failed: $error');
    }
  }

  void _warnIfConfigDiffers(
    FileLogHandlerOptions newConfig,
    FileLogHandler existing,
    String fileKey,
  ) {
    final bool sizeDiffers = existing.maxLogSizeInMb != newConfig.maxLogSize;
    final bool countDiffers = existing.maxFilesCount != newConfig.maxFilesCount;
    if (sizeDiffers || countDiffers) {
      final StringBuffer details = StringBuffer()
        ..write('Config mismatch for file key "$fileKey". ');
      if (sizeDiffers) {
        details.write(
          'maxLogSize: existing=${existing.maxLogSizeInMb}MB, '
          'new=${newConfig.maxLogSize}MB. ',
        );
      }
      if (countDiffers) {
        details.write(
          'maxFilesCount: existing=${existing.maxFilesCount}, '
          'new=${newConfig.maxFilesCount}. ',
        );
      }
      details.write('Using config from first registration.');
      developer.log(details.toString(), name: _logName);
    }
  }

  Future<void> _handleLogRecord(LogRecordMessage message) async {
    final FileLogHandler? handler = _handlers[message.handlerId];
    if (handler == null) {
      developer.log(
        'Received log for unknown handler: ${message.handlerId}',
        name: _logName,
      );
      return;
    }

    // Use file key as queue key so all writes to the same file are
    // serialized regardless of which handler sent the message.
    final String queueKey =
        _handlerIdToFileKey[message.handlerId] ?? message.handlerId;
    await _enqueue(queueKey, () async {
      try {
        await handler.handleRecord(message.record);
      } on Exception catch (error, stackTrace) {
        developer.log(
          'Handler ${message.handlerId} failed to process record',
          name: _logName,
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<void> _handleCleanup(HandlerCleanup message) async {
    final String? fileKey = _handlerIdToFileKey[message.handlerId];
    final String queueKey = fileKey ?? message.handlerId;

    // Enqueue cleanup so it waits for pending writes to finish.
    await _enqueue(queueKey, () async {
      final FileLogHandler? handler = _handlers.remove(message.handlerId);
      _handlerIdToFileKey.remove(message.handlerId);

      if (handler != null && fileKey != null) {
        final int remaining = (_filePathRefCount[fileKey] ?? 1) - 1;
        _filePathRefCount[fileKey] = remaining;

        if (remaining <= 0) {
          // Last handler for this file — close the file handle.
          _filePathRefCount.remove(fileKey);
          _fileKeyHandlers.remove(fileKey);
          try {
            await handler.clean();
          } on Exception catch (error, stackTrace) {
            developer.log(
              'Error cleaning handler ${message.handlerId}',
              name: _logName,
              error: error,
              stackTrace: stackTrace,
            );
          }
        }

        developer.log(
          'Cleaned handler ${message.handlerId}, '
          'active count: ${_handlers.length}, '
          'file refCount: $remaining',
          name: _logName,
        );
      }
    });

    // Only remove the queue if no handlers share this file anymore.
    if (fileKey == null || (_filePathRefCount[fileKey] ?? 0) <= 0) {
      _handlerQueues.remove(queueKey);
    }
    message.replyPort.send(_cleanupConfirmed);
    _checkShutdown();
  }

  /// Enqueues [operation] for sequential execution on the given queue key.
  Future<void> _enqueue(
    String queueKey,
    Future<void> Function() operation,
  ) {
    final Future<void> previous =
        _handlerQueues[queueKey] ?? Future<void>.value();
    final Future<void> next = previous.then((_) => operation());
    _handlerQueues[queueKey] = next;
    return next;
  }

  void _checkShutdown() {
    if (_handlers.isEmpty) {
      _shutdown();
    }
  }

  void _shutdown() {
    developer.log(
      'No active handlers, shutting down shared worker',
      name: _logName,
    );
    IsolateNameServer.removePortNameMapping(_sharedWorkerPortName);
    _receivePort.close();
  }
}
