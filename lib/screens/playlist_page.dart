import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../app/app_services.dart';
import '../app/playback_actions.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/database_service.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/snack.dart';
import '../widgets/add_local_tracks_sheet.dart';
import '../widgets/cached_cover_image.dart';
import '../widgets/empty_state.dart';
import '../widgets/mini_player.dart';
import '../widgets/pill_button.dart';
import '../widgets/song_tile.dart';
import '../widgets/track_options_menu.dart';
import 'now_playing_page.dart';

/// A playlist (or 收藏) as a full page.
///
/// Reads the playlist live from [LibraryController] by id, so edits made
/// anywhere (the player, a song's sheet) show up here immediately.
class PlaylistPage extends StatefulWidget {
  final String playlistId;

  const PlaylistPage({super.key, required this.playlistId});

  static Future<void> open(BuildContext context, String playlistId) {
    FocusManager.instance.primaryFocus?.unfocus();
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlaylistPage(playlistId: playlistId),
    ));
  }

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  LibraryController get _library => AppServices.instance.library;

  bool _editing = false;
  final Set<String> _selected = {};

  /// Optimistic order while a reorder is being persisted.
  List<Track>? _pendingOrder;

  /// Rows swiped away whose removal is still being persisted. A dismissed
  /// row must leave the tree immediately.
  final Set<String> _removing = {};

  final GlobalKey _miniPlayerKey = GlobalKey();

  Playlist? get _playlist {
    for (final p in _library.playlists) {
      if (p.id == widget.playlistId) return p;
    }
    return null;
  }

  bool get _isFavorites => widget.playlistId == Playlist.favoritesId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _library,
      builder: (context, _) {
        final playlist = _playlist;
        if (playlist == null) {
          // Deleted elsewhere.
          return const Scaffold(backgroundColor: AppColors.background);
        }
        final tracks = [
          for (final t in _pendingOrder ?? playlist.tracks)
            if (!_removing.contains(t.id)) t,
        ];
        final playable = _library.playableOf(tracks);

        return PopScope(
          canPop: !_editing,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _editing) _toggleEditing();
          },
          child: Scaffold(
            backgroundColor: AppColors.background,
            body: Column(
              children: [
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      _appBar(playlist),
                      SliverToBoxAdapter(
                        child: _header(playlist, tracks, playable),
                      ),
                      if (tracks.isEmpty)
                        const SliverToBoxAdapter(
                          child: EmptyState(
                            icon: Icons.library_music_rounded,
                            title: '暂无歌曲',
                            subtitle: '在歌曲的「更多」中选择「加入歌单」',
                          ),
                        )
                      else
                        _list(playlist, tracks, playable),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
                if (_editing)
                  _editBar(playlist, tracks)
                else
                  KeyedSubtree(
                    key: _miniPlayerKey,
                    child: MiniPlayer(
                      handler: AppServices.instance.handler,
                      onTap: _openPlayer,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openPlayer() {
    final box = _miniPlayerKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    unawaited(NowPlayingPage.open(context, from: rect));
  }

  Widget _appBar(Playlist playlist) {
    return SliverAppBar(
      pinned: true,
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      leading: _editing
          ? TextButton(
              onPressed: () => setState(() {
                final all = (_pendingOrder ?? playlist.tracks)
                    .map((t) => t.id)
                    .toSet();
                if (_selected.length == all.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(all);
                }
              }),
              child: const Text('全选', style: TextStyle(color: AppColors.accent)),
            )
          : null,
      leadingWidth: _editing ? 72 : null,
      actions: [
        if (playlist.tracks.isNotEmpty)
          TextButton(
            onPressed: _toggleEditing,
            child: Text(
              _editing ? '完成' : '编辑',
              style: TextStyle(
                color: _editing ? AppColors.accent : AppColors.textSecondary,
                fontWeight: _editing ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        if (!_isFavorites && !_editing)
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz_rounded,
                color: AppColors.textSecondary),
            onSelected: (action) => switch (action) {
              'add' => _addLocalTracks(playlist),
              'rename' => _rename(playlist),
              'cover' => _pickCover(playlist),
              'delete' => _delete(playlist),
              _ => null,
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'add', child: Text('添加已下载歌曲')),
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'cover', child: Text('更换封面')),
              PopupMenuItem(
                value: 'delete',
                child: Text('删除歌单', style: TextStyle(color: AppColors.danger)),
              ),
            ],
          ),
      ],
    );
  }

  Widget _header(Playlist playlist, List<Track> tracks, List<Track> playable) {
    final cover = playlist.coverUrl;
    final fallback = tracks.isNotEmpty ? tracks.first.coverUrl : '';
    final art = (cover != null && cover.isNotEmpty) ? cover : fallback;
    const size = 128.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: art.isNotEmpty
                    ? CachedCoverImage(url: art, width: size, height: size)
                    : SizedBox(
                        width: size,
                        height: size,
                        child: ColoredBox(
                          color: AppColors.fieldFill,
                          child: Icon(
                            _isFavorites
                                ? Icons.favorite_rounded
                                : Icons.queue_music_rounded,
                            size: 48,
                            color: _isFavorites
                                ? AppColors.accent
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.largeTitle.copyWith(fontSize: 26),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      playable.length == tracks.length
                          ? '${tracks.length} 首'
                          : '${tracks.length} 首 · ${playable.length} 首可播放',
                      style: AppTypography.caption.copyWith(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (tracks.isNotEmpty && !_editing) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: PillButton(
                    icon: Icons.play_arrow_rounded,
                    label: '播放',
                    onPressed:
                        playable.isEmpty ? null : () => playCollection(playable),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PillButton(
                    icon: Icons.shuffle_rounded,
                    label: '随机播放',
                    onPressed: playable.isEmpty
                        ? null
                        : () => playCollection(playable, shuffle: true),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _list(Playlist playlist, List<Track> tracks, List<Track> playable) {
    if (_editing) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverReorderableList(
          itemCount: tracks.length,
          onReorderItem: (oldIndex, newIndex) =>
              _reorder(playlist, tracks, oldIndex, newIndex),
          itemBuilder: (context, index) {
            final track = tracks[index];
            final selected = _selected.contains(track.id);
            return Material(
              key: ValueKey(track.id),
              color: AppColors.background,
              child: SongTile(
                track: track,
                onTap: () => setState(() {
                  selected
                      ? _selected.remove(track.id)
                      : _selected.add(track.id);
                }),
                leading: Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? AppColors.accent : AppColors.textFaint,
                ),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: const SizedBox(
                    width: 44,
                    height: 48,
                    child: Icon(Icons.drag_handle_rounded,
                        color: AppColors.textFaint),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList.builder(
        itemCount: tracks.length,
        itemBuilder: (context, index) {
          final track = tracks[index];
          return Dismissible(
            key: ValueKey('dismiss-${track.id}'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: const Icon(Icons.playlist_remove_rounded,
                  color: AppColors.danger),
            ),
            onDismissed: (_) => _removeOne(playlist, track),
            child: SongTile(
              track: track,
              queue: playable,
              showDownload: !_library.isDownloaded(track.id),
              onTap: () => openTrack(context, track, queue: playable),
            ),
          );
        },
      ),
    );
  }

  Widget _editBar(Playlist playlist, List<Track> tracks) {
    final count = _selected.length;
    final selectedTracks = [
      for (final t in tracks)
        if (_selected.contains(t.id)) t,
    ];
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          color: AppColors.backgroundElevated,
          border: Border(top: BorderSide(color: AppColors.hairline)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: count == 0
                    ? null
                    : () => TrackOptionsMenu.showAddToPlaylistForTracks(
                          context,
                          selectedTracks,
                          onTrackChanged: () => setState(() {
                            _editing = false;
                            _selected.clear();
                          }),
                        ),
                icon: const Icon(Icons.playlist_add_rounded),
                label: Text('加入歌单 ($count)'),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                onPressed:
                    count == 0 ? null : () => _removeSelected(playlist),
                icon: const Icon(Icons.playlist_remove_rounded),
                label: Text('移出歌单 ($count)'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _toggleEditing() {
    Haptics.light();
    setState(() {
      _editing = !_editing;
      _selected.clear();
    });
  }

  Future<void> _reorder(
    Playlist playlist,
    List<Track> tracks,
    int oldIndex,
    int newIndex,
  ) async {
    Haptics.selection();
    // onReorderItem already reports newIndex adjusted for the removal.
    final target = newIndex;
    final order = List<Track>.of(tracks);
    order.insert(target, order.removeAt(oldIndex));
    setState(() => _pendingOrder = order);
    await DatabaseService.reorderPlaylist(playlist.id, oldIndex, target);
    if (mounted) setState(() => _pendingOrder = null);
  }

  Future<void> _removeOne(Playlist playlist, Track track) async {
    setState(() => _removing.add(track.id));
    await DatabaseService.removeTrackFromPlaylist(playlist.id, track.id);
    await _library.reload();
    if (mounted) setState(() => _removing.remove(track.id));
  }

  Future<void> _removeSelected(Playlist playlist) async {
    final ids = _selected.toList();
    await DatabaseService.removeTracksFromPlaylist(playlist.id, ids);
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _editing = false;
    });
  }

  Future<void> _addLocalTracks(Playlist playlist) async {
    final downloaded = _library.downloaded;
    if (downloaded.isEmpty) {
      showAppSnackBar(
        ScaffoldMessenger.of(context),
        message: '还没有已下载的歌曲',
        backgroundColor: AppColors.backgroundElevated,
      );
      return;
    }
    await AddLocalTracksSheet.show(
      context,
      downloaded: downloaded,
      existingIds: playlist.tracks.map((t) => t.id).toSet(),
      playlistId: playlist.id,
      onAdded: _library.reload,
    );
  }

  Future<void> _rename(Playlist playlist) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppTypography.body,
          decoration: const InputDecoration(hintText: '歌单名称'),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty && name.trim() != playlist.name) {
      await DatabaseService.renamePlaylist(playlist.id, name.trim());
    }
  }

  Future<void> _pickCover(Playlist playlist) async {
    try {
      final image = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (image == null) return;
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/bilibeat_covers');
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = image.path.split('.').last;
      final saved = File('${dir.path}/playlist_${playlist.id}_'
          '${DateTime.now().millisecondsSinceEpoch}.$ext');
      await File(image.path).copy(saved.path);
      await DatabaseService.setPlaylistCover(playlist.id, saved.path);
    } catch (e) {
      debugPrint('Playlist cover pick failed: $e');
    }
  }

  Future<void> _delete(Playlist playlist) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('「${playlist.name}」将被删除，歌曲与本地音频保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    navigator.pop();
    await DatabaseService.deletePlaylist(playlist.id);
  }
}

/// Creates a playlist from the 歌单 header and opens it.
Future<void> createAndOpenPlaylist(BuildContext context) async {
  final created = await createPlaylistDialog(context);
  if (created != null && context.mounted) {
    await PlaylistPage.open(context, created.id);
  }
}

/// Asks for a playlist name and creates it. Returns the new playlist.
Future<Playlist?> createPlaylistDialog(BuildContext context) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('新建歌单'),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: AppTypography.body,
        decoration: const InputDecoration(hintText: '歌单名称'),
        onSubmitted: (value) => Navigator.pop(ctx, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('创建', style: TextStyle(color: AppColors.accent)),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || name.trim().isEmpty) return null;
  return DatabaseService.createPlaylist(name);
}
