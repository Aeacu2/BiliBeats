import 'package:bilibeats/widgets/player_seek_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A trimmed song's bar spans the part that plays; seeking stays in the
/// file's time.
void main() {
  Future<List<Duration>> pump(WidgetTester tester,
      {Duration start = Duration.zero, Duration? end}) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlayerSeekBar(
          position: ValueNotifier(const Duration(seconds: 40)),
          duration: ValueNotifier(const Duration(minutes: 5)),
          fallback: Duration.zero,
          onSeek: seeks.add,
          start: start,
          end: end,
        ),
      ),
    ));
    return seeks;
  }

  testWidgets('an untrimmed song shows the whole file', (tester) async {
    await pump(tester);
    expect(find.text('00:40'), findsOneWidget);
    expect(find.text('-04:20'), findsOneWidget);
  });

  testWidgets('a trimmed song shows its own length', (tester) async {
    final seeks = await pump(tester,
        start: const Duration(seconds: 30), end: const Duration(minutes: 4));
    // 10 s into a 3:30 song.
    expect(find.text('00:10'), findsOneWidget);
    expect(find.text('-03:20'), findsOneWidget);

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.max, 210);
    slider.onChangeEnd!(105);
    expect(seeks, [const Duration(seconds: 135)]);
  });

  test('a trim past the end of the file stops at the end', () {
    final span = trimmedSpan(const Duration(minutes: 3),
        start: const Duration(seconds: 10), end: const Duration(minutes: 9));
    expect(span.start, const Duration(seconds: 10));
    expect(span.end, const Duration(minutes: 3));
    // One that leaves nothing is not applied.
    expect(
        trimmedSpan(const Duration(minutes: 3),
                start: const Duration(minutes: 4))
            .start,
        Duration.zero);
  });
}
