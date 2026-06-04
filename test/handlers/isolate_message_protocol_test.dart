// ignore_for_file: cascade_invocations

import 'dart:isolate';

import 'package:bdlogging/bdlogging.dart';
import 'package:bdlogging/src/handlers/isolate_message_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('FileLogHandlerOptions', () {
    test('toMap/fromMap round-trip preserves all fields', () {
      const FileLogHandlerOptions options = FileLogHandlerOptions(
        logFileDirectoryPath: '/tmp/logs',
        maxFilesCount: 10,
        logNamePrefix: 'test_log',
        maxLogSize: 5,
        supportedLevels: <int>[1, 2, 3],
      );

      final Map<String, dynamic> map = options.toMap();
      final FileLogHandlerOptions restored = FileLogHandlerOptions.fromMap(map);

      expect(restored.logFileDirectoryPath, equals('/tmp/logs'));
      expect(restored.maxFilesCount, equals(10));
      expect(restored.logNamePrefix, equals('test_log'));
      expect(restored.maxLogSize, equals(5));
      expect(restored.supportedLevels, equals(<int>[1, 2, 3]));
    });

    test('fromMap handles dynamic list from isolate deserialization', () {
      // Isolate deserialization produces List<dynamic>, not List<int>
      final Map<String, dynamic> map = <String, dynamic>{
        'logFileDirectoryPath': '/tmp/logs',
        'maxFilesCount': 10,
        'logNamePrefix': 'test',
        'maxLogSize': 5,
        'supportedLevels': <dynamic>[1, 2, 3],
      };

      final FileLogHandlerOptions options = FileLogHandlerOptions.fromMap(map);
      expect(options.supportedLevels, equals(<int>[1, 2, 3]));
    });
  });

  group('LogRecordMessage', () {
    test('toMap/fromMap round-trip preserves fields', () {
      final BDLogRecord record = BDLogRecord(BDLevel.error, 'Test error');
      final LogRecordMessage message = LogRecordMessage(
        handlerId: 'handler-123',
        record: record,
      );

      final Map<String, dynamic> map = message.toMap();
      final LogRecordMessage restored = LogRecordMessage.fromMap(map);

      expect(restored.handlerId, equals('handler-123'));
      expect(restored.record.level, equals(BDLevel.error));
      expect(restored.record.message, equals('Test error'));
    });

    test('toMap includes correct type field', () {
      final LogRecordMessage message = LogRecordMessage(
        handlerId: 'id',
        record: BDLogRecord(BDLevel.info, 'msg'),
      );

      expect(message.toMap()['type'], equals('logRecordMessage'));
    });
  });

  group('HandlerRegistration', () {
    test('toMap/fromMap round-trip preserves fields', () {
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);

      const FileLogHandlerOptions config = FileLogHandlerOptions(
        logFileDirectoryPath: '/logs',
        maxFilesCount: 5,
        logNamePrefix: 'test',
        maxLogSize: 10,
        supportedLevels: <int>[1, 2],
      );

      final HandlerRegistration reg = HandlerRegistration(
        handlerId: 'handler-abc',
        config: config,
        replyPort: port.sendPort,
      );

      final Map<String, dynamic> map = reg.toMap();
      final HandlerRegistration restored = HandlerRegistration.fromMap(map);

      expect(restored.handlerId, equals('handler-abc'));
      expect(restored.config.logFileDirectoryPath, equals('/logs'));
      expect(restored.config.maxFilesCount, equals(5));
      expect(restored.replyPort, equals(port.sendPort));
    });

    test('toMap includes correct type field', () {
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);

      final HandlerRegistration reg = HandlerRegistration(
        handlerId: 'id',
        config: const FileLogHandlerOptions(
          logFileDirectoryPath: '/',
          maxFilesCount: 1,
          logNamePrefix: 'x',
          maxLogSize: 1,
          supportedLevels: <int>[],
        ),
        replyPort: port.sendPort,
      );

      expect(reg.toMap()['type'], equals('handlerRegistration'));
    });
  });

  group('HandlerCleanup', () {
    test('toMap/fromMap round-trip preserves fields', () {
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);

      final HandlerCleanup cleanup = HandlerCleanup(
        handlerId: 'handler-xyz',
        replyPort: port.sendPort,
      );

      final Map<String, dynamic> map = cleanup.toMap();
      final HandlerCleanup restored = HandlerCleanup.fromMap(map);

      expect(restored.handlerId, equals('handler-xyz'));
      expect(restored.replyPort, equals(port.sendPort));
    });

    test('toMap includes correct type field', () {
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);

      final HandlerCleanup cleanup = HandlerCleanup(
        handlerId: 'id',
        replyPort: port.sendPort,
      );

      expect(cleanup.toMap()['type'], equals('handlerCleanup'));
    });
  });

  group('WorkerHealthCheck', () {
    test('toMap/fromMap round-trip preserves fields', () {
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);

      final WorkerHealthCheck check = WorkerHealthCheck(
        replyPort: port.sendPort,
      );

      final Map<String, dynamic> map = check.toMap();
      final WorkerHealthCheck restored = WorkerHealthCheck.fromMap(map);

      expect(restored.replyPort, equals(port.sendPort));
    });

    test('toMap includes correct type field', () {
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);

      final WorkerHealthCheck check = WorkerHealthCheck(
        replyPort: port.sendPort,
      );

      expect(check.toMap()['type'], equals('workerHealthCheck'));
    });

    test('isMap correctly identifies health check messages', () {
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);

      final WorkerHealthCheck check = WorkerHealthCheck(
        replyPort: port.sendPort,
      );

      expect(WorkerHealthCheck.isMap(check.toMap()), isTrue);
      expect(
          WorkerHealthCheck.isMap(<String, dynamic>{'type': 'other'}), isFalse);
      expect(WorkerHealthCheck.isMap('not a map'), isFalse);
      expect(WorkerHealthCheck.isMap(null), isFalse);
    });
  });

  group('WorkerMessageType', () {
    test('tryByName resolves all known types', () {
      for (final WorkerMessageType type in WorkerMessageType.values) {
        expect(WorkerMessageType.tryByName(type.name), equals(type));
      }
    });

    test('tryByName returns null for unknown names', () {
      expect(WorkerMessageType.tryByName('nonexistent'), isNull);
      expect(WorkerMessageType.tryByName(null), isNull);
      expect(WorkerMessageType.tryByName(''), isNull);
    });

    test('configure type exists for dedicated worker config messages', () {
      expect(WorkerMessageType.configure.name, equals('configure'));
      expect(
        WorkerMessageType.tryByName('configure'),
        equals(WorkerMessageType.configure),
      );
    });
  });
}
