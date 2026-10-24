import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';
import 'lyrics_engine.dart';
import 'track_credit.dart';

/// What the listener seems to like, derived entirely from local data:
/// favourites, play history, the downloaded library and search history.
/// Nothing is uploaded and nothing is persisted separately — the profile is
/// rebuilt from those each time, so clearing any of them changes what comes
/// back at once.
@immutable
class TasteProfile {
  /// The songs to find more like, strongest first, each with its weight.
  final List<({Track track, double weight})> seeds;

  /// Artist (lower case, as [TrackCredit.artistOf] gives it) -> weight.
  final Map<String, double> artists;

  /// Videos the listener already has (bvids): never recommended back.
  final Set<String> knownVideos;

  /// Songs the listener already has ([songKey]): another upload of one of
  /// them is not a discovery.
  final Set<String> knownSongs;

  /// What they searched for, newest first.
  final List<String> searches;

  const TasteProfile({
    required this.seeds,
    required this.artists,
    required this.knownVideos,
    required this.knownSongs,
    required this.searches,
  });

  bool get isEmpty => seeds.isEmpty && searches.isEmpty;

  /// A favourite is an explicit "I like this". A play counts most when it
  /// is recent — taste drifts — and a download is a weaker, older choice.
  static const double favouriteWeight = 3.0;
  static const double recentPlayWeight = 2.0;
  static const double downloadWeight = 0.5;

  static const int _historyDepth = 30;
  static const int _libraryDepth = 100;

  static TasteProfile build({
    required List<Track> favourites,
    required List<Track> history,
    List<Track> downloaded = const [],
    required List<String> searches,
  }) {
    final weights = <String, double>{};
    final byId = <String, Track>{};
    final artists = <String, double>{};
    final videos = <String>{};
    final songs = <String>{};

    void absorb(Track t, double weight) {
      byId.putIfAbsent(t.id, () => t);
      weights[t.id] = (weights[t.id] ?? 0) + weight;
      final artist = TrackCredit.artistOf(t).toLowerCase();
      if (artist.isNotEmpty) artists[artist] = (artists[artist] ?? 0) + weight;
    }

    for (final t in favourites) {
      absorb(t, favouriteWeight);
    }
    final recent = history.take(_historyDepth).toList();
    for (var i = 0; i < recent.length; i++) {
      // From full weight for the latest play down to a quarter of it.
      absorb(recent[i], recentPlayWeight * (1 - 0.75 * i / _historyDepth));
    }
    for (final t in downloaded.take(_libraryDepth)) {
      absorb(t, downloadWeight);
    }
    for (final t in [...favourites, ...history, ...downloaded]) {
      videos.add(t.bvid);
      final key = songKey(t);
      if (key.isNotEmpty) songs.add(key);
    }

    final seeds = [
      for (final e in weights.entries) (track: byId[e.key]!, weight: e.value),
    ]..sort((a, b) => b.weight.compareTo(a.weight));

    return TasteProfile(
      seeds: seeds,
      artists: artists,
      knownVideos: videos,
      knownSongs: songs,
      searches: searches,
    );
  }

  static const TasteProfile empty = TasteProfile(
    seeds: [],
    artists: {},
    knownVideos: {},
    knownSongs: {},
    searches: [],
  );

  /// Which song a track is, in a form two uploads of it share: the song's
  /// name once named, else the title as the parser reads it, without case,
  /// spaces or punctuation.
  static String songKey(Track t) {
    final title = t.isNamed
        ? t.title
        : _songTitles[t.rawTitle] ??= _parse(t.rawTitle);
    return title.toLowerCase().replaceAll(_notWord, '');
  }

  static final Map<String, String> _songTitles = {};
  static final RegExp _notWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  static String _parse(String raw) {
    if (_songTitles.length > 4096) _songTitles.clear();
    final song = LyricsEngine.cleanTitle(raw)['songTitle'];
    return song == null || song.trim().isEmpty ? raw : song;
  }

  /// The songs to expand on [page]: [perPage] of them, taking the next ones
  /// down the list on every page so 换一批 brings other neighbours. Empty
  /// once every seed has had its turn.
  List<Track> seedsFor(int page, {int perPage = 4}) {
    final start = (page - 1) * perPage;
    if (start >= seeds.length) return const [];
    return [
      for (final s in seeds.skip(start).take(perPage)) s.track,
    ];
  }

  /// The artist to search for on [page], strongest first, or null when
  /// there are none left.
  String? artistFor(int page) {
    final ranked = artists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return page - 1 < ranked.length ? ranked[page - 1].key : null;
  }

  double weightOf(Track seed) {
    for (final s in seeds) {
      if (s.track.id == seed.id) return s.weight;
    }
    return 0;
  }
}

/// Builds 为你推荐: songs that people who watch the listener's songs go on
/// to watch on Bilibili (its 相关推荐), plus more by the artists they come
/// back to — weighed, cleaned of uploads that are not a song to listen to,
/// and spread across artists.
class RecommendationEngine {
  RecommendationEngine._();

  /// Recommendations are for picking something to listen to, so long-form
  /// uploads — concerts, compilations, radio rips — and clips are excluded.
  /// Explicit searches are never filtered this way.
  static const int maxDurationSeconds = 6 * 60;
  static const int minDurationSeconds = 60;

  static bool isSongLength(Track t) =>
      t.duration >= minDurationSeconds && t.duration <= maxDurationSeconds;

  /// Titles of uploads that are about music, or music cut for something
  /// else, rather than a song: lessons, reactions, rankings, medleys,
  /// loops, ringtones, DJ remixes for short videos.
  static final RegExp _notASong = RegExp(
    r'教学|教程|reaction|盘点|合集|合辑|串烧|歌单|连播|\d+\s*小时|循环播放|'
    r'鉴赏|解析|测评|切片|直播回放|抖音|快手|DJ版|铃声|伴奏|片段|试听|'
    r'唱法|声乐|曲谱|简谱|乐谱|top\s*\d+',
    caseSensitive: false,
  );

  static bool looksLikeASong(Track t) => !_notASong.hasMatch(t.rawTitle);

  /// No more than this many songs by one artist in a batch.
  static const int perArtist = 2;

  /// Ranks what the seeds brought back. [related] holds, per seed song,
  /// what Bilibili lists beside it, in its order; [byArtist] what a search
  /// for one of the listener's artists found. A song listed beside several
  /// of theirs, near the top, beside a song they care about more, ranks
  /// higher; so does one by an artist they play, and, a little, one that
  /// many people play.
  @visibleForTesting
  static List<Track> rank(
    TasteProfile profile, {
    required Map<Track, List<({Track track, int views})>> related,
    List<Track> byArtist = const [],
    Set<String> excludeIds = const {},
    int limit = 20,
  }) {
    final scores = <String, double>{};
    final tracks = <String, Track>{};
    final views = <String, int>{};

    bool admissible(Track t) =>
        isSongLength(t) &&
        looksLikeASong(t) &&
        !profile.knownVideos.contains(t.bvid) &&
        !excludeIds.contains(t.id) &&
        !profile.knownSongs.contains(TasteProfile.songKey(t));

    related.forEach((seed, list) {
      final weight = math.max(profile.weightOf(seed), 0.5);
      for (var i = 0; i < list.length; i++) {
        final t = list[i].track;
        if (!admissible(t)) continue;
        tracks.putIfAbsent(t.id, () => t);
        views[t.id] = math.max(views[t.id] ?? 0, list[i].views);
        // Bilibili's own order matters: the first neighbours are the
        // closest.
        scores[t.id] = (scores[t.id] ?? 0) + weight / (1 + i / 8);
      }
    });
    for (var i = 0; i < byArtist.length; i++) {
      final t = byArtist[i];
      if (!admissible(t)) continue;
      tracks.putIfAbsent(t.id, () => t);
      scores[t.id] = (scores[t.id] ?? 0) + 0.8 / (1 + i / 8);
    }

    final topArtist = profile.artists.values.fold<double>(0, math.max);
    final ranked = [
      for (final e in scores.entries)
        (
          track: tracks[e.key]!,
          score: e.value +
              // An artist they come back to: up to one strong neighbour.
              (topArtist > 0
                  ? (profile.artists[TrackCredit.artistOf(tracks[e.key]!)
                              .toLowerCase()] ??
                          0) /
                      topArtist
                  : 0) +
              // Popularity breaks ties; it never outweighs taste.
              0.1 * math.log((views[e.key] ?? 0) + 1) / math.ln10,
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));

    // One upload per song, and a few songs per artist.
    final songs = <String>{};
    final perArtistCount = <String, int>{};
    final out = <Track>[];
    for (final r in ranked) {
      if (out.length >= limit) break;
      final song = TasteProfile.songKey(r.track);
      if (song.isNotEmpty && !songs.add(song)) continue;
      final artist = TrackCredit.artistOf(r.track).toLowerCase();
      final n = perArtistCount[artist] ?? 0;
      if (n >= perArtist) continue;
      perArtistCount[artist] = n + 1;
      out.add(r.track);
    }
    return out;
  }

  /// Returns songs for the listener, best first. Empty when there is
  /// nothing to learn from, or when every page has been shown. [page]
  /// drives 换一批 and infinite scroll: each page expands other seed songs
  /// and another artist. [excludeIds] drops what the caller already shows.
  static Future<List<Track>> recommend({
    int limit = 20,
    int page = 1,
    Set<String> excludeIds = const {},
  }) async {
    final profile = TasteProfile.build(
      favourites: (await DatabaseService.getFavoritesPlaylist()).tracks,
      history: await DatabaseService.getRecentlyPlayed(),
      downloaded: await DatabaseService.getDownloadedTracks(),
      searches: await DatabaseService.getSearchHistory(),
    );
    if (profile.isEmpty) return const [];

    final seeds = profile.seedsFor(page);
    final artist = profile.artistFor(page);
    // Nothing played or kept yet: what they searched for is all there is.
    final query = profile.seeds.isEmpty
        ? (page - 1 < profile.searches.length
            ? profile.searches[page - 1]
            : null)
        : artist;
    if (seeds.isEmpty && query == null) return const [];

    // Independent requests, run together; one failing never sinks the
    // batch, but all of them failing is a transport failure, not "nothing".
    Object? firstError;
    var asked = 0;
    var failed = 0;
    Future<T?> attempt<T>(Future<T> Function() request) async {
      asked++;
      try {
        return await request();
      } catch (e) {
        debugPrint('Recommendation request failed: $e');
        failed++;
        firstError ??= e;
        return null;
      }
    }

    final neighbours = await Future.wait([
      for (final seed in seeds) attempt(() => BilibiliSdk.related(seed.bvid)),
    ]);
    final found =
        query == null ? null : await attempt(() => BilibiliSdk.search(query));
    if (asked > 0 && failed == asked) {
      throw firstError ?? const BiliApiException('recommendations failed');
    }

    return rank(
      profile,
      related: {
        for (var i = 0; i < seeds.length; i++)
          seeds[i]: neighbours[i] ?? const [],
      },
      byArtist: found ?? const [],
      excludeIds: excludeIds,
      limit: limit,
    );
  }
}
