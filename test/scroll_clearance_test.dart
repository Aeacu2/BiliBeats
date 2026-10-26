import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/app/app_services.dart';
import 'package:bilibeats/app/app_shell.dart';
import 'package:bilibeats/models/playlist.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/screens/artist_page.dart';
import 'package:bilibeats/screens/playlist_page.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/state/library_controller.dart';
import 'package:bilibeats/theme/app_theme.dart';
import 'package:bilibeats/widgets/docked_player.dart';
import 'package:bilibeats/widgets/mini_player.dart';
import 'package:bilibeats/widgets/song_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

void main() {
  late List<Track> tracks;
  late Playlist playlist;

  setUpAll(() async {
    useHermeticHttp();
    final docs = await stubDocs('clearance');
    final audio = Directory('${docs.path}/bilibeat_audio')..createSync();
    tracks = [
      for (var i = 0; i < 12; i++)
        Track(
          id: 'BVclear${i}_p1',
          bvid: 'BVclear$i',
          cid: 1,
          title: 'clear_song_$i',
          rawTitle: 'video $i',
          uploader: 'singer_${i % 3}',
          coverUrl: '',
          duration: 200,
        ),
    ];
    for (final t in tracks) {
      File('${audio.path}/audio_${t.id}.m4a')
          .writeAsBytesSync(List.filled(4096, 1));
      File('${audio.path}/audio_${t.id}.ready').writeAsBytesSync([]);
      File('${audio.path}/audio_${t.id}.json')
          .writeAsStringSync(jsonEncode(t.toMap()));
    }
    File('${docs.path}/bilibeat_downloaded.json')
        .writeAsStringSync(jsonEncode([for (final t in tracks) t.toMap()]));
    playlist = Playlist(id: 'pl_test', name: '测试歌单', tracks: tracks);
    final plMap = playlist.toMap();
    plMap['tracks'] = tracks.map((t) => t.toMap()).toList();
    File('${docs.path}/bilibeat_playlists.json').writeAsStringSync(jsonEncode({
      'schema_version': 1,
      'data': [plMap]
    }));
    await DatabaseService.getDownloadedTracks();
    await DatabaseService.getPlaylists();
  });

  Future<BiliBeatsAudioHandler> boot(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(tester.view.reset);
    final handler = BiliBeatsAudioHandler(
        player: FakeAudioPlayer(), manageAudioSession: false);
    AppServices.init(handler);
    await tester.runAsync(() async {
      await LibraryController.instance.reload();
      await handler.playTrack(tracks[0], queue: tracks);
    });
    await tester.pumpWidget(MaterialApp(theme: AppTheme.darkTheme, home: home));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    return handler;
  }

  Future<void> finish(
      WidgetTester tester, BiliBeatsAudioHandler handler) async {
    await tester.runAsync(() async {
      await handler.pause();
      await handler.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('home page list scrolls above docked player', (tester) async {
    final handler = await boot(tester, const AppShell());
    expect(find.byType(DockedPlayer), findsOneWidget);

    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('clear_song_11'),
      50,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();

    final lastSongRect =
        tester.getRect(find.widgetWithText(SongTile, 'clear_song_11'));
    final dockedRect = tester.getRect(find.byType(MiniPlayer));
    expect(lastSongRect.bottom, lessThanOrEqualTo(dockedRect.top),
        reason: 'Last song in home list must scroll above docked player card');

    await finish(tester, handler);
  });

  testWidgets('playlist page list scrolls above docked player', (tester) async {
    final handler = await boot(tester, PlaylistPage(playlistId: playlist.id));
    expect(find.byType(DockedPlayer), findsOneWidget);

    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('clear_song_11'),
      50,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();

    final lastSongRect =
        tester.getRect(find.widgetWithText(SongTile, 'clear_song_11'));
    final dockedRect = tester.getRect(find.byType(MiniPlayer));
    expect(lastSongRect.bottom, lessThanOrEqualTo(dockedRect.top),
        reason: 'Last song in playlist must scroll above docked player card');

    await finish(tester, handler);
  });

  testWidgets('artist page list scrolls above docked player', (tester) async {
    final handler = await boot(tester, const ArtistPage(name: 'singer_0'));
    expect(find.byType(DockedPlayer), findsOneWidget);

    final scrollable = find.byType(Scrollable).first;
    // singer_0 has songs 0, 3, 6, 9
    await tester.scrollUntilVisible(
      find.text('clear_song_9'),
      300,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();

    final lastSongRect =
        tester.getRect(find.widgetWithText(SongTile, 'clear_song_9'));
    final dockedRect = tester.getRect(find.byType(MiniPlayer));
    expect(lastSongRect.bottom, lessThanOrEqualTo(dockedRect.top),
        reason:
            'Last song in artist page must scroll above docked player card');

    await finish(tester, handler);
  });
}
