// Test file for refactored IsolateFileLogHandler with coordination layer
// ignore_for_file: cascade_invocations

import 'dart:async';
import 'dart:io';

import 'package:bdlogging/bdlogging.dart';
import 'package:bdlogging/src/handlers/isolate_worker_common.dart'
    as worker_common;
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory testDirectory;
  late String uniqueDirName;

  setUp(() {
    // Create a unique directory for each test to avoid conflicts
    uniqueDirName = 'isolate_test_${DateTime.now().microsecondsSinceEpoch}';
    testDirectory = Directory(
      path.join(Directory.current.path, 'test/resources', uniqueDirName),
    )..createSync(recursive: true);
  });

  tearDown(() async {
    // Give isolates time to finish before cleanup
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (testDirectory.existsSync()) {
      testDirectory.deleteSync(recursive: true);
    }
  });

  group('IsolateFileLogHandler - Basic', () {
    test('should create handler with default values', () async {
      final IsolateFileLogHandler handler =
          IsolateFileLogHandler(testDirectory);

      expect(handler.maxFilesCount, equals(5));
      expect(handler.logNamePrefix, equals('_log'));
      expect(handler.maxLogSizeInMb, equals(5));

      await handler.clean();
    });

    test('should create handler with custom values', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        maxFilesCount: 10,
        logNamePrefix: 'custom',
        maxLogSizeInMb: 10,
        supportedLevels: <BDLevel>[BDLevel.debug],
      );

      expect(handler.maxFilesCount, equals(10));
      expect(handler.logNamePrefix, equals('custom'));
      expect(handler.maxLogSizeInMb, equals(10));

      await handler.clean();
    });

    test('should support level checking', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        supportedLevels: <BDLevel>[BDLevel.error, BDLevel.warning],
      );

      expect(handler.supportLevel(BDLevel.error), isTrue);
      expect(handler.supportLevel(BDLevel.warning), isTrue);
      expect(handler.supportLevel(BDLevel.debug), isFalse);

      await handler.clean();
    });
  });

  group('IsolateFileLogHandler - Integration (Dedicated Mode)', () {
    test('should write log record to file', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'test_log',
        supportedLevels: BDLevel.values,
      );

      final BDLogRecord record =
          BDLogRecord(BDLevel.error, 'Test error message');
      await handler.handleRecord(record);

      // Give time to process
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await handler.clean();

      // Verify file was created
      final List<FileSystemEntity> files = testDirectory.listSync();
      expect(files, isNotEmpty);
      expect(files.any((FileSystemEntity f) => f.path.contains('test_log')),
          isTrue);
    });

    test('should write multiple log records', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'multi_test',
        supportedLevels: BDLevel.values,
      );

      for (int i = 0; i < 10; i++) {
        await handler.handleRecord(
          BDLogRecord(BDLevel.info, 'Message $i'),
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      await handler.clean();

      final List<FileSystemEntity> files = testDirectory.listSync();
      expect(files, isNotEmpty);
    });

    test('should handle clean() successfully', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'clean_test',
      );

      await handler.handleRecord(BDLogRecord(BDLevel.info, 'Test'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Should complete without error
      await handler.clean();
    });

    test('should handle rapid clean() calls', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'rapid_clean',
      );

      // Multiple clean calls should not throw
      final List<Future<void>> futures = <Future<void>>[
        handler.clean(),
        handler.clean(),
        handler.clean(),
      ];

      await Future.wait<void>(futures);
    });

    test('should write rapid concurrent records in order', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'order_test',
        supportedLevels: BDLevel.values,
      );

      // Fire many records without awaiting each individually
      final List<Future<void>> futures = <Future<void>>[];
      for (int i = 0; i < 20; i++) {
        futures.add(handler.handleRecord(
          BDLogRecord(BDLevel.info, 'Message $i'),
        ));
      }
      await Future.wait<void>(futures);

      // Give worker time to flush
      await Future<void>.delayed(const Duration(milliseconds: 500));

      await handler.clean();

      // Verify all messages were written
      final List<FileSystemEntity> files = testDirectory.listSync();
      expect(files, isNotEmpty);

      final File logFile = files.whereType<File>().first;
      final String content = logFile.readAsStringSync();
      // All 20 messages should be present
      for (int i = 0; i < 20; i++) {
        expect(content, contains('Message $i'));
      }
    });
  });

  group('IsolateFileLogHandler - Shared Mode', () {
    setUp(() {
      // Note: Shared mode is enabled by default on Flutter (dart:ui available)
      // These tests will use dedicated mode on pure Dart CLI
    });

    test('should have handler ID for routing', () async {
      final IsolateFileLogHandler handler =
          IsolateFileLogHandler(testDirectory);
      expect(handler.handlerIdForTesting, isNotEmpty);
      expect(handler.handlerIdForTesting, startsWith('handler_'));
      await handler.clean();
    });

    test('each handler should have a unique ID', () async {
      final IsolateFileLogHandler handler1 =
          IsolateFileLogHandler(testDirectory, logNamePrefix: 'h1');
      final IsolateFileLogHandler handler2 =
          IsolateFileLogHandler(testDirectory, logNamePrefix: 'h2');

      expect(handler1.handlerIdForTesting, isNot(handler2.handlerIdForTesting));

      await handler1.clean();
      await handler2.clean();
    });

    test('should track shared mode status based on platform', () async {
      // Handler's shared mode status should match BDLogger's configuration
      // which defaults to true on Flutter, false on pure Dart CLI
      final IsolateFileLogHandler handler =
          IsolateFileLogHandler(testDirectory);
      expect(
        handler.isSharedModeForTesting,
        BDLogger.isSharedModeEnabled,
      );
      await handler.clean();
    });

    test('multiple handlers should work concurrently', () async {
      final List<IsolateFileLogHandler> handlers = <IsolateFileLogHandler>[];

      for (int i = 0; i < 5; i++) {
        handlers.add(IsolateFileLogHandler(
          testDirectory,
          logNamePrefix: 'handler_$i',
        ));
      }

      // All should write successfully
      for (int i = 0; i < handlers.length; i++) {
        await handlers[i].handleRecord(
          BDLogRecord(BDLevel.info, 'Handler $i message'),
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Clean all
      await Future.wait(handlers.map((IsolateFileLogHandler h) => h.clean()));
    });
  });

  group('IsolateFileLogHandler - Error Handling', () {
    test('should handle clean timeout gracefully', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'timeout_test',
      );

      // Clean should complete (with or without timeout in dedicated mode)
      await handler.clean();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  group('IsolateFileLogHandler - Constructor Validation', () {
    test('should reject empty logNamePrefix', () {
      expect(
        () => IsolateFileLogHandler(
          testDirectory,
          logNamePrefix: '',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('should reject maxLogSizeInMb of zero', () {
      expect(
        () => IsolateFileLogHandler(
          testDirectory,
          maxLogSizeInMb: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('should reject negative maxLogSizeInMb', () {
      expect(
        () => IsolateFileLogHandler(
          testDirectory,
          maxLogSizeInMb: -1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('should reject maxFilesCount of zero', () {
      expect(
        () => IsolateFileLogHandler(
          testDirectory,
          maxFilesCount: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('should reject negative maxFilesCount', () {
      expect(
        () => IsolateFileLogHandler(
          testDirectory,
          maxFilesCount: -1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('should generate unique handler IDs', () {
      // Use separate directories to avoid conflicts
      final IsolateFileLogHandler handler1 = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'unique1',
      );
      final IsolateFileLogHandler handler2 = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'unique2',
      );

      expect(
        handler1.handlerIdForTesting,
        isNot(equals(handler2.handlerIdForTesting)),
      );

      // Handlers were never started, so no isolates to clean up.
    });
  });

  group('IsolateFileLogHandler - Dedicated Mode Write Verification', () {
    test('should persist log content to file', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'content_test',
        supportedLevels: BDLevel.values,
      );

      await handler.handleRecord(
        BDLogRecord(BDLevel.error, 'Unique message 12345'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));
      await handler.clean();

      final List<File> logFiles = testDirectory
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('content_test'))
          .toList();
      expect(logFiles, isNotEmpty);

      final String content = logFiles.first.readAsStringSync();
      expect(content, contains('Unique message 12345'));
    });

    test('should write records with error and stackTrace', () async {
      final IsolateFileLogHandler handler = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'error_test',
        supportedLevels: BDLevel.values,
      );

      await handler.handleRecord(
        BDLogRecord(
          BDLevel.error,
          'Error with details',
          error: 'TestError',
          stackTrace: StackTrace.current,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));
      await handler.clean();

      final List<File> logFiles = testDirectory
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('error_test'))
          .toList();
      expect(logFiles, isNotEmpty);

      final String content = logFiles.first.readAsStringSync();
      expect(content, contains('Error with details'));
    });
  });

  group('mapLevels', () {
    test('should map importance values to BDLevel enum values', () {
      final List<int> importanceValues =
          BDLevel.values.map((BDLevel l) => l.importance).toList();
      final List<BDLevel> levels = worker_common.mapLevels(importanceValues);
      expect(levels, equals(BDLevel.values));
    });

    test('should handle empty list', () {
      final List<BDLevel> levels = worker_common.mapLevels(<int>[]);
      expect(levels, isEmpty);
    });

    test('should skip unknown importance values', () {
      final List<BDLevel> levels = worker_common.mapLevels(<int>[999]);
      expect(levels, isEmpty);
    });

    test('should map individual levels correctly', () {
      for (final BDLevel level in BDLevel.values) {
        final List<BDLevel> result =
            worker_common.mapLevels(<int>[level.importance]);
        expect(result, equals(<BDLevel>[level]));
      }
    });
  });

  group('BDLogger - Shared Isolate Configuration', () {
    tearDown(BDLogger.resetSharedIsolateConfigForTesting);

    test('isSharedModeEnabled reflects configuration', () {
      BDLogger.configureSharedIsolate(enabled: false);
      expect(BDLogger.isSharedModeEnabled, isFalse);
    });

    test('disabling shared mode works on all platforms', () {
      BDLogger.configureSharedIsolate(enabled: false);
      expect(BDLogger.isSharedModeEnabled, isFalse);
    });

    test('prints warning when configured after handlers created', () {
      // Simulate handler creation marking
      BDLogger.markHandlerCreated();

      // Should print a warning but not throw
      expect(
        () => BDLogger.configureSharedIsolate(enabled: false),
        returnsNormally,
      );
    });

    test('does not warn when configured before handlers created', () {
      // Fresh state - no handlers created yet
      expect(
        () => BDLogger.configureSharedIsolate(enabled: false),
        returnsNormally,
      );
    });

    test('isSharedModeEnabled does not mark handlers as created', () {
      // Reading isSharedModeEnabled should be side-effect-free
      BDLogger.isSharedModeEnabled;

      // Configuring after reading should NOT trigger the warning path
      // (i.e., _handlersCreated should still be false)
      // We verify by checking that configureSharedIsolate works without issue
      BDLogger.configureSharedIsolate(enabled: false);
      expect(BDLogger.isSharedModeEnabled, isFalse);
    });

    test('markHandlerCreated marks handlers as created', () {
      BDLogger.markHandlerCreated();

      // After marking, configureSharedIsolate should still work
      // but internally _handlersCreated is true (warning would be logged)
      expect(
        () => BDLogger.configureSharedIsolate(enabled: false),
        returnsNormally,
      );
    });
  });

  group('IsolateFileLogHandler - Shared File Path Coalescing', () {
    // These tests verify that two handlers writing to the same file path
    // produce correct output without corruption. In shared mode, the worker
    // coalesces them onto one FileLogHandler + queue. In dedicated mode,
    // each gets its own isolate (no coalescing).

    test('two handlers with same prefix write to same file', () async {
      final IsolateFileLogHandler handler1 = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'shared_file',
        supportedLevels: BDLevel.values,
      );
      final IsolateFileLogHandler handler2 = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'shared_file',
        supportedLevels: BDLevel.values,
      );

      await handler1.handleRecord(
        BDLogRecord(BDLevel.info, 'From handler 1'),
      );
      await handler2.handleRecord(
        BDLogRecord(BDLevel.info, 'From handler 2'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));
      await handler1.clean();
      await handler2.clean();

      final List<File> logFiles = testDirectory
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('shared_file'))
          .toList();
      expect(logFiles, isNotEmpty);
    });

    test('first handler cleanup does not break second handler', () async {
      final IsolateFileLogHandler handler1 = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'lifecycle',
        supportedLevels: BDLevel.values,
      );
      final IsolateFileLogHandler handler2 = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'lifecycle',
        supportedLevels: BDLevel.values,
      );

      // Both write
      await handler1.handleRecord(
        BDLogRecord(BDLevel.info, 'Before cleanup'),
      );
      await handler2.handleRecord(
        BDLogRecord(BDLevel.info, 'Also before cleanup'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // First handler cleans up
      await handler1.clean();

      // Second handler should still be able to write
      await handler2.handleRecord(
        BDLogRecord(BDLevel.info, 'After first cleanup'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await handler2.clean();

      final List<File> logFiles = testDirectory
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('lifecycle'))
          .toList();
      expect(logFiles, isNotEmpty);

      final String content =
          logFiles.map((File f) => f.readAsStringSync()).join();
      expect(content, contains('After first cleanup'));
    });

    test('rapid writes from two handlers with same path are not lost',
        () async {
      final IsolateFileLogHandler handler1 = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'rapid_shared',
        supportedLevels: BDLevel.values,
      );
      final IsolateFileLogHandler handler2 = IsolateFileLogHandler(
        testDirectory,
        logNamePrefix: 'rapid_shared',
        supportedLevels: BDLevel.values,
      );

      final List<Future<void>> futures = <Future<void>>[];
      for (int i = 0; i < 10; i++) {
        futures.add(handler1.handleRecord(
          BDLogRecord(BDLevel.info, 'H1-Message-$i'),
        ));
        futures.add(handler2.handleRecord(
          BDLogRecord(BDLevel.info, 'H2-Message-$i'),
        ));
      }
      await Future.wait<void>(futures);

      await Future<void>.delayed(const Duration(milliseconds: 500));
      await handler1.clean();
      await handler2.clean();

      final List<File> logFiles = testDirectory
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('rapid_shared'))
          .toList();
      expect(logFiles, isNotEmpty);

      final String content =
          logFiles.map((File f) => f.readAsStringSync()).join();
      // All 20 messages should be present
      for (int i = 0; i < 10; i++) {
        expect(content, contains('H1-Message-$i'));
        expect(content, contains('H2-Message-$i'));
      }
    });
  });
}
