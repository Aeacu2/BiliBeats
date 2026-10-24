import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/bili_login.dart';
import '../services/bili_account.dart';
import '../services/bilibili_sdk.dart';
import '../services/library_transfer.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/snack.dart';
import 'sheet.dart';

/// 设置 → 哔哩哔哩: log in, import favourites, log out.
class BiliAccountSheet {
  BiliAccountSheet._();

  static Future<void> show(BuildContext context) async {
    await BiliAccountStore.ensureLoaded();
    if (!context.mounted) return;
    final account = BiliAccountStore.current.value;
    if (account == null) return BiliLogin.start(context);

    final navigator = Navigator.of(context);
    final choice = await showAppSheet<String>(
      context,
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle(account.name.isEmpty ? '哔哩哔哩' : account.name),
          SheetAction(
            icon: Icons.star_outline_rounded,
            label: '导入收藏夹',
            trailing: const Icon(Icons.chevron_right_rounded,
                color: AppColors.textFaint),
            onTap: () => Navigator.pop(sheet, 'favorites'),
          ),
          SheetAction(
            icon: Icons.logout_rounded,
            label: '退出登录',
            color: AppColors.danger,
            onTap: () => Navigator.pop(sheet, 'logout'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    final under = navigator.context;
    if (!under.mounted) return;
    switch (choice) {
      case 'favorites':
        await _FavoriteFolders.show(under, account);
        return;
      case 'logout':
        final messenger = ScaffoldMessenger.of(under);
        if (!await confirmAction(under,
            title: '退出哔哩哔哩账号？', confirm: '退出')) {
          return;
        }
        await BiliLogin.logOut();
        showAppSnackBar(messenger, message: '已退出登录');
    }
  }
}

/// The account's favourites folders; one becomes a playlist of the same
/// name, its videos downloaded like an imported library. Importing a
/// folder again adds what was favourited since.
class _FavoriteFolders extends StatefulWidget {
  final BiliAccount account;

  const _FavoriteFolders({required this.account});

  static Future<void> show(BuildContext context, BiliAccount account) =>
      showAppSheet<void>(
        context,
        builder: (_) => _FavoriteFolders(account: account),
      );

  @override
  State<_FavoriteFolders> createState() => _FavoriteFoldersState();
}

class _FavoriteFoldersState extends State<_FavoriteFolders> {
  late Future<List<({int id, String title, int count})>?> _folders =
      BilibiliSdk.favoriteFolders(widget.account.mid);
  int? _importing;

  Future<void> _import(({int id, String title, int count}) folder) async {
    Haptics.light();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importing = folder.id);
    final tracks =
        await BilibiliSdk.favoriteTracks(folder.id, max: folder.count);
    if (!mounted) return;
    setState(() => _importing = null);
    if (tracks == null) {
      showAppSnackBar(messenger, message: '收藏夹读取失败，请重试');
      return;
    }
    if (tracks.isEmpty) {
      showAppSnackBar(messenger, message: '收藏夹里没有可下载的视频');
      return;
    }
    Navigator.of(context).pop();
    final result = await LibraryTransfer.import(LibrarySnapshot(
      tracks: tracks,
      playlists: [(name: folder.title, favorites: false, tracks: tracks)],
    ));
    showAppSnackBar(messenger,
        message: result.queued == 0
            ? '已更新歌单「${folder.title}」'
            : '正在下载 ${result.queued} 首到「${folder.title}」');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<({int id, String title, int count})>?>(
      future: _folders,
      builder: (context, snapshot) {
        final folders = snapshot.data;
        final Widget body;
        if (snapshot.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (folders == null) {
          body = Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: PrimaryButton(
              label: '无法读取收藏夹，重试',
              secondary: true,
              onPressed: () => setState(() {
                _folders = BilibiliSdk.favoriteFolders(widget.account.mid);
              }),
            ),
          );
        } else if (folders.isEmpty) {
          body = const Padding(
            padding: EdgeInsets.all(24),
            child: Text('没有收藏夹',
                textAlign: TextAlign.center, style: AppTypography.bodyMedium),
          );
        } else {
          body = Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final folder in folders)
                  SheetAction(
                    icon: Icons.folder_outlined,
                    label: folder.title,
                    trailing: _importing == folder.id
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text('${folder.count}',
                            style: AppTypography.caption),
                    onTap: _importing == null && folder.count > 0
                        ? () => _import(folder)
                        : null,
                  ),
              ],
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetTitle('导入收藏夹', detail: '每个收藏夹成为一个歌单'),
            body,
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}
