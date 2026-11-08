import 'dart:async';

import 'package:flutter/material.dart';

import '../services/bili_account.dart';
import '../services/quality_upgrade_service.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/snack.dart';
import 'bili_account_sheet.dart';
import 'empty_state.dart';
import 'sheet.dart';
import 'song_tile.dart';

/// Sheet that checks offline tracks for available audio quality upgrades
/// (e.g. 132k -> 320k or Hi-Res lossless FLAC) and lets the user upgrade them.
class QualityUpgradeSheet extends StatefulWidget {
  const QualityUpgradeSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showAppSheet<void>(
      context,
      expand: true,
      builder: (_) => const QualityUpgradeSheet(),
    );
  }

  @override
  State<QualityUpgradeSheet> createState() => _QualityUpgradeSheetState();
}

class _QualityUpgradeSheetState extends State<QualityUpgradeSheet> {
  final _scan = QualityScanController.instance;
  QualityScanState get _state => _scan.state;
  int get _scanned => _scan.scanned;
  int get _total => _scan.total;
  List<QualityUpgradeCandidate> get _candidates => _scan.candidates;
  final Set<String> _upgradingIds = {};

  @override
  void initState() {
    super.initState();
    _scan.addListener(_refresh);
    if (_state == QualityScanState.idle) unawaited(_scan.start());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scan.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _upgradeCandidate(QualityUpgradeCandidate candidate) async {
    Haptics.light();
    setState(() {
      _upgradingIds.add(candidate.track.id);
    });
    try {
      await QualityUpgradeService.upgrade(candidate);
      _scan.remove(candidate.track.id);
      if (!mounted) return;
      showAppSnackBar(ScaffoldMessenger.of(context),
          message: '已重新下载「${candidate.track.title}」');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(ScaffoldMessenger.of(context), message: '升级失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _upgradingIds.remove(candidate.track.id);
        });
      }
    }
  }

  Future<void> _upgradeAll() async {
    if (_candidates.isEmpty) return;
    Haptics.medium();
    final messenger = ScaffoldMessenger.of(context);
    final count = _candidates.length;
    final toUpgrade = List<QualityUpgradeCandidate>.from(_candidates);
    for (final candidate in toUpgrade) {
      _scan.remove(candidate.track.id);
    }
    Navigator.of(context).pop();
    unawaited(QualityUpgradeService.upgradeAll(toUpgrade));
    showAppSnackBar(messenger, message: '正在逐首重新下载 $count 首歌曲，请保持应用运行');
  }

  Widget _buildAccountBanner() {
    final account = BiliAccountStore.current.value;
    if (account == null) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.white10,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.white10),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded,
                color: AppColors.accent, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '未登录 B 站账号，最高仅可获取 132k 音质。建议登录大会员以获取 Hi-Res 无损。',
                style: AppTypography.caption,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                final navigator = Navigator.of(context);
                navigator.pop();
                unawaited(BiliAccountSheet.show(navigator.context));
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text(
                  '去登录',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.account_circle_outlined,
              size: 16, color: AppColors.textFaint),
          const SizedBox(width: 6),
          Text(
            '当前账号：${account.name.isNotEmpty ? account.name : "已登录"}',
            style: AppTypography.caption,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_state == QualityScanState.scanning) {
      final progress = _total > 0 ? _scanned / _total : 0.0;
      return Expanded(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 32),
              SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  value: _total > 0 ? progress : null,
                  strokeWidth: 3,
                  color: AppColors.accent,
                  backgroundColor: AppColors.white10,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '正在检查音质... ($_scanned/$_total)',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '对比本地文件与 B 站最新可用流...',
                style: AppTypography.caption,
              ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: _scan.stop,
                child: const Text('停止检查',
                    style: TextStyle(color: AppColors.textFaint)),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      );
    }

    if (_state == QualityScanState.stopped) {
      return Expanded(
        child: Center(
          child: TextButton(
            onPressed: () => unawaited(_scan.start()),
            child: const Text('重新检查'),
          ),
        ),
      );
    }

    if (_state == QualityScanState.finished) {
      if (_candidates.isEmpty) {
        return Expanded(
          child: EmptyState(
            icon: Icons.verified_rounded,
            title: _total == 0 ? '暂无已下载的在线歌曲' : '当前所有歌曲已是最高音质',
          ),
        );
      }

      return Expanded(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Text(
                    '发现 ${_candidates.length} 首歌曲可提升音质',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _candidates.length,
                itemBuilder: (context, index) {
                  final candidate = _candidates[index];
                  final isHiRes = candidate.targetQuality.contains('Hi-Res') ||
                      candidate.targetQualityId == 30251;
                  final isDolby = candidate.targetQuality.contains('杜比') ||
                      candidate.targetQualityId == 30250;
                  final isUpgrading =
                      _upgradingIds.contains(candidate.track.id);

                  return SongTile(
                    key: ValueKey('candidate-${candidate.track.id}'),
                    track: candidate.track,
                    detail:
                        '${candidate.currentQuality}  ➔  ${candidate.targetQuality}',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isHiRes || isDolby)
                          Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isHiRes
                                  ? const Color(0x2ED4AF37)
                                  : const Color(0x2EFF6699),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: isHiRes
                                    ? const Color(0xFFD4AF37)
                                    : AppColors.accent,
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              isHiRes ? 'Hi-Res' : 'Dolby',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isHiRes
                                    ? const Color(0xFFE5C158)
                                    : AppColors.accent,
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: '立即升级',
                          icon: isUpgrading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.arrow_upward_rounded,
                                  color: AppColors.accent),
                          onPressed: isUpgrading
                              ? null
                              : () => _upgradeCandidate(candidate),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: PrimaryButton(
                label: '一键全部升级 (${_candidates.length} 首)',
                icon: Icons.upgrade_rounded,
                onPressed: _upgradeAll,
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitle(
          '检查更新音质',
          detail: _state == QualityScanState.finished && _candidates.isNotEmpty
              ? '${_candidates.length} 首可升级'
              : null,
          trailing: _state == QualityScanState.finished
              ? IconButton(
                  tooltip: '重新检查',
                  onPressed: () => unawaited(_scan.start()),
                  icon: const Icon(Icons.refresh_rounded),
                )
              : null,
        ),
        _buildAccountBanner(),
        _buildBody(),
      ],
    );
  }
}
