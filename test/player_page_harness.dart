import 'dart:io';

import 'package:bilibeats/app/app_services.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/screens/now_playing_page.dart';
import 'package:bilibeats/services/audio_download_service.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as ft;

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

/// testWidgets with real HTTP: flutter_test answers 400 to real hosts,
/// which would break the local audio server.
void testWidgetsWithHttp(String description, WidgetTesterCallback body) {
  ft.testWidgets(
      description, (tester) => HttpOverrides.runZoned(() => body(tester)));
}

/// Downloads [tracks] (served instantly by [server]), creates a handler on
/// [fake], registers it with [AppServices] and starts the first track.
///
/// Run inside `tester.runAsync`: this is real IO.
Future<BiliBeatsAudioHandler> startPlaying(
  LocalAudioServer server,
  FakeAudioPlayer fake,
  List<String> names, {
  List<String>? titles,
}) async {
  final tracks = <Track>[];
  for (var i = 0; i < names.length; i++) {
    server.serveInstant(names[i]);
    final track = serverTrack(
      server,
      names[i],
      title: titles != null ? titles[i] : names[i],
    );
    await AudioDownloadService.ensureDownloaded(track);
    tracks.add(track);
  }
  final handler = BiliBeatsAudioHandler(player: fake, manageAudioSession: false);
  AppServices.init(handler);
  await handler.playTrack(tracks.first, queue: tracks);
  return handler;
}

Future<void> pumpPlayer(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: NowPlayingPage()));
  await tester.pump();
}

/// Drives mixed fake-zone/real-zone work to a UI-observable condition:
/// each pump advances fake time, each real breath lets pending IO finish.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 150 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(done(), isTrue, reason: 'timed out waiting for UI signal');
}

/// Lets work queued from widget interactions settle across both zones.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 100));
  }
}
