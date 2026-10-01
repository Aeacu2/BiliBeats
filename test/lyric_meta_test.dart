import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:bilibeat/services/database_service.dart';
import 'package:bilibeat/widgets/track_info_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';
import 'player_page_harness.dart';

/// 编辑信息 captures its target: saving after playback moved on still edits
/// the song the sheet was opened for.
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
    await settle(tester);

    await tester.tap(find.byTooltip('更多'));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    await tester.tap(find.text('编辑信息'));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byType(TrackInfoSheet), findsOneWidget);

    // Playback moves on underneath the open sheet.
    await tester.runAsync(handler.skipToNext);
    await tester.pump();
    expect(handler.currentTrack?.id, b.id);

    await tester.enterText(
        find
            .descendant(
                of: find.byType(TrackInfoSheet),
                matching: find.byType(TextField))
            .first,
        'Alpha Renamed');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await pumpUntil(
        tester, () => find.byType(TrackInfoSheet).evaluate().isEmpty);
    // Let the debounced session save fire before the test ends.
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);

    final downloaded =
        await tester.runAsync(DatabaseService.getDownloadedTracks);
    expect(
        downloaded!.where((t) => t.id == a.id).single.title, 'Alpha Renamed');
    expect(downloaded.where((t) => t.id == b.id).single.title, 'Beta Song');
  });
}
