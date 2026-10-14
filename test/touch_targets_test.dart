import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/app/app_services.dart';
import 'package:bilibeats/app/app_shell.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/screens/now_playing_page.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/state/library_controller.dart';
import 'package:bilibeats/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

/// Every icon control is touched where it is drawn: its touch area is
/// centred on its glyph and at least 48 pt each way.
///
/// A glyph pushed to one edge of its target (to line it up with a margin)
/// leaves the area that answers mostly on one side of what the finger aims
/// at; on the player that made the end buttons and 收藏 feel unresponsive.
/// Line glyphs up by moving the target, never the glyph within it.
void main() {
  late List<Track> tracks;

  setUpAll(() async {
    final docs = await stubDocs('touch');
    final audio = Directory('${docs.path}/bilibeat_audio')..createSync();
    tracks = [
      for (var i = 0; i < 4; i++)
        Track(
          id: 'BVt${i}_p1',
          bvid: 'BVt$i',
          cid: 1,
          title: 'song $i',
          rawTitle: 'video $i',
          uploader: 'singer $i',
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
    await DatabaseService.getDownloadedTracks();
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

  /// Checks each control that carries a tooltip and draws one glyph.
  void expectCentredTargets(WidgetTester tester, {required int atLeast}) {
    var checked = 0;
    for (final element in find.byType(Tooltip).evaluate()) {
      final tooltip = element.widget as Tooltip;
      // An IconButton's tooltip covers its visible 40 pt disc; the area
      // that answers is the whole button, tap-target padding included.
      Element hit = element;
      element.visitAncestorElements((ancestor) {
        if (ancestor.widget is IconButton) {
          hit = ancestor;
          return false;
        }
        return ancestor.widget is! Tooltip &&
            ancestor.depth > element.depth - 16;
      });
      final target = find.byElementPredicate((e) => e == hit);
      final icons =
          find.descendant(of: target, matching: find.byType(Icon)).evaluate();
      if (icons.isEmpty) continue;
      final box = tester.getRect(target);
      final glyph =
          tester.getRect(find.byElementPredicate((e) => e == icons.first));
      final name = tooltip.message;
      expect((box.center - glyph.center).distance, lessThan(1.0),
          reason:
              '「$name」: touch area $box is not centred on its glyph $glyph');
      expect(box.width, greaterThanOrEqualTo(48), reason: '「$name」 width');
      expect(box.height, greaterThanOrEqualTo(48), reason: '「$name」 height');
      checked++;
    }
    expect(checked, greaterThanOrEqualTo(atLeast));
  }

  testWidgets('on the player', (tester) async {
    final handler = await boot(tester, const NowPlayingPage());
    // 收起 · 歌词 · 更多 · 收藏 · play mode · 上一首 · 播放 · 下一首 · 播放队列
    expectCentredTargets(tester, atLeast: 9);
    await finish(tester, handler);
  });

  testWidgets('on the home screen and its mini player', (tester) async {
    final handler = await boot(tester, const AppShell());
    // 设置 · 排序 · each row's 更多 · the mini player's two buttons
    expectCentredTargets(tester, atLeast: 6);

    // A song's sheet.
    await tester.tap(find.byTooltip('更多').first);
    await tester.pump(const Duration(seconds: 1));
    expectCentredTargets(tester, atLeast: 7);
    await tester.tapAt(const Offset(195, 60));
    await tester.pump(const Duration(seconds: 1));

    // Searching: the clear button, the library's matches.
    await tester.tap(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, 'song');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip('清除'), findsOneWidget);
    expectCentredTargets(tester, atLeast: 2);
    await finish(tester, handler);
  });
}
