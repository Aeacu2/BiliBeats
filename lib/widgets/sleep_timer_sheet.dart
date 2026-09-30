import 'package:flutter/material.dart';

import '../services/audio_player_handler.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/format.dart';
import 'glass_card.dart';

/// Small sleep-timer surface. All timing lives in the handler; this only
/// selects, displays, and cancels.
class SleepTimerSheet extends StatefulWidget {
  final BiliBeatAudioHandler handler;

  const SleepTimerSheet({
    super.key,
    required this.handler,
  });

  static Future<void> show(
    BuildContext context, {
    required BiliBeatAudioHandler handler,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: AppColors.backgroundElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
      builder: (context) {
        return SleepTimerSheet(handler: handler);
      },
    );
  }

  @override
  State<SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<SleepTimerSheet> {
  SleepTimerState get _state => widget.handler.sleepTimerState;

  @override
  void initState() {
    super.initState();
    widget.handler.sleepTimerNotifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.handler.sleepTimerNotifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _set(SleepTimerMode mode, {Duration? duration}) {
    Haptics.selection();
    widget.handler.setSleepTimer(mode, duration: duration);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '睡眠定时',
                    style: AppTypography.title,
                  ),
                ),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ],
            ),
            if (_state.isActive) ...[
              const SizedBox(height: 8),
              GlassCard(
                child: Row(
                  children: [
                    const Icon(Icons.bedtime_rounded,
                        color: AppColors.accent, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _state.mode == SleepTimerMode.endOfTrack
                            ? '播完当前歌曲后暂停'
                            : '${formatDuration(_state.remaining)} 后暂停',
                        style: AppTypography.bodyMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _set(SleepTimerMode.off),
                      child: const Text('取消',
                          style: TextStyle(color: AppColors.accent)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            _option(
              label: '15 分钟',
              selected: _state.mode == SleepTimerMode.duration &&
                  _state.remaining.inMinutes <= 15,
              onTap: () =>
                  _set(SleepTimerMode.duration, duration: const Duration(minutes: 15)),
            ),
            _option(
              label: '30 分钟',
              selected: _state.mode == SleepTimerMode.duration &&
                  _state.remaining.inMinutes > 15 &&
                  _state.remaining.inMinutes <= 30,
              onTap: () =>
                  _set(SleepTimerMode.duration, duration: const Duration(minutes: 30)),
            ),
            _option(
              label: '60 分钟',
              selected: _state.mode == SleepTimerMode.duration &&
                  _state.remaining.inMinutes > 30,
              onTap: () =>
                  _set(SleepTimerMode.duration, duration: const Duration(minutes: 60)),
            ),
            _option(
              label: '播完当前歌曲',
              selected: _state.mode == SleepTimerMode.endOfTrack,
              onTap: () => _set(SleepTimerMode.endOfTrack),
            ),
          ],
        ),
      ),
    );
  }

  Widget _option({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: AppTypography.body.copyWith(
                      color: selected
                          ? AppColors.accent
                          : AppColors.textPrimary,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(Icons.check_rounded,
                      color: AppColors.accent, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
