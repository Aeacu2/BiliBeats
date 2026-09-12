import 'dart:io';

import 'package:bilibeat/models/lyric_line.dart';
import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:bilibeat/services/database_service.dart';
import 'package:bilibeat/widgets/lyric_editor_dialog.dart';
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
    await stubDocs('lw_meta');
    useHermeticHttp();
    server = await LocalAudioServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  /// Drives mixed fake-zone/real-zone work to a UI-observable condition:
  /// each pump advances fake microtasks/timers, each real breath lets
  /// pending IO complete. Bounded so a stall fails fast with a message.
  ///
  /// The breath must consume REAL time (not just yield): several FS
  /// roundtrips only settle while the real loop actually turns.
  Future<void> pumpSettle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(done(), isTrue, reason: 'timed out waiting for UI signal');
  }

  /// Settles gate work queued from widget interactions (e.g. the editor
  /// open's hold-trim, which chains in the fake zone): real breaths let
  /// downloads finish, pumps let fake-zone gate callbacks run, so a later
  /// bare `runAsync` never queues behind an unfinished chain.
  Future<void> settleGates(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() async {});
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Track trackA(String base) =>
      serverTrack(server, '$base-a', title: 'Alpha Song');
  Track trackB(String base) =>
      serverTrack(server, '$base-b', title: 'Beta Song');

  Future<BiliBeatAudioHandler> playingA(
    FakeAudioPlayer fake,
    String base,
  ) async {
    for (final s in ['a', 'b']) {
      server.serveInstant('$base-$s');
    }
    final handler = BiliBeatAudioHandler(player: fake);
    await handler.playTrack(
      trackA(base),
      newQueue: [trackA(base), trackB(base)],
    );
    return handler;
  }

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

  testWidgets('metadata save targets the captured track', (tester) async {
    const base = 'lw-meta';
    final fake = FakeAudioPlayer();
    late BiliBeatAudioHandler handler;
    await tester.runAsync(() async {
      handler = await playingA(fake, base);
    });
    final a = trackA(base);
    final b = trackB(base);
    final lyrics = ValueNotifier<List<LyricLine>>(const []);
    await pumpSheet(tester, handler, a, lyrics);

    await tester.tap(find.byIcon(Icons.edit_note_rounded));
    await tester.pump();
    await settleGates(tester);

    await tester.runAsync(handler.skipToNext);
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'Alpha Renamed');
    await tester.pump();
    await tester.tap(find.text('确认'));
    // Same gesture-delivery note as above: drive the real wiring directly.
    tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '确认'))
        .onPressed!();
    // The dialog closes only after the transactional save completes.
    await pumpSettle(
        tester, () => find.byType(LyricEditorDialog).evaluate().isEmpty);

    final downloaded =
        await tester.runAsync(DatabaseService.getDownloadedTracks);
    expect(
        downloaded!.where((t) => t.id == a.id).single.title, 'Alpha Renamed');
    expect(downloaded.where((t) => t.id == b.id).single.title, 'Beta Song');
  });
}
