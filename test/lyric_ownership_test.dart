import 'dart:io';

import 'package:bilibeats/models/lyrics.dart';
import 'package:bilibeats/services/lyrics_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who owns a song's lyrics: [LyricsStore]'s half of the contract — a pin
/// registers at once, beats any automatic lookup already in flight, is
/// never evicted, and reports a failed write without losing the choice.
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

  Lyrics res(String source, String title, String text) => Lyrics(
        source: source,
        title: title,
        artist: 'artist',
        lines: [LyricLine(time: 1.0, text: text)],
      );

  test('stale automatic commit is rejected after a manual save', () async {
    const id = 'own-t1-auto-vs-manual';
    final manual = res('user', 'manual pick', 'manual line');
    final auto = res('netease', 'auto result', 'auto line');

    final revBefore = LyricsStore.revisionOf(id);
    await LyricsStore.pin(id, manual);

    final accepted = await LyricsStore.putAutomatic(
      id,
      auto,
      expectedRevision: revBefore,
    );

    expect(accepted, isFalse);
    final cached = await LyricsStore.get(id);
    expect(cached?.title, 'manual pick');
    expect(cached?.lines.single.text, 'manual line');
  });

  test('automatic commit is accepted when nothing superseded it', () async {
    const id = 'own-t2-auto-clean';
    final auto = res('netease', 'auto result', 'auto line');

    final rev = LyricsStore.revisionOf(id);
    final accepted = await LyricsStore.putAutomatic(
      id,
      auto,
      expectedRevision: rev,
    );

    expect(accepted, isTrue);
    final cached = await LyricsStore.get(id);
    expect(cached?.title, 'auto result');
  });

  test('manual choice 2 supersedes manual choice 1', () async {
    const id = 'own-t3-manual-order';
    final first = res('netease', 'choice one', 'line one');
    final second = res('user', 'choice two', 'line two');

    final save1 = LyricsStore.pin(id, first);
    final save2 = LyricsStore.pin(id, second);
    await Future.wait([save1, save2]);

    final cached = await LyricsStore.get(id);
    expect(cached?.title, 'choice two');
    expect(cached?.lines.single.text, 'line two');
  });

  test('manual selection is readable synchronously, before disk write',
      () async {
    const id = 'own-t4-sync-register';
    final manual = res('user', 'sync pick', 'sync line');

    final save = LyricsStore.pin(id, manual);
    // No await yet: registration must already be visible.
    expect(LyricsStore.peek(id)?.title, 'sync pick');

    await save;
    expect((await LyricsStore.get(id))?.title, 'sync pick');
  });

  test('manual save for A leaves B untouched', () async {
    const a = 'own-t5-track-a';
    const b = 'own-t5-track-b';

    await LyricsStore.pin(a, res('user', 'A pick', 'A line'));

    expect(LyricsStore.peek(b), isNull);
    expect(LyricsStore.revisionOf(b), 0);
  });

  test('automatic none-result removes the entry without a placeholder',
      () async {
    const id = 'own-t6-auto-none';

    final rev = LyricsStore.revisionOf(id);
    final accepted = await LyricsStore.putAutomatic(
      id,
      const Lyrics(source: 'none', lines: []),
      expectedRevision: rev,
    );

    expect(accepted, isTrue);
    expect(await LyricsStore.get(id), isNull);
  });

  test('a pin is kept as pinned and survives any number of automatic entries',
      () async {
    const id = 'own-t8-never-evicted';
    await LyricsStore.pin(id, res('user', 'mine', 'my line'));
    for (var i = 0; i < 320; i++) {
      await LyricsStore.putAutomatic(
        'own-t8-filler-$i',
        res('netease', 'auto $i', 'line'),
        expectedRevision: 0,
      );
    }
    final kept = await LyricsStore.get(id);
    expect(kept?.pinned, isTrue);
    expect(kept?.title, 'mine');
    // The automatic cache itself is bounded: the oldest fillers are gone.
    expect(await LyricsStore.get('own-t8-filler-0'), isNull);
    expect(await LyricsStore.get('own-t8-filler-319'), isNotNull);
  });

  test('clearing forgets a pin and lets automatic results in again', () async {
    const id = 'own-t9-clear';
    await LyricsStore.pin(id, res('user', 'mine', 'my line'));
    await LyricsStore.clear(id);
    expect(LyricsStore.peek(id), isNull);

    final accepted = await LyricsStore.putAutomatic(
      id,
      res('netease', 'auto', 'auto line'),
      expectedRevision: LyricsStore.revisionOf(id),
    );
    expect(accepted, isTrue);
    expect((await LyricsStore.get(id))?.pinned, isFalse);
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
      LyricsStore.pin(id, manual),
      throwsA(isA<FileSystemException>()),
    );

    expect(LyricsStore.peek(id)?.title, 'kept pick');
    expect((await LyricsStore.get(id))?.title, 'kept pick');
  });
}
