import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../services/background_protection.dart';
import '../theme/app_theme.dart';
import '../utils/snack.dart';
import '../widgets/download_management_sheet.dart';

/// The few things worth a setting.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (_) => const SettingsSheet(),
    );
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text('设置', style: AppTypography.title),
            ),
            if (BackgroundProtection.supported)
              _row(
                icon: Icons.shield_moon_outlined,
                title: '后台播放保护',
                subtitle: _protected == true
                    ? '已开启：BiliBeats 不受电池优化限制'
                    : '部分手机会在后台关闭音乐应用，点按以允许后台运行',
                trailing: _protected == true
                    ? const Icon(Icons.check_circle_rounded,
                        color: AppColors.success)
                    : null,
                onTap: _protected == true
                    ? null
                    : () => unawaited(BackgroundProtection.request()),
              ),
            _row(
              icon: Icons.download_for_offline_outlined,
              title: '下载管理',
              subtitle: '失败重试、已下载歌曲与存储空间',
              onTap: () {
                final navigator = Navigator.of(context);
                final parent = navigator.context;
                navigator.pop();
                DownloadManagementSheet.show(parent);
              },
            ),
            _row(
              icon: Icons.history_rounded,
              title: '清除搜索记录',
              subtitle: '推荐也会随之重新学习',
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                Navigator.of(context).pop();
                await AppServices.instance.onlineSearch.clearHistory();
                showAppSnackBar(
                  messenger,
                  message: '已清除搜索记录',
                  backgroundColor: AppColors.backgroundElevated,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return ListTile(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(title, style: AppTypography.body),
      subtitle: Text(subtitle, style: AppTypography.caption),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
