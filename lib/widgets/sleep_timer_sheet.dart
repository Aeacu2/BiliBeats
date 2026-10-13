import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../services/audio_player_handler.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/format.dart';
import 'sheet.dart';

/// Pause after a while. All timing lives in the handler; this only selects,
/// displays and cancels.
class SleepTimerSheet extends StatelessWidget {
  const SleepTimerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showAppSheet<void>(
      context,
      builder: (_) => const SleepTimerSheet(),
    );
  }

  static const List<int> _minutes = [15, 30, 45, 60];

  @override
  Widget build(BuildContext context) {
    final handler = AppServices.instance.handler;

    void set(SleepTimerMode mode, {Duration? duration}) {
      Haptics.selection();
      handler.setSleepTimer(mode, duration: duration);
      if (mode != SleepTimerMode.off) Navigator.of(context).pop();
    }

    return ValueListenableBuilder<SleepTimerState>(
      valueListenable: handler.sleepTimerNotifier,
      builder: (context, state, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitle(
              '睡眠定时',
              detail: !state.isActive
                  ? null
                  : state.mode == SleepTimerMode.endOfTrack
                      ? '播完本首后暂停'
                      : '${formatDuration(state.remaining)} 后暂停',
              trailing: state.isActive
                  ? TextButton(
                      onPressed: () => set(SleepTimerMode.off),
                      child: const Text('关闭',
                          style: TextStyle(color: AppColors.accent)),
                    )
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final minutes in _minutes)
                    _Choice(
                      label: '$minutes 分钟',
                      onTap: () => set(
                        SleepTimerMode.duration,
                        duration: Duration(minutes: minutes),
                      ),
                    ),
                  _Choice(
                    label: '播完本首',
                    selected: state.mode == SleepTimerMode.endOfTrack,
                    onTap: () => set(SleepTimerMode.endOfTrack),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Choice({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.textPrimary : AppColors.fieldFill,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Text(
            label,
            style: AppTypography.body.copyWith(
              fontWeight: FontWeight.w500,
              color: selected ? AppColors.background : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
