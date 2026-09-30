import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A section title inside a page: 最近播放, 歌单, 已下载 · 12 …
class SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.count,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(20, 20, 12, 6),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Text(title, style: AppTypography.section),
            if (count != null) ...[
              const SizedBox(width: 8),
              Text(
                '$count',
                style: AppTypography.section.copyWith(
                  color: AppColors.textFaint,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
