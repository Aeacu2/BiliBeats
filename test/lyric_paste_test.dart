import 'package:bilibeat/app/app_services.dart';
import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:bilibeat/services/database_service.dart';
import 'package:bilibeat/widgets/lyric_editor_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';
import 'player_page_harness.dart';

/// Lyrics pasted after playback moved on are saved for the song the editor
/// was opened for, and never published as the new song's lyrics.
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
    late BiliBeatAudioHandler handler;
    await tester.runAsync(() async {
      handler = await startPlaying(server, fake, ['lw-paste-a', 'lw-paste-b']);
    });
    final a = handler.queueSnapshot.tracks[0];
    final b = handler.queueSnapshot.tracks[1];
    await pumpPlayer(tester);

    // Show lyrics, then open the editor on its lyrics tab.
    await tester.tap(find.text('歌词'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.edit_note_rounded));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('歌名'), findsNothing);
    await settle(tester);

    await tester.runAsync(handler.skipToNext);
    await tester.pump();
    expect(handler.currentTrack?.id, b.id);

    await tester.tap(find.text('粘贴 LRC 文本'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '[00:01.00]hello');
    await tester.pump();
    tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '保存'))
        .onPressed!();
    await pumpUntil(
        tester, () => find.byType(LyricEditorDialog).evaluate().isEmpty);

    expect(DatabaseService.manualLyricsFor(a.id)!.lines.single.text, 'hello');
    expect(DatabaseService.manualLyricsFor(b.id), isNull);
    // B is playing: the shared lyrics must not show A's paste.
    expect(AppServices.instance.lyrics.lines.value, isEmpty);
  });
}
