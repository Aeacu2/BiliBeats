import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../screens/bili_login.dart';
import '../services/bili_account.dart';
import '../services/bili_favorites.dart';
import '../services/bilibili_sdk.dart';
import '../theme/app_theme.dart';
import '../utils/snack.dart';
import 'sheet.dart';
import 'song_tile.dart';

class BiliAccountSheet {
  BiliAccountSheet._();

  static Future<void> show(BuildContext context) async {
    await BiliAccountStore.ensureLoaded();
    if (!context.mounted) return;
    final account = BiliAccountStore.current.value;
    if (account == null) return BiliLogin.start(context);
    await showAppSheet<void>(context,
        builder: (_) => _AccountOptions(account: account));
  }
}

class _AccountOptions extends StatefulWidget {
  const _AccountOptions({required this.account});
  final BiliAccount account;
  @override
  State<_AccountOptions> createState() => _AccountOptionsState();
}

class _AccountOptionsState extends State<_AccountOptions> {
  bool? _history;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // A refused session is expired by the SDK; network trouble keeps it.
    unawaited(BilibiliSdk.accountFor(widget.account.cookies));
  }

  Future<void> _load() async {
    final enabled = await BiliAccountStore.historyEnabled();
    if (mounted) setState(() => _history = enabled);
  }

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetTitle(
              widget.account.name.isEmpty ? '哔哩哔哩' : widget.account.name),
          SheetAction(
              icon: Icons.star_outline_rounded,
              label: '导入收藏夹 / 检查更新',
              onTap: () => showAppSheet<void>(context,
                  expand: true,
                  builder: (_) =>
                      FavoriteFoldersSheet(account: widget.account))),
          SwitchListTile(
            title: const Text('根据观看历史推荐', style: AppTypography.body),
            value: _history ?? false,
            onChanged: _history == null
                ? null
                : (value) async {
                    setState(() => _history = value);
                    await BiliAccountStore.setHistoryEnabled(
                        widget.account, value);
                  },
          ),
          SheetAction(
              icon: Icons.logout_rounded,
              label: '退出登录',
              color: AppColors.danger,
              onTap: () async {
                if (!await confirmAction(context,
                    title: '退出哔哩哔哩账号？', confirm: '退出')) {
                  return;
                }
                await BiliLogin.logOut();
                if (context.mounted) Navigator.pop(context);
              }),
          const SizedBox(height: 8),
        ],
      );
}

class FavoriteFoldersSheet extends StatefulWidget {
  const FavoriteFoldersSheet({super.key, required this.account});
  final BiliAccount account;
  @override
  State<FavoriteFoldersSheet> createState() => _FavoriteFoldersSheetState();
}

class _FavoriteFoldersSheetState extends State<FavoriteFoldersSheet> {
  late Future<List<({int id, String title, int count})>?> _folders =
      BilibiliSdk.favoriteFolders(widget.account.mid);

  @override
  Widget build(BuildContext context) => Column(children: [
        const SheetTitle('导入收藏夹', detail: '选择视频后再下载'),
        Expanded(
            child: FutureBuilder<List<({int id, String title, int count})>?>(
          future: _folders,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final folders = snapshot.data;
            if (folders == null) {
              return Center(
                  child: TextButton(
                      onPressed: () => setState(() {
                            _folders =
                                BilibiliSdk.favoriteFolders(widget.account.mid);
                          }),
                      child: const Text('无法读取收藏夹，重试')));
            }
            if (folders.isEmpty) return const Center(child: Text('没有收藏夹'));
            return ListView.builder(
                itemCount: folders.length,
                itemBuilder: (context, i) {
                  final folder = folders[i];
                  return FutureBuilder<bool>(
                    future:
                        BiliFavorites.isLinked(widget.account.mid, folder.id),
                    builder: (context, linked) => SheetAction(
                      icon: Icons.folder_outlined,
                      label: folder.title,
                      trailing: Text(
                          '${folder.count}${linked.data == true ? ' · 已导入' : ''}',
                          style: AppTypography.caption),
                      onTap: folder.count == 0
                          ? null
                          : () async {
                              await showAppSheet<void>(context,
                                  expand: true,
                                  builder: (_) => FavoriteImportSheet(
                                      account: widget.account,
                                      folderId: folder.id,
                                      folderName: folder.title));
                              if (mounted) setState(() {});
                            },
                    ),
                  );
                });
          },
        )),
      ]);
}

/// No downloads start until the listener accepts the selection. All videos
/// stay visible, including ones the title heuristic did not preselect.
class FavoriteImportSheet extends StatefulWidget {
  const FavoriteImportSheet(
      {super.key,
      required this.account,
      required this.folderId,
      required this.folderName});
  final BiliAccount account;
  final int folderId;
  final String folderName;
  @override
  State<FavoriteImportSheet> createState() => _FavoriteImportSheetState();
}

class _FavoriteImportSheetState extends State<FavoriteImportSheet> {
  late final FavoriteScan _scan = FavoriteScan(widget.folderId, widget.account);
  final Set<String> _selected = {};
  final Map<String, List<Track>> _parts = {};
  final Set<String> _expanding = {};
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  bool _download = true;
  bool _recommend = false;

  List<Track> get _choices => [
        for (final t in _scan.tracks) ...(_parts[t.bvid] ?? [t])
      ];

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    unawaited(
        BiliFavorites.usesRecommendations(widget.account.mid, widget.folderId)
            .then((value) {
      if (mounted) setState(() => _recommend = value);
    }));
  }

  @override
  void dispose() {
    _scan.cancelled = true;
    super.dispose();
  }

  Future<void> _read() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await _scan.read(onProgress: () {
        if (mounted) setState(() {});
      });
      if (!mounted) return;
      _selected
          .addAll(_scan.tracks.where(BiliFavorites.suggest).map((t) => t.id));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _expand(Track track) async {
    setState(() => _expanding.add(track.bvid));
    try {
      final parts = await BilibiliSdk.fetchVideoInfo(track.bvid);
      if (!mounted) return;
      if (parts.isEmpty) {
        throw const BiliApiException('视频已失效');
      }
      setState(() => _parts[track.bvid] = parts);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(ScaffoldMessenger.of(context), message: '分P读取失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _expanding.remove(track.bvid));
    }
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      final selected = _choices.where((t) => _selected.contains(t.id)).toList();
      final result = await BiliFavorites.importSelection(
          account: widget.account,
          folderId: widget.folderId,
          folderName: widget.folderName,
          tracks: selected,
          recommend: _recommend,
          download: _download);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      showAppSnackBar(messenger,
          message: result.queued > 0
              ? '已加入歌单，${result.queued} 首加入下载队列'
              : '已更新歌单「${widget.folderName}」');
    } catch (_) {
      if (mounted) {
        showAppSnackBar(ScaffoldMessenger.of(context),
            message: '导入失败，请重试或重新登录');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final choices = _choices;
    final count = choices.where((t) => _selected.contains(t.id)).length;
    return Column(children: [
      SheetTitle('选择收藏', detail: widget.folderName),
      if (_loading || _failed)
        Expanded(
            child: Center(
                child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading) const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
                _failed
                    ? '读取中断，已读取 ${_scan.tracks.length} 条'
                    : '已读取 ${_scan.tracks.length} 条',
                style: AppTypography.bodyMedium),
            if (_failed)
              TextButton(onPressed: _read, child: const Text('继续读取')),
          ],
        )))
      else ...[
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              const Expanded(
                  child: Text('按标题预选，可调整', style: AppTypography.caption)),
              TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _selected.addAll(choices.map((t) => t.id));
                          }),
                  child: const Text('全选')),
              TextButton(
                  onPressed: _busy ? null : () => setState(_selected.clear),
                  child: const Text('清空')),
            ])),
        Expanded(
            child: choices.isEmpty
                ? const Center(child: Text('没有可导入的视频'))
                : ListView.builder(
                    itemCount: choices.length,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemBuilder: (context, i) {
                      final t = choices[i];
                      void toggle() => setState(() {
                            if (!_selected.add(t.id)) _selected.remove(t.id);
                          });
                      return SongTile(
                        track: t,
                        showActions: false,
                        onTap: _busy ? null : toggle,
                        leading: Checkbox(
                            value: _selected.contains(t.id),
                            onChanged: _busy ? null : (_) => toggle()),
                        trailing: _expanding.contains(t.bvid)
                            ? const SizedBox(
                                width: 48,
                                height: 48,
                                child: Center(
                                    child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator())))
                            : _parts.containsKey(t.bvid)
                                ? const SizedBox(width: 48)
                                : IconButton(
                                    tooltip: '选择分P',
                                    icon: const Icon(Icons.list_rounded),
                                    onPressed: _busy ? null : () => _expand(t)),
                      );
                    })),
        SwitchListTile(
            title: const Text('下载到本机', style: AppTypography.bodyMedium),
            value: _download,
            onChanged:
                _busy ? null : (value) => setState(() => _download = value)),
        SwitchListTile(
            title: const Text('用这个歌单推荐', style: AppTypography.bodyMedium),
            value: _recommend,
            onChanged:
                _busy ? null : (value) => setState(() => _recommend = value)),
        Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: PrimaryButton(
                label:
                    _busy ? '正在加入…' : '${_download ? '下载所选' : '加入歌单'} $count 首',
                onPressed: _busy || count == 0 || _expanding.isNotEmpty
                    ? null
                    : _accept)),
      ],
    ]);
  }
}
