import 'dart:convert';

import 'package:bilibeats/app/app_services.dart';
import 'package:bilibeats/screens/search_view.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';
import 'player_page_harness.dart' show pumpUntil;

void main() {
  setUpAll(() async {
    final docs = await stubDocs('search_pagination');
    addTearDown(() => docs.delete(recursive: true));
    useHermeticHttp();
  });

  testWidgets('a keyword search can advance when the first page fits', (
    tester,
  ) async {
    const query = 'pagination regression';
    final pages = <int>[];
    BilibiliSdk.requestWith = (url, {cookies}) async {
      final uri = Uri.parse(url);
      if (!uri.path.endsWith('/search/type')) return null;
      final page = int.parse(uri.queryParameters['page']!);
      pages.add(page);
      return jsonEncode({
        'code': 0,
        'data': {
          'result': [
            if (page <= 2)
              {'bvid': 'pagination-$page', 'title': 'Result $page'},
          ],
        },
      });
    };
    addTearDown(() => BilibiliSdk.requestWith = null);

    final handler = (await tester.runAsync(() async {
      final handler = BiliBeatsAudioHandler(
        player: FakeAudioPlayer(),
        manageAudioSession: false,
      );
      AppServices.init(handler);
      await AppServices.instance.library.reload();
      await AppServices.instance.onlineSearch.search(query);
      return handler;
    }))!;
    final text = ValueNotifier(query);
    addTearDown(text.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchView(query: text, onSearchOnline: (_) {}),
        ),
      ),
    );

    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      0,
    );
    expect(find.text('Result 1'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await pumpUntil(tester, () => find.text('Result 2').evaluate().isNotEmpty);
    await tester.tap(find.text('加载更多'));
    await pumpUntil(tester, () => AppServices.instance.onlineSearch.reachedEnd);
    await tester.pump();

    expect(pages, [1, 2, 3]);
    expect(find.text('加载更多'), findsNothing);
    expect(find.text('Result 1'), findsOneWidget);
    expect(find.text('Result 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(handler.dispose);
  });
}
