import 'dart:io';

import 'package:bilibeat/models/lyric_line.dart';
import 'package:bilibeat/services/database_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Targeted tests for the lyric-ownership patch (Prompt 2):
/// UI load generations live in widgets (not unit-testable without a running
/// app), so these cover the [DatabaseService] half of the contract —
/// revision registration, stale-commit rejection, session reads, and
/// failure propagation. Widget/handler halves are verified by review +
/// manual QA (see summary).
///
/// Each test uses unique track ids: the service keeps process-wide static
/// state with no reset hook, and ids must not cross-talk.
void main() {
  late Directory docsDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = await Directory.systemTemp.createTemp('bilibeat_lyric_own_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return docsDir.path;
      }
      return null;
    });
  });

  LyricsResult res(String source, String title, String text) => LyricsResult(
        source: source,
        songTitle: title,
        artistName: 'artist',
        lines: [LyricLine(time: 1.0, text: text)],
      );

  test('stale automatic commit is rejected after a manual save', () async {
    const id = 'own-t1-auto-vs-manual';
    final manual = res('user', 'manual pick', 'manual line');
    final auto = res('netease', 'auto result', 'auto line');

    final revBefore = DatabaseService.lyricsRevisionFor(id);
    await DatabaseService.cacheLyrics(id, manual);

    final accepted = await DatabaseService.cacheAutomaticLyrics(
      id,
      auto,
      expectedRevision: revBefore,
    );

    expect(accepted, isFalse);
    final cached = await DatabaseService.getCachedLyrics(id);
    expect(cached?.songTitle, 'manual pick');
    expect(cached?.lines.single.text, 'manual line');
  });

  test('automatic commit is accepted when nothing superseded it', () async {
    const id = 'own-t2-auto-clean';
    final auto = res('netease', 'auto result', 'auto line');

    final rev = DatabaseService.lyricsRevisionFor(id);
    final accepted = await DatabaseService.cacheAutomaticLyrics(
      id,
      auto,
      expectedRevision: rev,
    );

    expect(accepted, isTrue);
    final cached = await DatabaseService.getCachedLyrics(id);
    expect(cached?.songTitle, 'auto result');
  });

  test('manual choice 2 supersedes manual choice 1', () async {
    const id = 'own-t3-manual-order';
    final first = res('netease', 'choice one', 'line one');
    final second = res('user', 'choice two', 'line two');

    final save1 = DatabaseService.cacheLyrics(id, first);
    final save2 = DatabaseService.cacheLyrics(id, second);
    await Future.wait([save1, save2]);

    final cached = await DatabaseService.getCachedLyrics(id);
    expect(cached?.songTitle, 'choice two');
    expect(cached?.lines.single.text, 'line two');
  });

  test('manual selection is readable synchronously, before disk write',
      () async {
    const id = 'own-t4-sync-register';
    final manual = res('user', 'sync pick', 'sync line');

    final save = DatabaseService.cacheLyrics(id, manual);
    // No await yet: registration must already be visible.
    expect(DatabaseService.manualLyricsFor(id)?.songTitle, 'sync pick');

    await save;
    expect((await DatabaseService.getCachedLyrics(id))?.songTitle, 'sync pick');
  });

  test('manual save for A leaves B untouched', () async {
    const a = 'own-t5-track-a';
    const b = 'own-t5-track-b';

    await DatabaseService.cacheLyrics(a, res('user', 'A pick', 'A line'));

    expect(DatabaseService.manualLyricsFor(b), isNull);
    expect(DatabaseService.lyricsRevisionFor(b), 0);
  });

  test('automatic none-result removes the entry without a placeholder',
      () async {
    const id = 'own-t6-auto-none';

    final rev = DatabaseService.lyricsRevisionFor(id);
    final accepted = await DatabaseService.cacheAutomaticLyrics(
      id,
      res('none', 'nothing', 'nothing'),
      expectedRevision: rev,
    );

    expect(accepted, isTrue);
    expect(await DatabaseService.getCachedLyrics(id), isNull);
  });

  // Last: deliberately breaks the lyrics file location so the disk write
  // fails. Verifies the session selection survives and the failure
  // propagates instead of reading back as saved.
  test('failed disk write keeps the session choice and reports failure',
      () async {
    const id = 'own-t7-write-fails';
    final manual = res('user', 'kept pick', 'kept line');

    final blockerPath = '${docsDir.path}/bilibeat_lyrics.json';
    final blockerFile = File(blockerPath);
    if (await blockerFile.exists()) {
      await blockerFile.delete();
    }
    final blocker = Directory(blockerPath);
    if (!await blocker.exists()) {
      await blocker.create();
    }

    await expectLater(
      DatabaseService.cacheLyrics(id, manual),
      throwsA(isA<FileSystemException>()),
    );

    expect(DatabaseService.manualLyricsFor(id)?.songTitle, 'kept pick');
    expect((await DatabaseService.getCachedLyrics(id))?.songTitle, 'kept pick');
  });
}
