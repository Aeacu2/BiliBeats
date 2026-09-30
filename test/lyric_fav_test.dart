import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:bilibeat/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';
import 'player_page_harness.dart';

/// A favorite toggled on the player belongs to the song it was pressed for,
/// even when playback moves on before the write lands.
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

  testWidgetsWithHttp(
      'favorite started before a switch never touches the new track',
      (tester) async {
    final fake = FakeAudioPlayer();
    late BiliBeatAudioHandler handler;
    await tester.runAsync(() async {
      handler = await startPlaying(server, fake, ['lw-fav-a', 'lw-fav-b']);
    });
    final a = handler.queueSnapshot.tracks[0];
    final b = handler.queueSnapshot.tracks[1];
    await pumpPlayer(tester);

    // Favorite A and switch to B back-to-back.
    tester
        .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.favorite_border_rounded))
        .onPressed!();
    await tester.runAsync(handler.skipToNext);
    await tester.pump();

    await pumpUntil(tester, () => handler.currentTrack?.id == b.id);
    final favLanded = await tester.runAsync(() async {
      for (var i = 0; i < 200; i++) {
        if (await DatabaseService.isFavorite(a.id)) return true;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return false;
    });
    expect(favLanded, isTrue);
    await settle(tester);

    final results = (await tester.runAsync(() async => (
          favA: await DatabaseService.isFavorite(a.id),
          favB: await DatabaseService.isFavorite(b.id),
        )))!;
    expect(results.favA, isTrue);
    expect(results.favB, isFalse);
    // The page now shows B, which is not a favorite.
    expect(find.text(b.title), findsWidgets);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
  });
}
