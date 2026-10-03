// Renders the main screens to PNG, for looking at layout changes without a
// device. Not part of the suite (no `_test` suffix); run it by hand:
//
//   flutter test test/render_screens.dart --update-goldens
//
// Images land in build/screens/. Needs a CJK font at [_cjkFont] (macOS ships
// one); without it the run is skipped.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bilibeats/app/app_services.dart';
import 'package:bilibeats/app/app_shell.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/screens/now_playing_page.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/state/library_controller.dart';
import 'package:bilibeats/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

const _cjkFont = '/Library/Fonts/Arial Unicode.ttf';
final _out = '${Directory.current.path}/build/screens';

const _songs = [
  ['大鱼', '周深', '【4K60帧】周深《大鱼》现场 纯享版'],
  ['光年之外', 'G.E.M.邓紫棋', 'G.E.M.邓紫棋【光年之外】MV'],
  ['起风了', '买辣椒也用券', '起风了'],
  ['岁月', '黄绮珊 & 周深', '【声生不息3】 黄绮珊&周深《岁月》'],
  ['孤勇者', '陈奕迅', '陈奕迅 - 孤勇者'],
  ['夜曲', '周杰伦', '周杰伦《夜曲》'],
  ['Lemon', '米津玄師', '米津玄師 - Lemon'],
  ['晴天', '周杰伦', '周杰伦《晴天》'],
  ['不舍', '周深', '周深翻唱《不舍》'],
  ['平凡之路', '朴树', '朴树 - 平凡之路'],
];

/// A soft two-colour gradient standing in for album art.
Future<List<int>> _cover(int i) async {
  const size = 240.0;
  final hue = (i * 47) % 360;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(size, size), [
        HSLColor.fromAHSL(1, hue.toDouble(), 0.75, 0.6).toColor(),
        HSLColor.fromAHSL(1, (hue + 70) % 360, 0.6, 0.25).toColor(),
      ]),
  );
  final image = await recorder.endRecording().toImage(240, 240);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.view(File(path).readAsBytesSync().buffer);
  for (final family in ['Roboto', '.SF Pro Text', '.SF Pro Display']) {
    final loader = FontLoader(family)
      ..addFont(bytes(_cjkFont));
    await loader.load();
  }
  // The SDK's own copy of the icon font (`flutter test` sets FLUTTER_ROOT).
  final icons = FontLoader('MaterialIcons')
    ..addFont(bytes('${Platform.environment['FLUTTER_ROOT']}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

void main() {
  if (!File(_cjkFont).existsSync()) {
    print('No CJK font at $_cjkFont; nothing rendered.');
    return;
  }

  late Directory docs;
  late List<Track> tracks;

  setUpAll(() async {
    docs = await stubDocs('shots');
    await _loadFonts();
    final audio = Directory('${docs.path}/bilibeat_audio')..createSync();
    final covers = Directory('${docs.path}/covers')..createSync();
    for (var i = 0; i < _songs.length; i++) {
      File('${covers.path}/c$i.png').writeAsBytesSync(await _cover(i));
    }
    tracks = [
      for (var i = 0; i < _songs.length; i++)
        Track(
          id: 'BVs${i}_p1',
          bvid: 'BVs$i',
          cid: 1,
          title: _songs[i][0],
          rawTitle: _songs[i][2],
          uploader: _songs[i][1],
          coverUrl: '${covers.path}/c$i.png',
          duration: 200 + i * 7,
          loudness: -14,
        ),
    ];
    for (final t in tracks) {
      File('${audio.path}/audio_${t.id}.m4a').writeAsBytesSync(List.filled(4096, 1));
      File('${audio.path}/audio_${t.id}.ready').writeAsBytesSync([]);
      File('${audio.path}/audio_${t.id}.json')
          .writeAsStringSync(jsonEncode(t.toMap()));
    }
    File('${docs.path}/bilibeat_downloaded.json')
        .writeAsStringSync(jsonEncode([for (final t in tracks) t.toMap()]));
    File('${docs.path}/bilibeat_recently_played.json').writeAsStringSync(
        jsonEncode([for (final t in tracks.take(6)) t.toMap()]));
    File('${docs.path}/bilibeat_playlists.json').writeAsStringSync(jsonEncode([
      {
        'id': 'favorites',
        'name': '收藏',
        'tracks': [for (final t in tracks.take(4)) t.toMap()],
      },
      {
        'id': 'pl_1',
        'name': '深夜循环',
        'tracks': [for (final t in tracks.skip(3).take(5)) t.toMap()],
      },
      {
        'id': 'pl_2',
        'name': '通勤',
        'tracks': [for (final t in tracks.skip(6)) t.toMap()],
      },
    ]));
    // Loaded here, in real time: the library parse runs in an isolate,
    // which never completes under a widget test's fake clock.
    await DatabaseService.getDownloadedTracks();
  });

  Future<void> settle(WidgetTester tester, [int rounds = 12]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    print('$_out/$name.png');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$_out/$name.png'),
    );
  }

  Future<BiliBeatsAudioHandler> boot(WidgetTester tester,
      {bool play = true}) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    tester.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(tester.view.reset);

    final fake = FakeAudioPlayer()
      ..positionValue = const Duration(seconds: 72);
    final handler =
        BiliBeatsAudioHandler(player: fake, manageAudioSession: false);
    AppServices.init(handler);
    await tester.runAsync(() async {
      await LibraryController.instance.reload();
      if (play) await handler.playTrack(tracks[0], queue: tracks);
    });
    return handler;
  }

  /// Stops the handler's timers, which a widget test may not leave pending.
  Future<void> finish(
      WidgetTester tester, BiliBeatsAudioHandler handler) async {
    await tester.runAsync(() async {
      await handler.pause();
      await handler.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('home lenses', (tester) async {
    final handler = await boot(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme.copyWith(textTheme: AppTheme.darkTheme.textTheme.apply(fontFamily: 'Roboto')),
      debugShowCheckedModeBanner: false,
      home: const AppShell(),
    ));
    await shot(tester, 'home_songs');
    await tester.tap(find.text('歌单'));
    await shot(tester, 'home_playlists');
    await tester.tap(find.text('歌手'));
    await shot(tester, 'home_artists');
    await finish(tester, handler);
  });

  testWidgets('player', (tester) async {
    final handler = await boot(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme.copyWith(textTheme: AppTheme.darkTheme.textTheme.apply(fontFamily: 'Roboto')),
      debugShowCheckedModeBanner: false,
      home: const NowPlayingPage(),
    ));
    await shot(tester, 'player');
    await finish(tester, handler);
  });
}
