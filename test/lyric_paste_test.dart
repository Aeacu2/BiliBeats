import 'package:bilibeats/app/app_services.dart';
import 'package:bilibeats/models/lyrics.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:bilibeats/services/lyrics_store.dart';
import 'package:bilibeats/state/lyrics_controller.dart';
import 'package:bilibeats/widgets/lyrics_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';
import 'player_page_harness.dart';

/// The lyrics sheet belongs to the song it was opened for: what is written
/// or calibrated there is saved for that song, and never shown over
/// whatever is playing by then.
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

  testWidgetsWithHttp('paste after track switch saves the captured target',
      (tester) async {
    final fake = FakeAudioPlayer();
    late BiliBeatsAudioHandler handler;
    await tester.runAsync(() async {
      handler = await startPlaying(server, fake, ['lw-paste-a', 'lw-paste-b']);
    });
    final a = handler.queueSnapshot.tracks[0];
    final b = handler.queueSnapshot.tracks[1];
    await pumpPlayer(tester);
    await settle(tester);

    // Show lyrics, then open the lyrics sheet for A.
    await tester.tap(find.byTooltip('歌词'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('歌词选项'));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byType(LyricsSheet), findsOneWidget);

    // Playback moves on underneath the open sheet.
    await tester.runAsync(handler.skipToNext);
    await tester.pump();
    expect(handler.currentTrack?.id, b.id);

    await tester.tap(find.text('粘贴'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(
        find.descendant(
            of: find.byType(LrcEditorPage), matching: find.byType(TextField)),
        '[00:01.00]hello\n[00:05.00]world');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await pumpUntil(tester, () => find.byType(LyricsSheet).evaluate().isEmpty);
    await settle(tester);

    final saved = LyricsStore.peek(a.id)!;
    expect(saved.lines.map((l) => l.text), ['hello', 'world']);
    expect(saved.pinned, isTrue);
    expect(LyricsStore.peek(b.id), isNull);
    // B is playing: the shared lyrics must not show A's paste.
    expect(AppServices.instance.lyrics.state.value.lyrics.isEmpty, isTrue);
  });

  testWidgetsWithHttp('calibrating shifts the playing song and ends on skip',
      (tester) async {
    final fake = FakeAudioPlayer();
    late BiliBeatsAudioHandler handler;
    await tester.runAsync(() async {
      handler = await startPlaying(server, fake, ['lw-cal-a', 'lw-cal-b']);
    });
    final a = handler.queueSnapshot.tracks[0];
    await pumpPlayer(tester);
    await settle(tester);

    AppServices.instance.lyrics
        .choose(
          a,
          Lyrics(source: 'netease', title: 'x', lines: [
            for (var i = 0; i < 8; i++)
              LyricLine(time: i * 5.0, text: 'line $i'),
          ]),
        )
        .ignore();
    await settle(tester);
    expect(AppServices.instance.lyrics.state.value.status, LyricsStatus.ready);

    await tester.tap(find.byTooltip('歌词'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('歌词选项'));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    await tester.tap(find.text('校准'));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.text('点一下正在唱的那句'), findsOneWidget);
    // The song being timed repeats instead of moving on.
    expect(fake.nativeLoopMode.name, 'one');

    // The playhead is at 0:00; "line 1" (5.0s) is what is being sung.
    await tester.tap(find.text('line 1'));
    await settle(tester);
    expect(LyricsStore.peek(a.id)!.offset, closeTo(-5.2, 0.01));
    expect(LyricsStore.peek(a.id)!.lines[1].time, 5.0,
        reason: 'calibration must not rewrite the lines');

    await tester.runAsync(handler.skipToNext);
    await tester.pump();
    await settle(tester);
    expect(find.text('点一下正在唱的那句'), findsNothing);
    expect(fake.nativeLoopMode.name, isNot('one'));
  });
}
