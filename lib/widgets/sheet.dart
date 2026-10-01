import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Opens the app's one kind of bottom sheet: rounded, elevated surface with a
/// grab handle. Content sizes itself; pass [expand] for a tall, scrollable
/// sheet (queue, downloads, lyrics).
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool expand = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.backgroundElevated,
    builder: (context) {
      final body = Column(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Handle(),
          if (expand) Expanded(child: builder(context)) else builder(context),
        ],
      );
      return Padding(
        // Sheets with a text field rise with the keyboard.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: expand
              ? FractionallySizedBox(heightFactor: 0.82, child: body)
              : body,
        ),
      );
    },
  );
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 8, bottom: 6),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// A sheet's title line, with an optional control on the right.
class SheetTitle extends StatelessWidget {
  final String title;
  final String? detail;
  final Widget? trailing;

  const SheetTitle(this.title, {super.key, this.detail, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Text(title, style: AppTypography.title),
            if (detail != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption.copyWith(fontSize: 13),
                ),
              ),
            ] else
              const Spacer(),
            if (trailing != null) trailing!,
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// One tappable line in a sheet: icon, label, optional trailing widget.
class SheetAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final Widget? trailing;

  const SheetAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final tint = color ?? AppColors.textPrimary;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                Icon(icon, size: 23, color: color ?? AppColors.textSecondary),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body.copyWith(color: tint),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The filled, full-width button that ends a form or leads a sheet.
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// Quieter fill, for the second of two side-by-side buttons.
  final bool secondary;

  /// 0..1 fills the button from the left (a download in flight).
  final double? progress;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.secondary = false,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null || progress != null;
    final foreground = secondary || progress != null
        ? AppColors.textPrimary
        : AppColors.background;
    final fill = secondary || progress != null
        ? AppColors.white10
        : (enabled ? AppColors.textPrimary : AppColors.white24);

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: fill)),
          if (progress != null)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress!.clamp(0.0, 1.0),
                child: const ColoredBox(color: AppColors.accent50),
              ),
            ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                height: 48,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: foreground, size: 22),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      label,
                      style: AppTypography.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: foreground,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for one line of text. Returns the trimmed value, or null if
/// cancelled or left empty.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String confirm,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: AppTypography.body,
        onSubmitted: (value) => Navigator.pop(ctx, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(confirm, style: const TextStyle(color: AppColors.accent)),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// Asks before something destructive. True when confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String confirm,
  String? message,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm, style: const TextStyle(color: AppColors.danger)),
        ),
      ],
    ),
  );
  return ok == true;
}
