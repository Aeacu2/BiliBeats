import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../services/background_protection.dart';
import '../services/track_naming.dart';
import '../theme/app_theme.dart';
import '../utils/snack.dart';
import '../widgets/download_management_sheet.dart';
import '../widgets/sheet.dart';

/// The few things worth a setting.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showAppSheet<void>(context, builder: (_) => const SettingsSheet());
  }

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet>
    with WidgetsBindingObserver {
  bool? _protected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The exemption is granted in a system dialog; re-read on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!BackgroundProtection.supported) return;
    final enabled = await BackgroundProtection.isEnabled();
    if (mounted) setState(() => _protected = enabled);
  }

  @override
  Widget build(BuildContext context) {
    final handler = AppServices.instance.handler;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetTitle('设置'),
        ValueListenableBuilder<bool>(
          valueListenable: handler.normalizeVolume,
          builder: (context, on, _) => _Toggle(
            icon: Icons.graphic_eq_rounded,
            label: '音量均衡',
            value: on,
            onChanged: handler.setNormalizeVolume,
          ),
        ),
        _Toggle(
          icon: Icons.auto_awesome_outlined,
          label: '自动识别歌名',
          value: TrackNaming.enabled,
          onChanged: (on) async {
            await TrackNaming.setEnabled(on);
            if (mounted) setState(() {});
          },
        ),
        if (BackgroundProtection.supported)
          SheetAction(
            icon: Icons.shield_moon_outlined,
            label: '后台播放保护',
            trailing: _protected == true
                ? const Icon(Icons.check_rounded, color: AppColors.success)
                : const Text('开启',
                    style: TextStyle(color: AppColors.accent, fontSize: 14)),
            onTap: _protected == true
                ? null
                : () => unawaited(BackgroundProtection.request()),
          ),
        SheetAction(
          icon: Icons.download_done_rounded,
          label: '下载管理',
          trailing: const Icon(Icons.chevron_right_rounded,
              color: AppColors.textFaint),
          onTap: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            DownloadManagementSheet.show(navigator.context);
          },
        ),
        SheetAction(
          icon: Icons.history_rounded,
          label: '清除搜索记录',
          onTap: () async {
            final messenger = ScaffoldMessenger.of(context);
            Navigator.of(context).pop();
            await AppServices.instance.onlineSearch.clearHistory();
            showAppSnackBar(messenger, message: '已清除');
          },
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _Toggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SheetAction(
      icon: icon,
      label: label,
      onTap: () => onChanged(!value),
      trailing: IgnorePointer(
        child: Switch(
          value: value,
          onChanged: (_) {},
          activeThumbColor: Colors.white,
          activeTrackColor: AppColors.accent,
          inactiveThumbColor: AppColors.textMuted,
          inactiveTrackColor: AppColors.white12,
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
    );
  }
}
