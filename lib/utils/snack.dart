import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app's one toast: a small floating pill, the same everywhere.
void showAppSnackBar(
  ScaffoldMessengerState messenger, {
  required String message,
  Duration duration = const Duration(seconds: 2),
}) {
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: AppTypography.bodyMedium.copyWith(color: AppColors.textPrimary),
      ),
      backgroundColor: AppColors.fieldFill,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 48, vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      shape: const StadiumBorder(
        side: BorderSide(color: AppColors.hairline),
      ),
      duration: duration,
    ));
}
