import 'package:bilibeat/widgets/marquee_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reading pause: overflowing text holds its static start through
/// [dwell], then scrolls. Fit text never animates.
void main() {
  double scrollDx(WidgetTester tester) {
    final transform = tester.widget<Transform>(find.byType(Transform).first);
    return transform.transform.getTranslation().x;
  }

  Widget frame(String text) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: MarqueeText(
              text: text,
              style: const TextStyle(fontSize: 15),
              dwell: const Duration(seconds: 2),
            ),
          ),
        ),
      );

  testWidgets('holds the static start through dwell, then scrolls',
      (tester) async {
    await tester
        .pumpWidget(frame('a very long song title that must overflow its row'));
    await tester.pump();
    expect(scrollDx(tester), 0.0);

    await tester.pump(const Duration(seconds: 1));
    expect(scrollDx(tester), 0.0);

    // Dwell elapses, then the cycle visibly advances.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 3));
    expect(scrollDx(tester), lessThan(-1.0));
  });
}
