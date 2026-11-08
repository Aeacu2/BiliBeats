import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'audio_download_service.dart';
import 'bili_account.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';
import 'download_manager.dart';

/// One track eligible for upgrading to a higher audio quality.
@immutable
class QualityUpgradeCandidate {
  final Track track;
  final String currentQuality;
  final int currentQualityId;
  final String targetQuality;
  final int targetQualityId;
  final int? targetBandwidth;

  const QualityUpgradeCandidate({
    required this.track,
    required this.currentQuality,
    required this.currentQualityId,
    required this.targetQuality,
    required this.targetQualityId,
    this.targetBandwidth,
  });
}

enum QualityScanState { idle, scanning, finished, stopped }

/// Owns a scan independently of the sheet displaying it.
class QualityScanController extends ChangeNotifier {
  QualityScanController({this.scan = QualityUpgradeService.scanAll});

  static final instance = QualityScanController();

  final Future<List<QualityUpgradeCandidate>> Function({
    void Function(int, int)? onProgress,
    bool Function()? isCancelled,
  }) scan;
  QualityScanState state = QualityScanState.idle;
  int scanned = 0;
  int total = 0;
  List<QualityUpgradeCandidate> candidates = [];
  int _generation = 0;

  Future<void> start() async {
    if (state == QualityScanState.scanning) return;
    final generation = ++_generation;
    state = QualityScanState.scanning;
    scanned = total = 0;
    candidates = [];
    notifyListeners();
    try {
      await BiliAccountStore.ensureLoaded();
      if (generation != _generation) return;
      final results = await scan(
        onProgress: (current, count) {
          if (generation != _generation) return;
          scanned = current;
          total = count;
          notifyListeners();
        },
        isCancelled: () => generation != _generation,
      );
      if (generation != _generation) return;
      candidates = results;
      state = QualityScanState.finished;
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('Quality scan failed: $e');
      state = QualityScanState.stopped;
    }
    notifyListeners();
  }

  void stop() {
    if (state != QualityScanState.scanning) return;
    _generation++;
    state = QualityScanState.stopped;
    notifyListeners();
  }

  void remove(String id) {
    candidates = candidates.where((c) => c.track.id != id).toList();
    notifyListeners();
  }
}

class QualityUpgradeService {
  QualityUpgradeService._();

  /// Assigns higher numbers to higher quality audio tiers.
  static int qualityRank(int qualityId) =>
      BilibiliSdk.audioQualityRank(qualityId);

  /// Checks if [track] can be upgraded to a higher quality on Bilibili.
  static Future<QualityUpgradeCandidate?> checkTrack(Track track) async {
    if (track.isLocal) return null;

    final localInfo = await AudioDownloadService.qualityInfo(track.id);
    if (localInfo != null) {
      final currentQualityId = localInfo['qualityId'] as int? ?? 30232;
      final currentRank = qualityRank(currentQualityId);
      // If already at the highest possible tier (Hi-Res FLAC), no upgrade is possible.
      if (currentRank >= 500) return null;
    }

    final stream = await BilibiliSdk.fetchAudioStream(track.bvid, track.cid);
    if (stream == null || stream.containsKey('unavailable')) return null;

    final targetQualityId = int.tryParse(stream['qualityId'] ?? '') ?? 30232;
    final targetQuality = stream['quality'] ?? '标准品质';
    final targetBandwidth = int.tryParse(stream['bandwidth'] ?? '');
    final targetRank = qualityRank(targetQualityId);

    if (localInfo != null) {
      final currentQualityId = localInfo['qualityId'] as int? ?? 30232;
      final currentQuality = localInfo['quality'] as String? ?? '标准品质';
      final currentRank = qualityRank(currentQualityId);

      if (targetRank > currentRank) {
        return QualityUpgradeCandidate(
          track: track,
          currentQuality: currentQuality,
          currentQualityId: currentQualityId,
          targetQuality: targetQuality,
          targetQualityId: targetQualityId,
          targetBandwidth: targetBandwidth,
        );
      }
      return null;
    }

    // Older downloads have no quality record; offer a replacement without
    // claiming to know whether it is better than the file already present.
    if (targetRank >= 300) {
      return QualityUpgradeCandidate(
        track: track,
        currentQuality: '未知',
        currentQualityId: 0,
        targetQuality: targetQuality,
        targetQualityId: targetQualityId,
        targetBandwidth: targetBandwidth,
      );
    }

    return null;
  }

  /// Scans all offline tracks and returns candidates that can be upgraded.
  static Future<List<QualityUpgradeCandidate>> scanAll({
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final downloaded = await DatabaseService.getDownloadedTracks();
    final onlineTracks = downloaded.where((t) => !t.isLocal).toList();
    final candidates = <QualityUpgradeCandidate>[];

    for (var i = 0; i < onlineTracks.length; i++) {
      if (isCancelled?.call() == true) break;
      onProgress?.call(i + 1, onlineTracks.length);
      final track = onlineTracks[i];
      final localInfo = await AudioDownloadService.qualityInfo(track.id);
      if (localInfo != null) {
        final currentQualityId = localInfo['qualityId'] as int? ?? 30232;
        if (qualityRank(currentQualityId) >= 500) {
          // Already at Hi-Res; skip network check and rate-limit delay.
          continue;
        }
      }
      try {
        final candidate = await checkTrack(track);
        if (candidate != null) {
          candidates.add(candidate);
        }
      } catch (e) {
        debugPrint('checkTrack error for ${track.id}: $e');
      }
      // Polite interval to avoid triggering rate-limits
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    return candidates;
  }

  /// Triggers an in-place upgrade download for [candidate].
  static Future<void> upgrade(QualityUpgradeCandidate candidate) async {
    final before = await AudioDownloadService.qualityInfo(candidate.track.id);
    await DownloadManager.instance.startDownload(candidate.track,
        force: true,
        minimumQualityRank: qualityRank(candidate.targetQualityId));
    if (DownloadManager.instance.isFailed(candidate.track.id)) {
      throw StateError('下载失败，请在下载管理中重试');
    }
    final after = await AudioDownloadService.qualityInfo(candidate.track.id);
    if (after == null || after['updatedAt'] == before?['updatedAt']) {
      throw StateError('下载未完成');
    }
  }

  /// Triggers upgrades for all [candidates].
  static Future<void> upgradeAll(
      List<QualityUpgradeCandidate> candidates) async {
    for (final candidate in candidates) {
      try {
        await upgrade(candidate);
      } catch (e) {
        debugPrint('Quality upgrade failed for ${candidate.track.id}: $e');
      }
    }
  }
}
