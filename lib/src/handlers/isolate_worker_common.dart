import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:bdlogging/src/bd_level.dart';
import 'package:bdlogging/src/bd_log_record.dart';
import 'package:bdlogging/src/handlers/file_log_handler.dart';
import 'package:bdlogging/src/handlers/isolate_message_protocol.dart';
import 'package:file/local.dart';
import 'package:meta/meta.dart';

const String _logName = 'bdlogging';

/// Starts a dedicated isolate for a single handler (1:1 pattern).
@internal
Future<SendPort> startDedicatedIsolate(FileLogHandlerOptions config) async {
  final ReceivePort receivePort = ReceivePort();
  await Isolate.spawn(
    dedicatedWorkerEntryPoint,
    receivePort.sendPort,
    debugName: '${config.logNamePrefix}_dedicated_worker',
  );

  final SendPort workerPort = await receivePort.first as SendPort;
  receivePort.close();
  final Map<String, dynamic> configMessage = config.toMap();
  configMessage['type'] = WorkerMessageType.configure.name;
  workerPort.send(configMessage);
  return workerPort;
}

/// Entry point for dedicated worker isolate.
///
/// Processes messages sequentially using a future-chaining queue to prevent
/// concurrent file writes from interleaving.
@internal
void dedicatedWorkerEntryPoint(SendPort mainSendPort) {
  final ReceivePort receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  FileLogHandler? handler;
  Future<void> pending = Future<void>.value();

  receivePort.listen((dynamic message) {
    if (message is! Map<String, dynamic>) {
      developer.log(
        'Dedicated worker received unexpected: '
        '${message.runtimeType}',
        name: _logName,
      );
      return;
    }

    final WorkerMessageType? messageType =
        WorkerMessageType.tryByName(message['type'] as String?);
    switch (messageType) {
      case WorkerMessageType.configure:
        final FileLogHandlerOptions config =
            FileLogHandlerOptions.fromMap(message);
        const LocalFileSystem fs = LocalFileSystem();
        handler = FileLogHandler(
          logNamePrefix: config.logNamePrefix,
          maxLogSizeInMb: config.maxLogSize,
          maxFilesCount: config.maxFilesCount,
          logFileDirectory: fs.directory(config.logFileDirectoryPath),
          supportedLevels: mapLevels(config.supportedLevels),
        );
      case WorkerMessageType.logRecord:
        if (handler != null) {
          pending = pending.then((_) async {
            try {
              final BDLogRecord record = BDLogRecord.fromMap(message);
              await handler!.handleRecord(record);
            } on Exception catch (error, stackTrace) {
              developer.log(
                'Dedicated worker error handling record',
                name: _logName,
                error: error,
                stackTrace: stackTrace,
              );
            }
          });
        }
      case WorkerMessageType.clean:
        pending = pending.then((_) async {
          if (handler != null) {
            await handler!.clean();
          }
          final SendPort? replyPort = message['replyPort'] as SendPort?;
          replyPort?.send('clean_completed');
          receivePort.close();
        });
      case null:
      case WorkerMessageType.workerHealthCheck:
      case WorkerMessageType.handlerRegistration:
      case WorkerMessageType.logRecordMessage:
      case WorkerMessageType.handlerCleanup:
      case WorkerMessageType.shutdown:
        developer.log(
          'Dedicated worker received unexpected type: '
          '${message['type']}',
          name: _logName,
        );
    }
  });
}

/// Maps level importance values to BDLevel enum values.
@internal
List<BDLevel> mapLevels(List<int> importanceValues) {
  final List<BDLevel> levels = <BDLevel>[];
  for (final int importance in importanceValues) {
    for (final BDLevel level in BDLevel.values) {
      if (level.importance == importance) {
        levels.add(level);
        break;
      }
    }
  }
  return levels;
}
