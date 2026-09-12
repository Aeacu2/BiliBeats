import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/haptics.dart';

/// Quiet, text-led navigation.
///
/// Labels keep their natural widths. Selection is communicated through
/// contrast and a short underline, rather than a filled segmented pill.
///
/// Works with the existing PageController animation adapter and with
/// TabController.animation.
class SegmentTabs extends StatelessWidget {
  final List<String> labels;
  final Animation<double> animation;
  final ValueChanged<int> onTap;
  final double fontSize;

  const SegmentTabs({
    super.key,
    required this.labels,
    required this.animation,
    required this.onTap,
    this.fontSize = 23,
  });

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final double value =
            animation.value.clamp(0.0, labels.length - 1).toDouble();

        final selectedIndex = value.round();

        return Material(
          type: MaterialType.transparency,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < labels.length; index++) ...[
                if (index > 0) const SizedBox(width: 24),
                Flexible(
                  child: _label(
                    context,
                    index: index,
                    value: value,
                    selected: selectedIndex == index,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _label(
    BuildContext context, {
    required int index,
    required double value,
    required bool selected,
  }) {
    final emphasis = (1.0 - (value - index).abs()).clamp(0.0, 1.0).toDouble();

    final color = Color.lerp(
      AppColors.textMuted,
      AppColors.textPrimary,
      emphasis,
    )!;

    return Semantics(
      button: true,
      selected: selected,
      label: labels[index],
      child: Tooltip(
        message: labels[index],
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: () {
            if (!selected) Haptics.selection();
            onTap(index);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 48,
              minHeight: 52,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Text(
                      labels[index],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.titleLarge.copyWith(
                        fontSize: fontSize,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(height: 9),
                  Opacity(
                    opacity: emphasis,
                    child: Container(
                      width: 18,
                      height: 2,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
