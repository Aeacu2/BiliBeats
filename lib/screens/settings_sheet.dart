import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_services.dart';
import '../services/audio_folder.dart';
import '../services/audio_player_handler.dart';
import '../services/bili_account.dart';
import '../services/background_protection.dart';
import '../services/error_log.dart';
import '../services/library_transfer.dart';
import '../services/local_songs.dart';
import '../services/track_naming.dart';
import '../theme/app_theme.dart';
import '../utils/snack.dart';
import '../widgets/bili_account_sheet.dart';
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
    unawaited(BiliAccountStore.ensureLoaded());
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

  /// The library as text on the clipboard, to paste on another device.
  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final snapshot = await LibraryTransfer.snapshot();
    if (snapshot.tracks.isEmpty) {
      showAppSnackBar(messenger, message: '资料库是空的');
      return;
    }
    await Clipboard.setData(
        ClipboardData(text: LibraryTransfer.encode(snapshot)));
    navigator.pop();
    showAppSnackBar(messenger,
        message: '已复制 ${snapshot.tracks.length} 首，在另一台设备上导入');
  }

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final pasted = await Clipboard.getData(Clipboard.kTextPlain);
    final snapshot = LibraryTransfer.decode(pasted?.text ?? '');
    if (snapshot == null) {
      showAppSnackBar(messenger, message: '先在另一台设备上导出并复制');
      return;
    }
    final under = navigator.context;
    if (!under.mounted) return;
    navigator.pop();
    final confirmed = await showAppSheet<bool>(
      under,
      builder: (context) => _ImportConfirm(snapshot: snapshot),
    );
    if (confirmed != true) return;
    final result = await LibraryTransfer.import(snapshot);
    showAppSnackBar(messenger,
        message: result.queued == 0 ? '歌曲都已在资料库中' : '正在下载 ${result.queued} 首');
  }

  /// Audio files from the phone's storage, kept like downloads.
  Future<void> _importLocal() async {
    final messenger = ScaffoldMessenger.of(context);
    final LocalImport? result;
    try {
      result = await LocalSongs.pick();
    } catch (e) {
      showAppSnackBar(messenger, message: '无法导入');
      return;
    }
    if (result == null) {
      showAppSnackBar(messenger, message: '没有可以选择文件的应用');
      return;
    }
    final added = result.added.length;
    final message = [
      if (added > 0) '已导入 $added 首',
      if (result.existing.isNotEmpty) '${result.existing.length} 首已在资料库中',
      if (result.failed > 0) '${result.failed} 个文件无法导入',
    ].join('，');
    if (message.isNotEmpty) showAppSnackBar(messenger, message: message);
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
        _AppVolume(handler: handler),
        _Toggle(
          icon: Icons.auto_awesome_outlined,
          label: '自动匹配歌曲信息',
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
        if (AudioFolder.supported)
          SheetAction(
            icon: Icons.folder_open_rounded,
            label: '音频文件',
            trailing: const Icon(Icons.chevron_right_rounded,
                color: AppColors.textFaint),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              if (!await AudioFolder.open()) {
                showAppSnackBar(messenger,
                    message: '在系统「文件」App 的侧栏中打开 BiliBeats');
              }
            },
          ),
        if (LocalSongs.supported)
          SheetAction(
            icon: Icons.audio_file_outlined,
            label: '导入本地歌曲',
            onTap: _importLocal,
          ),
        SheetAction(
          icon: Icons.ios_share_rounded,
          label: '导出资料库',
          onTap: _export,
        ),
        SheetAction(
          icon: Icons.content_paste_go_rounded,
          label: '导入资料库',
          onTap: _import,
        ),
        // Optional: everything works without it; logged in, subtitles
        // help with names, lyrics and trims, and favourites can be
        // imported. Never asked for anywhere else.
        ValueListenableBuilder<int>(
          valueListenable: BiliAccountStore.changes,
          builder: (context, revision, _) {
            final account = BiliAccountStore.current.value;
            return SheetAction(
              icon: Icons.account_circle_outlined,
              label: '哔哩哔哩账号',
              trailing: Text(
                account == null
                    ? (BiliAccountStore.expired ? '登录已失效' : '未登录')
                    : (account.name.isEmpty ? '已登录' : account.name),
                style: AppTypography.caption,
              ),
              onTap: () {
                final navigator = Navigator.of(context);
                navigator.pop();
                unawaited(BiliAccountSheet.show(navigator.context));
              },
            );
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
        // Only once something went wrong: for a bug report.
        ValueListenableBuilder<bool>(
          valueListenable: ErrorLog.hasEntries,
          builder: (context, any, _) => !any
              ? const SizedBox.shrink()
              : SheetAction(
                  icon: Icons.bug_report_outlined,
                  label: '复制错误日志',
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.of(context).pop();
                    await Clipboard.setData(
                        ClipboardData(text: await ErrorLog.read()));
                    await ErrorLog.clear();
                    showAppSnackBar(messenger, message: '已复制，可粘贴到反馈中');
                  },
                ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ImportConfirm extends StatelessWidget {
  final LibrarySnapshot snapshot;

  const _ImportConfirm({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final lists = snapshot.playlists.where((p) => !p.favorites).length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitle(lists == 0
            ? '${snapshot.tracks.length} 首歌曲'
            : '${snapshot.tracks.length} 首歌曲 · $lists 个歌单'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: PrimaryButton(
            label: '导入',
            icon: Icons.download_rounded,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ),
      ],
    );
  }
}

/// The app's own volume, over the level 音量均衡 brings songs to: set once,
/// it holds while other apps move the phone's media volume. Above 0 dB
/// where the platform can boost (Android).
class _AppVolume extends StatelessWidget {
  final BiliBeatsAudioHandler handler;

  const _AppVolume({required this.handler});

  static String _label(double db) {
    if (db == 0) return '标准';
    final size = db.abs().round();
    return db > 0 ? '+$size dB' : '−$size dB';
  }

  @override
  Widget build(BuildContext context) {
    const min = BiliBeatsAudioHandler.minAppGainDb;
    final max = handler.maxAppGainDb;
    return ValueListenableBuilder<double>(
      valueListenable: handler.appGain,
      builder: (context, db, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              const Icon(Icons.volume_up_rounded,
                  size: 23, color: AppColors.textSecondary),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: AppColors.textPrimary,
                    inactiveTrackColor: AppColors.white24,
                    thumbColor: AppColors.textPrimary,
                    overlayColor: AppColors.white12,
                    tickMarkShape: SliderTickMarkShape.noTickMark,
                    showValueIndicator: ShowValueIndicator.never,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                      elevation: 0,
                      pressedElevation: 0,
                    ),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 16),
                  ),
                  child: Slider(
                    value: db,
                    min: min,
                    max: max,
                    // Whole decibels: 标准 is easy to land on again.
                    divisions: (max - min).round(),
                    semanticFormatterCallback: _label,
                    onChanged: (v) =>
                        unawaited(handler.setAppGain(v, save: false)),
                    onChangeEnd: (v) => unawaited(handler.setAppGain(v)),
                  ),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  _label(db),
                  textAlign: TextAlign.end,
                  style: AppTypography.caption.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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
