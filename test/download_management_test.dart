import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/audio_download_service.dart';
import 'package:bilibeat/services/database_service.dart';
import 'package:bilibeat/services/download_manager.dart';
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

  test('failed downloads appear with their track and error', () async {
    const name = 'dm-fail-a';
    server.serveError(name);

    await DownloadManager.instance.startDownload(t(name));

    final failed = DownloadManager.instance.failedTasks;
    expect(failed.any((f) => f.track.id == 'ht-$name'), isTrue);
    final entry =
        failed.firstWhere((f) => f.track.id == 'ht-$name');
    expect(entry.error, isNotEmpty);
  });

  test('retry moves a failed task back to active and completes', () async {
    const name = 'dm-retry-a';
    server.serveError(name);

    await DownloadManager.instance.startDownload(t(name));
    expect(DownloadManager.instance.isFailed('ht-$name'), isTrue);

    server.serveInstant(name);
    expect(DownloadManager.instance.retryDownload('ht-$name'), isTrue);

    await waitForTrue(
        () => AudioDownloadService.isDownloaded(t(name)));
    expect(DownloadManager.instance.isFailed('ht-$name'), isFalse);
  });

  test('dismiss drops a failed item without downloading', () async {
    const name = 'dm-dismiss-a';
    server.serveError(name);

    await DownloadManager.instance.startDownload(t(name));
    expect(DownloadManager.instance.isFailed('ht-$name'), isTrue);

    DownloadManager.instance.dismissFailed('ht-$name');
    expect(DownloadManager.instance.isFailed('ht-$name'), isFalse);
    expect(
        await AudioDownloadService.isDownloaded(t(name)), isFalse);
  });

  test('retry of an unknown id returns false', () {
    expect(
        DownloadManager.instance.retryDownload('dm-no-such-id'),
        isFalse);
  });

  test('remove-download preserves playlists and favorites', () async {
    const name = 'dm-preserve-a';
    server.serveInstant(name);
    final track = t(name);

    await DownloadManager.instance.startDownload(track);
    await waitForTrue(
        () => AudioDownloadService.isDownloaded(track));

    final playlist =
        await DatabaseService.createPlaylist('保存测试');
    await DatabaseService.addTrackToPlaylist(playlist.id, track);
    await DatabaseService.toggleFavorite(track);

    await DatabaseService.removeDownloadedTrack(track);

    expect(await AudioDownloadService.isDownloaded(track), isFalse);
    final playlists = await DatabaseService.getPlaylists();
    final reloaded =
        playlists.firstWhere((p) => p.id == playlist.id);
    expect(reloaded.tracks.any((e) => e.id == track.id), isTrue);
    expect(await DatabaseService.isFavorite(track.id), isTrue);
  });

  test('storage breakdown reports downloaded bytes', () async {
    const name = 'dm-size-a';
    server.serveInstant(name);
    final track = t(name);

    await DownloadManager.instance.startDownload(track);
    await waitForTrue(
        () => AudioDownloadService.isDownloaded(track));

    final breakdown =
        await AudioDownloadService.storageBreakdown();
    expect(breakdown[track.id], greaterThan(1024));
  });
}
