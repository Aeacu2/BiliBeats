import 'dart:async';

import 'package:bilibeats/services/bili_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stalled response is cancelled at the overall deadline', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    stream.add([65]);
    await expectLater(
      readHttpBody(stream.stream, const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    await stream.close();
    expect(cancelled, isTrue);
  });

  test('an oversized response is cancelled before more data is read', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    stream.add([65, 66]);
    stream.add([67, 68]);
    await expectLater(
      readHttpBody(stream.stream, const Duration(seconds: 1), maxBytes: 3),
      throwsFormatException,
    );
    await stream.close();
    expect(cancelled, isTrue);
  });
}
