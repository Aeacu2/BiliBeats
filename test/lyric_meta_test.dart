import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:bilibeat/services/database_service.dart';
import 'package:bilibeat/widgets/lyric_editor_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';
import 'player_page_harness.dart';

/// The editor captures its target: saving after playback moved on still
/// edits the song the editor was opened for.
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

  testWidgetsWithHttp('metadata save targets the captured track',
      (tester) async {
    final fake = FakeAudioPlayer();
    late BiliBeatAudioHandler handler;
    await tester.runAsync(() async {
      handler = await startPlaying(
        server,
        fake,
        ['lw-meta-a', 'lw-meta-b'],
        titles: ['Alpha Song', 'Beta Song'],
      );
    });
    final a = handler.queueSnapshot.tracks[0];
    final b = handler.queueSnapshot.tracks[1];
    await pumpPlayer(tester);

    await tester.tap(find.byIcon(Icons.edit_note_rounded));
    await tester.pump();
    await settle(tester);

    // Playback moves on underneath the open editor.
    await tester.runAsync(handler.skipToNext);
    await tester.pump();
    expect(handler.currentTrack?.id, b.id);

    await tester.enterText(find.byType(TextField).first, 'Alpha Renamed');
    await tester.pump();
    tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '确认'))
        .onPressed!();
    await pumpUntil(
        tester, () => find.byType(LyricEditorDialog).evaluate().isEmpty);

    final downloaded =
        await tester.runAsync(DatabaseService.getDownloadedTracks);
    expect(
        downloaded!.where((t) => t.id == a.id).single.title, 'Alpha Renamed');
    expect(downloaded.where((t) => t.id == b.id).single.title, 'Beta Song');
  });
}
