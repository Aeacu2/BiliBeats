import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A restrained grouping surface.
///
/// Keep this for grouped controls and collection shortcuts.
/// Track lists should continue using TrackRow.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double borderRadius;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius = AppRadius.md,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: AppColors.hairline),
      ),
      child: child,
    );
  }
}
