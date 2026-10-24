import 'dart:async';

import 'package:bilibeats/app/app_services.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:bilibeats/services/bili_account.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/library_transfer.dart';
import 'package:bilibeats/theme/app_theme.dart';
import 'package:bilibeats/widgets/bili_account_sheet.dart';
import 'package:bilibeats/widgets/sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';
import 'favorite_import_fixture.dart';
import 'player_page_harness.dart' show pumpUntil, settle;

void main() {
  setUpAll(() async {
    await stubDocs('favorite_widgets');
    useHermeticHttp();
  });

  testWidgets(
      'preview selects candidates, expands parts, and does not download before accepting',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final handler = (await tester.runAsync(() async {
      final handler = BiliBeatsAudioHandler(
          player: FakeAudioPlayer(), manageAudioSession: false);
      AppServices.init(handler);
      return handler;
    }))!;
    BilibiliSdk.requestWith = favoriteImportResponse;
    var downloads = 0;
    LibraryTransfer.downloadWith = (t) async {
      downloads++;
      return true;
    };
    await tester.runAsync(() => BiliAccountStore.save(importAccount));
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showAppSheet<void>(context,
                        expand: true,
                        builder: (_) => const FavoriteImportSheet(
                            account: importAccount,
                            folderId: 88,
                            folderName: '夜里听')),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await pumpUntil(tester, () => find.text('下载所选 2 首').evaluate().isNotEmpty);
    expect(downloads, 0);
    await settle(tester);
    await tester.tap(find.byTooltip('选择分P').first);
    await pumpUntil(
        tester, () => find.textContaining('P2: 光亮').evaluate().isNotEmpty);
    await settle(tester);
    expect(find.text('下载所选 2 首'), findsOneWidget);
    await tester.tap(find.textContaining('P2: 光亮'));
    await tester.pump();
    expect(find.text('下载所选 3 首'), findsOneWidget);
    await tester.tap(find.text('下载到本机'));
    await tester.pump();
    await tester.tap(find.text('加入歌单 3 首'));
    await pumpUntil(tester, () => find.text('选择收藏').evaluate().isEmpty);
    expect(downloads, 0);
    final playlists = await tester.runAsync(DatabaseService.getPlaylists);
    expect(playlists!.firstWhere((p) => p.name == '夜里听').tracks, hasLength(3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    var cleanedUp = false;
    unawaited(() async {
      await BiliAccountStore.logOut();
      await handler.dispose();
      cleanedUp = true;
    }());
    await pumpUntil(tester, () => cleanedUp);
    BilibiliSdk.requestWith = null;
    LibraryTransfer.downloadWith = null;
  });
}
