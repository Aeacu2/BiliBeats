import 'dart:io';

import 'package:bilibeat/models/lyric_line.dart';
import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:bilibeat/services/database_service.dart';
import 'package:bilibeat/widgets/now_playing_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as ft;

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

/// testWidgets with real HTTP: flutter_test answers 400 to real hosts,
/// which would break the local audio server.
void testWidgets(String description, WidgetTesterCallback body) {
  ft.testWidgets(
      description, (tester) => HttpOverrides.runZoned(() => body(tester)));
}

/// Widget-side lyric ownership cases (Prompt 2, sheet half).
///
/// Async discipline (FakeAsync): handler/database/delay work runs inside
/// `tester.runAsync`; widget-triggered async work is driven with [pumpUntil]
/// on UI-observable signals — never bare `await` on real IO in the fake
/// zone, which deadlocks.
void main() {
  late LocalAudioServer server;

  setUpAll(() async {
    await stubDocs('lw_fav');
    useHermeticHttp();
    server = await LocalAudioServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  Track trackA(String base) =>
      serverTrack(server, '$base-a', title: 'Alpha Song');
  Track trackB(String base) =>
      serverTrack(server, '$base-b', title: 'Beta Song');

  Future<void> pumpSheet(
    WidgetTester tester,
    BiliBeatAudioHandler handler,
    Track focused,
    ValueNotifier<List<LyricLine>> lyrics,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NowPlayingSheet(
            handler: handler,
            focusedTrack: focused,
            positionNotifier: ValueNotifier(Duration.zero),
            durationNotifier: ValueNotifier(const Duration(seconds: 200)),
            lyricsNotifier: lyrics,
            followHandler: true,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('favorite started before a switch never touches the new track',
      (tester) async {
    const base = 'lw-fav';
    server.serveInstant('$base-a');
    server.serveInstant('$base-b');
    final fake = FakeAudioPlayer();
    final handler = BiliBeatAudioHandler(player: fake);
    final a = trackA(base);
    final b = trackB(base);
    await tester.runAsync(() => handler.playTrack(a, newQueue: [a, b]));
    final lyrics = ValueNotifier<List<LyricLine>>(const []);
    await pumpSheet(tester, handler, a, lyrics);

    // Favorite A and switch to B back-to-back without awaiting between:
    // whichever completes first, B must stay untouched. The toggle
    // captured A, and B's refresh is token-guarded.
    // NOTE: taps do not reach some buttons in widget tests (see above);
    // invoke the real button wiring directly.
    tester
        .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.favorite_border_rounded))
        .onPressed!();
    await tester.runAsync(handler.skipToNext);
    await tester.pump();
    await tester.pump();

    // The toggle lands on its own time; wait for it in the real zone.
    final favLanded = await tester.runAsync(() async {
      for (var i = 0; i < 200; i++) {
        if (await DatabaseService.isFavorite(a.id)) return true;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return false;
    });
    expect(favLanded, isTrue);
    await tester.pump();
    await tester.pump();

    final results = (await tester.runAsync(() async => (
          favA: await DatabaseService.isFavorite(a.id),
          favB: await DatabaseService.isFavorite(b.id),
        )))!;
    expect(results.favA, isTrue);
    expect(results.favB, isFalse);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
  });
}
