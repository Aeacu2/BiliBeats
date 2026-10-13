import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// What a list shows when it has nothing: a faint glyph and a few words.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;

  /// An optional way forward (e.g. a 重试 button).
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.white24),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTypography.body.copyWith(color: AppColors.textMuted),
            ),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}
