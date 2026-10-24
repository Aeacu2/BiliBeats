import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/playback_actions.dart';
import '../models/playlist.dart';
import '../services/database_service.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/snack.dart';
import '../widgets/collection_header.dart';
import '../widgets/docked_player.dart';
import '../widgets/sheet.dart';
import '../widgets/song_tile.dart';
import 'playlist_page.dart';

/// Every downloaded song by one artist — a collection that keeps itself up
/// to date, with nothing to pick by hand. It can be frozen into an ordinary
/// playlist from the menu.
class ArtistPage extends StatelessWidget {
  final String name;

  const ArtistPage({super.key, required this.name});

  static Future<void> open(BuildContext context, String name) {
    FocusManager.instance.primaryFocus?.unfocus();
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ArtistPage(name: name),
    ));
  }

  static bool _savingPlaylist = false;

  Future<void> _saveAsPlaylist(BuildContext context, ArtistGroup group) async {
    // A second tap while the first is being saved made a second playlist.
    if (_savingPlaylist) return;
    _savingPlaylist = true;
    final messenger = ScaffoldMessenger.of(context);
    final Playlist playlist;
    try {
      playlist = await DatabaseService.createPlaylist(group.name);
      await DatabaseService.addTracksToPlaylist(playlist.id, group.tracks);
    } finally {
      _savingPlaylist = false;
    }
    showAppSnackBar(messenger, message: '已存为歌单「${playlist.name}」');
    if (context.mounted) unawaited(PlaylistPage.open(context, playlist.id));
  }

  void _showMenu(BuildContext context, ArtistGroup group) {
    showAppSheet<void>(
      context,
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 4),
          SheetAction(
            icon: Icons.playlist_add_rounded,
            label: '存为歌单',
            onTap: () {
              Navigator.pop(sheet);
              _saveAsPlaylist(context, group);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = AppServices.instance.library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final group = library.artistNamed(name) ?? ArtistGroup(name, const []);
        final tracks = group.tracks;

        return Scaffold(
          backgroundColor: AppColors.background,
          body: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      backgroundColor: AppColors.background,
                      surfaceTintColor: Colors.transparent,
                      actions: [
                        // Behind 更多, where the playlist page keeps its menu:
                        // as a bare button in that spot it made a playlist
                        // from a tap meant for the menu.
                        if (tracks.isNotEmpty)
                          IconButton(
                            tooltip: '更多',
                            onPressed: () => _showMenu(context, group),
                            icon: const Icon(Icons.more_horiz_rounded,
                                color: AppColors.textSecondary),
                          ),
                        const SizedBox(width: 4),
                      ],
                    ),
                    SliverToBoxAdapter(
                      child: CollectionHeader(
                        title: group.name,
                        coverUrl: group.coverUrl,
                        placeholder: Icons.person_rounded,
                        round: true,
                        playable: tracks,
                        count: tracks.length,
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 8, 24),
                      sliver: SliverFixedExtentList.builder(
                        itemExtent: SongTile.extent,
                        itemCount: tracks.length,
                        itemBuilder: (context, index) {
                          final track = tracks[index];
                          return SongTile(
                            track: track,
                            queue: tracks,
                            onTap: () =>
                                openTrack(context, track, queue: tracks),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const DockedPlayer(),
            ],
          ),
        );
      },
    );
  }
}
