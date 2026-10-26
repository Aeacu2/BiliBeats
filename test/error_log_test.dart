import 'dart:io';

import 'package:bilibeats/services/error_log.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// What nothing caught is kept for a bug report, and kept small.
void main() {
  late Directory docs;

  setUpAll(() async {
    docs = await stubDocs('error_log');
  });

  test('an error is kept with its stack, and copied once cleared', () async {
    expect(ErrorLog.hasEntries.value, isFalse);
    ErrorLog.record(StateError('boom'), StackTrace.current, context: 'tap');
    final log = await ErrorLog.read();
    expect(log, contains('tap: Bad state: boom'));
    expect(log, contains('error_log_test.dart'));
    expect(ErrorLog.hasEntries.value, isTrue);

    await ErrorLog.clear();
    expect(await ErrorLog.read(), isEmpty);
    expect(ErrorLog.hasEntries.value, isFalse);
  });

  test('a long log drops its oldest half, entry by entry', () async {
    final filler = 'x' * 1000;
    for (var i = 0; i < 400; i++) {
      ErrorLog.record('error $i $filler', null);
    }
    final log = await ErrorLog.read();
    expect(log.length, lessThan(300 << 10));
    expect(log, startsWith('['));
    expect(log, contains('error 399 '));
    expect(log, isNot(contains('error 0 ')));
    expect(File('${docs.path}/bilibeat_errors.log').existsSync(), isTrue);
  });
}
