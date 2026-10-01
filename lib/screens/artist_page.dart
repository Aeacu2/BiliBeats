import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/playback_actions.dart';
import '../services/database_service.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/snack.dart';
import '../widgets/collection_header.dart';
import '../widgets/docked_player.dart';
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

  Future<void> _saveAsPlaylist(BuildContext context, ArtistGroup group) async {
    final messenger = ScaffoldMessenger.of(context);
    final playlist = await DatabaseService.createPlaylist(group.name);
    // Inserted front-first, so reverse to keep the page's order.
    await DatabaseService.addTracksToPlaylist(
        playlist.id, group.tracks.reversed.toList());
    showAppSnackBar(messenger, message: '已存为歌单「${playlist.name}」');
    if (context.mounted) unawaited(PlaylistPage.open(context, playlist.id));
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
                        if (tracks.isNotEmpty)
                          IconButton(
                            tooltip: '存为歌单',
                            onPressed: () => _saveAsPlaylist(context, group),
                            icon: const Icon(Icons.playlist_add_rounded,
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
