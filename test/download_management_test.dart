import 'dart:async';
import 'dart:io';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/audio_download_service.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/download_manager.dart';
import 'package:bilibeats/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// Download management verification (M5 §4, M2 §6.3): failed tracking,
/// retry/dismiss, live active state, and download-only removal that
/// preserves collection membership.
void main() {
  late LocalAudioServer server;

  setUpAll(() async {
    await stubDocs('download_mgmt');
    useRealHttp();
    server = await LocalAudioServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  Track t(String name) => serverTrack(server, name);

  test('concurrent callers await the same completed download', () async {
    const name = 'dm-shared';
    server.serveInstant(name);
    final first = DownloadManager.instance.startDownload(t(name));
    final second = DownloadManager.instance.startDownload(t(name));
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(await AudioDownloadService.isDownloaded(t(name)), isTrue);
  });

  test('cancelling during the initial file check does not start a download',
      () async {
    const name = 'dm-cancel-before-start';
    server.serveInstant(name);
    final future = DownloadManager.instance.startDownload(t(name));
    DownloadManager.instance.cancelDownload(t(name).id);
    await future;
    expect(await AudioDownloadService.isDownloaded(t(name)), isFalse);
  });

  test('failed downloads appear with their track and error', () async {
    const name = 'dm-fail-a';
    server.serveError(name);

    await DownloadManager.instance.startDownload(t(name));

    final failed = DownloadManager.instance.failedTasks;
    expect(failed.any((f) => f.track.id == 'ht-$name'), isTrue);
    final entry = failed.firstWhere((f) => f.track.id == 'ht-$name');
    expect(entry.error, isNotEmpty);
  });

  test('retry moves a failed task back to active and completes', () async {
    const name = 'dm-retry-a';
    server.serveError(name);

    await DownloadManager.instance.startDownload(t(name));
    expect(DownloadManager.instance.isFailed('ht-$name'), isTrue);

    server.serveInstant(name);
    expect(DownloadManager.instance.retryDownload('ht-$name'), isTrue);

    await waitForTrue(() => AudioDownloadService.isDownloaded(t(name)));
    expect(DownloadManager.instance.isFailed('ht-$name'), isFalse);
  });

  test('dismiss drops a failed item without downloading', () async {
    const name = 'dm-dismiss-a';
    server.serveError(name);

    await DownloadManager.instance.startDownload(t(name));
    expect(DownloadManager.instance.isFailed('ht-$name'), isTrue);

    DownloadManager.instance.dismissFailed('ht-$name');
    expect(DownloadManager.instance.isFailed('ht-$name'), isFalse);
    expect(await AudioDownloadService.isDownloaded(t(name)), isFalse);
  });

  test('retry of an unknown id returns false', () {
    expect(DownloadManager.instance.retryDownload('dm-no-such-id'), isFalse);
  });

  test('remove-download preserves playlists and favorites', () async {
    const name = 'dm-preserve-a';
    server.serveInstant(name);
    final track = t(name);

    await DownloadManager.instance.startDownload(track);
    await waitForTrue(() => AudioDownloadService.isDownloaded(track));

    final playlist = await DatabaseService.createPlaylist('保存测试');
    await DatabaseService.addTrackToPlaylist(playlist.id, track);
    await DatabaseService.toggleFavorite(track);

    await DatabaseService.removeDownloadedTrack(track);

    expect(await AudioDownloadService.isDownloaded(track), isFalse);
    final playlists = await DatabaseService.getPlaylists();
    final reloaded = playlists.firstWhere((p) => p.id == playlist.id);
    expect(reloaded.tracks.any((e) => e.id == track.id), isTrue);
    expect(await DatabaseService.isFavorite(track.id), isTrue);
  });

  test('a song taken out of a playlist goes back where it was', () async {
    final songs = [t('dm-undo-a'), t('dm-undo-b'), t('dm-undo-c')];
    final playlist = await DatabaseService.createPlaylist('撤销测试');
    await DatabaseService.addTracksToPlaylist(playlist.id, songs);

    await DatabaseService.removeTrackFromPlaylist(playlist.id, songs[1].id);
    await DatabaseService.insertTrackInPlaylist(playlist.id, songs[1], 1);
    // Twice is still once.
    await DatabaseService.insertTrackInPlaylist(playlist.id, songs[1], 1);

    final reloaded = (await DatabaseService.getPlaylists())
        .firstWhere((p) => p.id == playlist.id);
    expect(reloaded.tracks.map((e) => e.id), songs.map((e) => e.id));
  });

  test('storage breakdown reports downloaded bytes', () async {
    const name = 'dm-size-a';
    server.serveInstant(name);
    final track = t(name);

    await DownloadManager.instance.startDownload(track);
    await waitForTrue(() => AudioDownloadService.isDownloaded(track));

    final breakdown = await AudioDownloadService.storageBreakdown();
    expect(breakdown[track.id], greaterThan(1024));
  });

  group('formatBytes', () {
    test('formats zero and small byte counts in B', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-10), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('formats kilobytes correctly', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(50 * 1024), '50.0 KB');
      expect(formatBytes(512 * 1024), '512 KB');
    });

    test('formats megabytes correctly without inflating to GB', () {
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes((5.4 * 1024 * 1024).round()), '5.4 MB');
      expect(formatBytes(120 * 1024 * 1024), '120 MB');
    });

    test('formats gigabytes correctly', () {
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatBytes((2.5 * 1024 * 1024 * 1024).round()), '2.5 GB');
    });
  });

  test('a download called off is neither kept nor listed as failed', () async {
    const name = 'dm-cancel-a';
    final gate = Completer<void>();
    server.serveGated(name, gate);
    final track = t(name);

    final running = DownloadManager.instance.startDownload(track);
    await waitFor(() => DownloadManager.instance.isDownloading(track.id));
    DownloadManager.instance.cancelDownload(track.id);
    gate.complete();
    await running;

    expect(DownloadManager.instance.isDownloading(track.id), isFalse);
    expect(DownloadManager.instance.isFailed(track.id), isFalse);
    expect(await AudioDownloadService.isDownloaded(track), isFalse);
    final path = await AudioDownloadService.audioPathForId(track.id);
    expect(await File('$path.part').exists(), isFalse);

    // And it can be downloaded afterwards like any other.
    server.serveInstant(name);
    await DownloadManager.instance.startDownload(track);
    expect(await AudioDownloadService.isDownloaded(track), isTrue);
  });
}
