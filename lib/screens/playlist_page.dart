import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/playback_actions.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/database_service.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/cover_picker.dart';
import '../utils/snack.dart';
import '../widgets/collection_header.dart';
import '../widgets/docked_player.dart';
import '../widgets/empty_state.dart';
import '../widgets/sheet.dart';
import '../widgets/song_tile.dart';
import '../widgets/track_sheet.dart';

/// A playlist (or 收藏) as a full page.
///
/// Reads the playlist live from [LibraryController] by id, so edits made
/// anywhere (the player, a song's sheet) show up here immediately. Swipe a
/// row away to remove it; 编辑 turns on multi-select and reordering.
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
        final cover = playlist.coverUrl;

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
                      _appBar(playlist, tracks),
                      SliverToBoxAdapter(
                        child: CollectionHeader(
                          title: playlist.name,
                          coverUrl: cover != null && cover.isNotEmpty
                              ? cover
                              : (tracks.isNotEmpty
                                  ? tracks.first.coverUrl
                                  : ''),
                          placeholder: _isFavorites
                              ? Icons.favorite_rounded
                              : Icons.queue_music_rounded,
                          placeholderColor: _isFavorites
                              ? AppColors.accent
                              : AppColors.textMuted,
                          playable: playable,
                          count: tracks.length,
                          showActions: !_editing,
                        ),
                      ),
                      if (tracks.isEmpty)
                        SliverToBoxAdapter(
                          child: EmptyState(
                            icon: Icons.library_music_outlined,
                            title: '还没有歌曲',
                            action: _isFavorites
                                ? null
                                : TextButton(
                                    onPressed: () => _addSongs(playlist),
                                    child: const Text('添加歌曲',
                                        style:
                                            TextStyle(color: AppColors.accent)),
                                  ),
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
                  const DockedPlayer(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _appBar(Playlist playlist, List<Track> tracks) {
    return SliverAppBar(
      pinned: true,
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      leading: _editing
          ? TextButton(
              onPressed: () => setState(() {
                final all = tracks.map((t) => t.id).toSet();
                if (_selected.length == all.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(all);
                }
              }),
              child: const Text('全选'),
            )
          : null,
      leadingWidth: _editing ? 72 : null,
      actions: [
        if (_editing)
          TextButton(
            onPressed: _toggleEditing,
            child: const Text('完成',
                style: TextStyle(
                    color: AppColors.accent, fontWeight: FontWeight.w600)),
          )
        else if (!_isFavorites || tracks.isNotEmpty)
          IconButton(
            tooltip: '更多',
            onPressed: () => _showMenu(playlist),
            icon: const Icon(Icons.more_horiz_rounded,
                color: AppColors.textSecondary),
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  void _showMenu(Playlist playlist) {
    showAppSheet<void>(
      context,
      builder: (sheet) {
        void run(void Function() action) {
          Navigator.pop(sheet);
          action();
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 4),
            if (!_isFavorites)
              SheetAction(
                icon: Icons.add_rounded,
                label: '添加歌曲',
                onTap: () => run(() => _addSongs(playlist)),
              ),
            if (playlist.tracks.isNotEmpty)
              SheetAction(
                icon: Icons.checklist_rounded,
                label: '编辑',
                onTap: () => run(_toggleEditing),
              ),
            if (!_isFavorites) ...[
              SheetAction(
                icon: Icons.drive_file_rename_outline_rounded,
                label: '重命名',
                onTap: () => run(() => _rename(playlist)),
              ),
              SheetAction(
                icon: Icons.image_outlined,
                label: '更换封面',
                onTap: () => run(() => _pickCover(playlist)),
              ),
              SheetAction(
                icon: Icons.delete_outline_rounded,
                label: '删除歌单',
                color: AppColors.danger,
                onTap: () => run(() => _delete(playlist)),
              ),
            ],
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Widget _list(Playlist playlist, List<Track> tracks, List<Track> playable) {
    if (_editing) {
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
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
                  color: selected ? AppColors.accent : AppColors.white24,
                ),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: const SizedBox(
                    width: 48,
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
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
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
              child: const Icon(Icons.remove_circle_outline_rounded,
                  color: AppColors.danger),
            ),
            onDismissed: (_) => _removeOne(playlist, track),
            child: SongTile(
              track: track,
              queue: playable,
              onTap: () => openTrack(context, track, queue: playable),
            ),
          );
        },
      ),
    );
  }

  Widget _editBar(Playlist playlist, List<Track> tracks) {
    final selectedTracks = [
      for (final t in tracks)
        if (_selected.contains(t.id)) t,
    ];
    final none = selectedTracks.isEmpty;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: const BoxDecoration(
          color: AppColors.backgroundElevated,
          border: Border(top: BorderSide(color: AppColors.hairline)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: none
                    ? null
                    : () async {
                        final added =
                            await PlaylistPicker.show(context, selectedTracks);
                        if (added && mounted && _editing) _toggleEditing();
                      },
                icon: const Icon(Icons.playlist_add_rounded),
                label: const Text('加入歌单'),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                onPressed: none ? null : () => _removeSelected(playlist),
                icon: const Icon(Icons.remove_circle_outline_rounded),
                label: Text(none ? '移出' : '移出 ${selectedTracks.length} 首'),
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
    final order = List<Track>.of(tracks);
    order.insert(newIndex, order.removeAt(oldIndex));
    setState(() => _pendingOrder = order);
    await DatabaseService.reorderPlaylist(playlist.id, oldIndex, newIndex);
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

  Future<void> _addSongs(Playlist playlist) async {
    final existing = playlist.tracks.map((t) => t.id).toSet();
    final candidates = [
      for (final t in _library.downloaded)
        if (!existing.contains(t.id)) t,
    ];
    if (candidates.isEmpty) {
      showAppSnackBar(ScaffoldMessenger.of(context), message: '没有可添加的歌曲');
      return;
    }
    final picked = await _SongPicker.show(context, candidates);
    if (picked == null || picked.isEmpty) return;
    await DatabaseService.addTracksToPlaylist(playlist.id, picked);
  }

  Future<void> _rename(Playlist playlist) async {
    final name = await promptForText(
      context,
      title: '重命名',
      confirm: '保存',
      initial: playlist.name,
    );
    if (name != null && name != playlist.name) {
      await DatabaseService.renamePlaylist(playlist.id, name);
    }
  }

  Future<void> _pickCover(Playlist playlist) async {
    final path = await pickCoverImage('playlist_${playlist.id}');
    if (path != null) await DatabaseService.setPlaylistCover(playlist.id, path);
  }

  Future<void> _delete(Playlist playlist) async {
    final navigator = Navigator.of(context);
    if (!await confirmAction(
      context,
      title: '删除「${playlist.name}」？',
      message: '歌曲和下载会保留。',
      confirm: '删除',
    )) {
      return;
    }
    navigator.pop();
    await DatabaseService.deletePlaylist(playlist.id);
  }
}

/// Multi-select over downloaded songs, for adding to a playlist.
class _SongPicker extends StatefulWidget {
  final List<Track> tracks;

  const _SongPicker({required this.tracks});

  static Future<List<Track>?> show(BuildContext context, List<Track> tracks) {
    return showAppSheet<List<Track>>(
      context,
      expand: true,
      builder: (_) => _SongPicker(tracks: tracks),
    );
  }

  @override
  State<_SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends State<_SongPicker> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SheetTitle(
          '添加歌曲',
          trailing: TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.pop(context, [
                      for (final t in widget.tracks)
                        if (_selected.contains(t.id)) t,
                    ]),
            child: Text(
              _selected.isEmpty ? '添加' : '添加 ${_selected.length} 首',
              style: TextStyle(
                color:
                    _selected.isEmpty ? AppColors.textFaint : AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
            itemExtent: SongTile.extent,
            itemCount: widget.tracks.length,
            itemBuilder: (context, index) {
              final track = widget.tracks[index];
              final checked = _selected.contains(track.id);
              return SongTile(
                track: track,
                onTap: () => setState(() {
                  checked
                      ? _selected.remove(track.id)
                      : _selected.add(track.id);
                }),
                trailing: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    checked
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: checked ? AppColors.accent : AppColors.white24,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Asks for a name, creates the playlist and opens it.
Future<void> createAndOpenPlaylist(BuildContext context) async {
  final name = await promptForText(context, title: '新建歌单', confirm: '创建');
  if (name == null) return;
  final created = await DatabaseService.createPlaylist(name);
  if (context.mounted) await PlaylistPage.open(context, created.id);
}
