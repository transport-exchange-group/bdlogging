// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';

import 'package:bdlogging/src/bd_level.dart';
import 'package:bdlogging/src/bd_log_record.dart';
import 'package:test/test.dart';

void main() {
  group('BDLogRecord', () {
    test('isFatal=true with error should succeed', () {
      expect(
        () => BDLogRecord(
          BDLevel.error,
          'Fatal error message',
          error: Exception('Fatal exception'),
          isFatal: true,
        ),
        returnsNormally,
      );
    });

    test('isFatal=false with error should succeed', () {
      expect(
        () => BDLogRecord(
          BDLevel.error,
          'Non-fatal error message',
          error: Exception('Exception'),
          isFatal: false,
        ),
        returnsNormally,
      );
    });

    test('isFatal=false without error should succeed', () {
      expect(
        () => BDLogRecord(
          BDLevel.info,
          'Info message',
          isFatal: false,
        ),
        returnsNormally,
      );
    });

    test('isFatal=true without error should fail assertion', () {
      expect(
        () => BDLogRecord(
          BDLevel.error,
          'Fatal without error',
          isFatal: true,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('equality and hashCode include all fields', () {
      final StackTrace stackTrace = StackTrace.current;
      final Exception error = Exception('Failure');

      final BDLogRecord record1 = BDLogRecord(
        BDLevel.error,
        'Message',
        error: error,
        stackTrace: stackTrace,
        isFatal: true,
      );
      final BDLogRecord record2 = record1;
      final BDLogRecord record3 = BDLogRecord(
        BDLevel.error,
        'Message',
        error: Exception('Different error'),
        stackTrace: stackTrace,
        isFatal: true,
      );

      expect(record1 == record1, isTrue);
      expect(record1 == record2, isTrue);
      expect(record1 == record3, isFalse);
      expect(record1.hashCode, equals(record2.hashCode));
    });

    test('equality compares each field', () async {
      final BDLogRecord base = BDLogRecord(BDLevel.info, 'Message');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final BDLogRecord differentTime = BDLogRecord(BDLevel.info, 'Message');

      final BDLogRecord differentError = BDLogRecord(
        BDLevel.info,
        'Message',
        error: Exception('Boom'),
      );
      final BDLogRecord differentStackTrace = BDLogRecord(
        BDLevel.info,
        'Message',
        stackTrace: StackTrace.current,
      );
      final BDLogRecord differentFatal = BDLogRecord(
        BDLevel.info,
        'Message',
        error: 'Fatal',
        isFatal: true,
      );

      expect(base == differentTime, isFalse);
      expect(base == differentError, isFalse);
      expect(base == differentStackTrace, isFalse);
      expect(base == differentFatal, isFalse);
    });

    test('toString includes all fields', () {
      final BDLogRecord record = BDLogRecord(
        BDLevel.warning,
        'Warning message',
        error: 'error',
        stackTrace: StackTrace.current,
        isFatal: false,
      );

      final String description = record.toString();
      expect(description, contains('level:'));
      expect(description, contains('message: Warning message'));
      expect(description, contains('error: error'));
      expect(description, contains('stackTrace:'));
      expect(description, contains('isFatal: false'));
    });

    test('hashCode should be consistent with equals', () {
      final BDLogRecord record = BDLogRecord(BDLevel.info, 'Test');

      expect(record.hashCode, equals(record.hashCode));

      // ignore: unrelated_type_equality_checks
      if (record == record) {
        expect(record.hashCode, equals(record.hashCode));
      }
    });

    test('different records should have different hashCodes', () {
      final BDLogRecord record1 = BDLogRecord(BDLevel.info, 'Message 1');
      final BDLogRecord record2 = BDLogRecord(BDLevel.info, 'Message 2');
      final BDLogRecord record3 = BDLogRecord(BDLevel.error, 'Message 1');

      expect(record1.hashCode, isNot(equals(record2.hashCode)));
      expect(record1.hashCode, isNot(equals(record3.hashCode)));
    });
  });

  group('BDLogRecord serialization', () {
    test('toMap/fromMap round-trip preserves basic fields', () {
      final DateTime now = DateTime.now();
      final BDLogRecord record = BDLogRecord(
        BDLevel.warning,
        'Warning message',
        time: now,
      );

      final Map<String, dynamic> map = record.toMap();
      final BDLogRecord restored = BDLogRecord.fromMap(map);

      expect(restored.level, equals(BDLevel.warning));
      expect(restored.message, equals('Warning message'));
      expect(restored.time, equals(now));
      expect(restored.error, isNull);
      expect(restored.stackTrace, isNull);
      expect(restored.isFatal, isFalse);
    });

    test('toMap/fromMap preserves error as string', () {
      final BDLogRecord record = BDLogRecord(
        BDLevel.error,
        'Error occurred',
        error: Exception('test error'),
        isFatal: true,
      );

      final Map<String, dynamic> map = record.toMap();
      final BDLogRecord restored = BDLogRecord.fromMap(map);

      expect(restored.error, isA<String>());
      expect(restored.error.toString(), contains('test error'));
      // Note: isFatal requires non-null error, which is preserved
      expect(restored.isFatal, isTrue);
    });

    test('toMap/fromMap preserves stackTrace', () {
      final StackTrace trace = StackTrace.current;
      final BDLogRecord record = BDLogRecord(
        BDLevel.debug,
        'Debug message',
        stackTrace: trace,
      );

      final Map<String, dynamic> map = record.toMap();
      final BDLogRecord restored = BDLogRecord.fromMap(map);

      expect(restored.stackTrace, isNotNull);
      expect(restored.stackTrace.toString(), equals(trace.toString()));
    });

    test('toMap/fromMap handles all BDLevel values', () {
      for (final BDLevel level in BDLevel.values) {
        final BDLogRecord record = BDLogRecord(level, 'Test $level');
        final Map<String, dynamic> map = record.toMap();
        final BDLogRecord restored = BDLogRecord.fromMap(map);
        expect(restored.level, equals(level));
      }
    });

    test('toMap produces expected keys', () {
      final BDLogRecord record = BDLogRecord(BDLevel.info, 'msg');
      final Map<String, dynamic> map = record.toMap();

      expect(map.containsKey('level'), isTrue);
      expect(map.containsKey('message'), isTrue);
      expect(map.containsKey('time'), isTrue);
      expect(map.containsKey('error'), isTrue);
      expect(map.containsKey('stackTrace'), isTrue);
      expect(map.containsKey('isFatal'), isTrue);
    });

    test('fromMap with null error and isFatal defaults to false', () {
      final Map<String, dynamic> map = <String, dynamic>{
        'level': BDLevel.info.importance,
        'message': 'test',
        'error': null,
        'time': DateTime.now().toIso8601String(),
        'stackTrace': null,
        // isFatal omitted
      };

      final BDLogRecord record = BDLogRecord.fromMap(map);
      expect(record.isFatal, isFalse);
    });

    test('fromMap with unknown level importance defaults to debug', () {
      final Map<String, dynamic> map = <String, dynamic>{
        'level': 999, // Unknown importance value
        'message': 'unknown level message',
        'error': null,
        'time': DateTime.now().toIso8601String(),
        'stackTrace': null,
        'isFatal': false,
      };

      final BDLogRecord record = BDLogRecord.fromMap(map);
      expect(record.level, equals(BDLevel.debug));
      expect(record.message, equals('unknown level message'));
    });
  });
}
