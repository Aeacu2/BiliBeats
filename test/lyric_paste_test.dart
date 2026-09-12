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
    await stubDocs('lw_paste');
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

  testWidgets('paste after track switch saves the captured target',
      (tester) async {
    const base = 'lw-paste';
    final fake = FakeAudioPlayer();
    late BiliBeatAudioHandler handler;
    await tester.runAsync(() async {
      handler = await playingA(fake, base);
    });
    final a = trackA(base);
    final b = trackB(base);
    final lyrics = ValueNotifier<List<LyricLine>>(const []);
    await pumpSheet(tester, handler, a, lyrics);

    // Open the editor for A, then switch playback to B underneath it.
    // NOTE: the dialog's tab bar is exercised in isolation
    // (tabtap_test); here the lyrics toggle lands directly on the tab.
    await tester.tap(find.byTooltip('显示歌词'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.edit_note_rounded));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('歌名'), findsNothing);

    // Settle cross-zone gate work queued by the editor open (hold-trim):
    // a real-zone hop plus pumps before issuing the next start.
    await tester.runAsync(() async {});
    await tester.pump();
    await tester.pump();

    await tester.runAsync(handler.skipToNext);
    await tester.pump();
    await tester.pump();

    // Paste flow inside the still-open editor.
    await tester.tap(find.text('粘贴 LRC 文本'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '[00:01.00]hello');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '[00:01.00]hello',
    );
    await tester.tap(find.text('保存'));
    // NOTE: raw taps do not reach buttons inside this dialog subtree in
    // widget tests (verified: direct callback works, gesture silent-misses;
    // sheet-level taps are unaffected). Invoke the real button wiring.
    tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '保存'))
        .onPressed!();
    // The dialog closes only after the save completes.
    await pumpSettle(
        tester, () => find.byType(LyricEditorDialog).evaluate().isEmpty);

    expect(DatabaseService.manualLyricsFor(a.id)!.lines.single.text, 'hello');
    expect(DatabaseService.manualLyricsFor(b.id), isNull);
    // B was active: its shared notifier must be untouched.
    expect(lyrics.value, isEmpty);
  });
}
