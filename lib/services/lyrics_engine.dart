import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/lyrics.dart';
import '../models/video_hints.dart';
import 'bili_http.dart';

/// What [LyricsEngine.identify] concluded about a video.
class SongIdentity {
  final String title;
  final String artist;

  /// The original release's artwork; only offered when [exact].
  final String? coverUrl;

  /// True when the video is this very artist's song (their name is in the
  /// title, or they uploaded it); false for a cover, where only the song's
  /// name is the database's.
  final bool exact;

  const SongIdentity({
    required this.title,
    required this.artist,
    required this.exact,
    this.coverUrl,
  });

  @override
  String toString() => 'SongIdentity($title, $artist, exact: $exact)';
}

class LyricsEngine {
  static final HttpClient _client = biliHttpClient();

  static const Duration _timeout = Duration(seconds: 10);

  static Future<String?> _httpGet(String urlStr,
      {Map<String, String>? headers}) async {
    try {
      final req = await _client.getUrl(Uri.parse(urlStr)).timeout(_timeout);
      headers?.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(_timeout);
      if (res.statusCode == 200) {
        return await res.transform(utf8.decoder).join().timeout(_timeout);
      }
      // Drain non-200 bodies so the connection returns to the pool; with
      // maxConnectionsPerHost = 4, a few un-drained 4xx/5xx responses would
      // exhaust it and later requests would queue behind idleTimeout.
      await res.drain<void>();
    } catch (e) {
      debugPrint('Lyrics HTTP error: $e');
    }
    return null;
  }

  // Common noise words in B站 titles
  static final RegExp noiseKeywords = RegExp(
    r'(?:4K|1080P|720P|60帧|50帧|杜比视界|杜比全景声|杜比音效|Hi-?Res|无损音质|无损|高音质|高音質|HQ|SQ|'
    r'官方MV|\bMV\b|纯享版|纯享|纯净版|动态歌词|LRC|歌词排版|流行歌曲|全场|完整版|片段|精剪|多机位|直拍|现场|\bLive\b|'
    r'首唱|单曲循环|单曲|纯音频|Audio|字幕组|字幕|重置|超清|高清|录音棚|在.*大声听|'
    r'主题曲|片尾曲|片头曲|插曲|推广曲|印象曲|角色曲|宣传曲|ED|OP|OST|'
    r'舞台|带来|第\s*\d+\s*[季期届集]|EP\d+)',
    caseSensitive: false,
  );

  // Noise words that can be *embedded* in a real name token ("周深翻唱",
  // "陈奕迅新歌", "毛不易演唱会"). Dropping such a token whole loses the
  // name; stripping these out of the token keeps it. Deliberately disjoint
  // from [noiseKeywords]'s format class: format words (无损, 音质, 4K…) leave
  // meaningless residue and must still kill the whole token. The ASCII glue
  // words are word-anchored so they cannot eat real words out of a token
  // (Alive, Discovery, Deliver must survive).
  static final RegExp glueNoise = RegExp(
    r'(?:翻唱|原唱|合唱|演唱|新歌|混音|修音|字幕|伴奏|现场|演唱会|纯享|单曲|直拍|修复|'
    r'完整版|官方版|官方|版本|首唱|歌词排版|歌词|舞台|合作|UP主|\bCover\b|\bMV\b|\bLive\b)',
    caseSensitive: false,
  );

  /// A token that is nothing but a separator ("-", "–", "—", "|"…). Such
  /// tokens must survive [_noisyClean]: step-4's "Artist - Song" split runs on
  /// the cleaned title and needs the dash, a 1-char token otherwise dropped.
  static final RegExp pureSeparatorToken = RegExp(r'^[-–—/︱|丨_]+$');

  // Follows a 《…》 pair to flag it as a show name rather than the song:
  // season markers ("第二季", "EP09") and show-suffix tags ("主题曲" etc.).
  static final RegExp showMarker = RegExp(
    r'第\s*\d+[季期届集]|EP\d+|\d+\s*季|'
    r'主题曲|片尾曲|片头曲|插曲|推广曲|印象曲|角色曲|宣传曲|ED|OP|OST',
    caseSensitive: false,
  );

  // Token-level noise: if a space-separated token contains any of these, the
  // whole token is noise (spaces are the atomic unit of titles).
  static final RegExp tokenNoise = RegExp(
    noiseKeywords.pattern + r'|(?:\bCover\b|翻唱|原唱|词/曲|混音|演唱|UP主|版本)',
    caseSensitive: false,
  );

  static final RegExp bracketCategory = RegExp(
    r'合集|歌单|珍藏|榜|反应|点评|解析|试听',
    caseSensitive: false,
  );

  // Shared structural regexes: cleaning and candidate generation must strip
  // exactly the same brackets, or the two paths disagree on the same title.
  static final RegExp htmlTag = RegExp(r'<[^>]+>');
  static final RegExp bracketContent = RegExp(r'[【\[]([^】\]]+)[】\]]');
  static final RegExp bookBracket = RegExp(r'[《「『]([^》」』]+)[》」』]');
  static final RegExp bracketStripper =
      RegExp(r'【[^】]+】|\[[^\]]+\]|（[^）]+）|\([^)]+\)|《[^》]+》|「[^」]+」|『[^』]+』');
  static final RegExp parenSubtitle = RegExp(r'\s*[\(（][^\)）]+[\)）]');
  static final RegExp separator = RegExp(r'^(.+?)\s*[-–—/︱|丨_]\s*(\S.*)$');
  static final RegExp featSeparator = RegExp(
      r'^(.+?)\s+(?:feat\.?|ft\.?|with|by)\s+(.+)$',
      caseSensitive: false);

  /// "在百万豪装录音棚大声听", "百万级录音棚试听", "用顶级音响听": where the
  /// uploader played the song, written without a space before the singer
  /// ("…大声听周深《大鱼》"). It has to come out *of* the token — dropping the
  /// token as noise takes the singer with it, and the UP主 gets the credit.
  static final RegExp listeningPhrase = RegExp(
    r'(?:[在用戴][^\s《》「」『』【】\[\]()（）|｜丨︱,，、]{0,8}?|'
    r'(?:价值|百万|千万|顶级|专业|豪华)[^\s《》「」『』【】\[\]()（）|｜丨︱,，、]{0,6}?)?'
    r'(?:录音棚|音响|音箱|耳机|装备|设备|声卡)'
    r'[^\s《》「」『』【】\[\]()（）|｜丨︱,，、]{0,5}?(?:试听|聆听|听)',
  );

  static Map<String, String> _knownArtists = const {};

  /// Artists already in the library. A title that names one of them and
  /// gives the parser no structure to go by ("周深 大鱼 无损", or a name run
  /// into the words around it) is credited to them rather than the UP主.
  static set knownArtists(Iterable<String> names) {
    _knownArtists = {
      for (final name in names)
        if (_isLearnableName(name.trim())) _normalize(name): name.trim(),
    };
  }

  static bool _isLearnableName(String name) {
    final n = _normalize(name);
    if (n.length > 16) return false;
    // Short Latin names are ordinary words too often (JJ, Eve, Air).
    return RegExp(r'[\u4e00-\u9fa5]').hasMatch(n)
        ? n.length >= 2
        : n.length >= 4;
  }

  /// The longest [knownArtists] name [title] contains, other than [song].
  static String? _knownArtistIn(String title, {String song = ''}) {
    if (_knownArtists.isEmpty) return null;
    final norm = _normalize(title);
    final songNorm = _normalize(song);
    String? best;
    for (final key in _knownArtists.keys) {
      if (key == songNorm || !norm.contains(key)) continue;
      if (best == null || key.length > best.length) best = key;
    }
    return best == null ? null : _knownArtists[best];
  }

  static String _preprocess(String raw) {
    return raw
        .trim()
        .replaceAll(htmlTag, '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        // "《大梦归（《兰香如故》主题曲）》": a note inside the song's own
        // brackets would end them early.
        .replaceAll(RegExp(r'[（(][^（）()]*《[^《》]*》[^（）()]*[）)]'), '')
        .replaceAll(listeningPhrase, ' ')
        // "周深的《大鱼》": the particle is not part of the name.
        .replaceAll(RegExp(r'的(?=[《「『])'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Drops brackets, parens and noise from [s], preserving the surviving
  /// space-separated tokens.
  ///
  /// Two classes of noise, handled differently:
  ///  * [glueNoise] words (翻唱, 新歌, Cover…) are stripped *out of* a token,
  ///    so "周深翻唱" keeps 周深 instead of vanishing — dropping the whole
  ///    token used to lose the name whenever a verb was glued to it.
  ///  * [tokenNoise] (format words like 无损, plus glue words in their own
  ///    right) kills the whole token, because their residue is meaningless.
  ///    Bar-like separators (|｜、,，/) also split tokens, so "Song｜完整版｜
  ///    歌词LyricsVideo" keeps the song part instead of dying with the noise.
  static String _noisyClean(String s) {
    final out = <String>[];
    for (final t in s.replaceAll(bracketStripper, ' ').split(RegExp(r'\s+'))) {
      if (t.isEmpty) continue;
      // A whole-token separator ("/", "|", "｜") must survive for step-4's
      // "Artist - Song" split — the bar-split below would otherwise destroy
      // it (and the pureSeparatorToken check would only see its empty husks).
      if (pureSeparatorToken.hasMatch(t)) {
        out.add(t);
        continue;
      }
      for (final seg in t.split(RegExp(r'[|｜、,，/]'))) {
        if (pureSeparatorToken.hasMatch(seg)) {
          out.add(seg);
          continue;
        }
        for (final sub
            in seg.replaceAll(glueNoise, ' ').split(RegExp(r'\s+'))) {
          if (sub.isEmpty) continue;
          // Keep single-char CJK song names like 《爱》; ASCII single letters are noise
          if (sub.length < 2) {
            final isSingleCjk = RegExp(r'^[\u4e00-\u9fa5]$').hasMatch(sub);
            if (!isSingleCjk) continue;
            // A lone character left over after glue words were cut out of a
            // longer token ("重混音修音版本" → 重) is debris, not a name.
            if (seg.length > 1) continue;
          }
          if (tokenNoise.hasMatch(sub)) continue;
          // tokenNoise residue like "品" after stripping "无损" is meaningless
          if (sub.length == 1 &&
              RegExp(r'^[\u4e00-\u9fa5]$').hasMatch(sub) &&
              tokenNoise.hasMatch(sub)) {
            continue;
          }
          out.add(sub);
        }
      }
    }
    return out.join(' ');
  }

  /// The text that describes a 《…》 pair: what follows it, up to the next
  /// pair. A marker there (第二季, 主题曲…) is about *this* pair — scanning
  /// the whole rest of the title would let 《衣裳中国》主题曲 also condemn the
  /// 《画绢》 that precedes it.
  static String _afterPair(String title, Match pair) {
    final next = title.indexOf(RegExp('[《「『]'), pair.end);
    return title.substring(pair.end, next < 0 ? title.length : next);
  }

  // Title cleaner to extract clean song name & artist from Bilibili video titles
  //
  // Deliberately structural: brackets supply the artist, 《》 supplies the
  // song, separators split "Artist - Song", and space-separated tokens are the
  // unit of noise removal. All semantic disambiguation (which 《》 is the song,
  // who the singer is, collaboration brackets like 【A&B 歌名】) is delegated to
  // [cleanTitleWithValidation]'s lyric-DB search; this method is only the
  // offline fallback and the instant first pass.
  static Map<String, String> cleanTitle(String rawTitle,
      {String defaultArtist = ''}) {
    final title = _preprocess(rawTitle);
    var artist = defaultArtist.trim();
    if (artist == '未知UP主' || artist == '未知歌手' || artist == 'UP主') {
      artist = '';
    }

    String? song;

    // 2. Artist from brackets like 【周深】, [周深], or space-split
    //    【Artist1&Artist2 SongTitle】 patterns.
    final bracketMatch = bracketContent.firstMatch(title);
    if (bracketMatch != null) {
      final content = bracketMatch.group(1)!.trim();
      if (!bracketCategory.hasMatch(content)) {
        // Vertical bars are category separators (【周深｜舞台】), not part of
        // the name — unlike &, which joins real collab artists.
        final tokens = content
            .split(RegExp(r'[\s|｜]+'))
            .where((t) => t.isNotEmpty)
            .toList();
        final nonNoise = tokens.where((t) => !tokenNoise.hasMatch(t)).toList();
        // A bracket whose every token is noise (【现场】, 【Live】) carries no
        // info; one mixing a name and a category keeps the name.
        if (tokens.isNotEmpty && nonNoise.isNotEmpty) {
          if (nonNoise.length >= 2) {
            artist = nonNoise.sublist(0, nonNoise.length - 1).join(' ');
            song = nonNoise.last;
          } else {
            artist = nonNoise.join(' ');
          }
        }
      }
    }

    // 2b. "Artist【Song】": a bracket that *follows* a lone name is the song,
    //     not the artist ("G.E.M.邓紫棋【光年之外】MV").
    if (bracketMatch != null && bracketMatch.start > 0) {
      final before = _noisyClean(title.substring(0, bracketMatch.start));
      final inside = bracketMatch.group(1)!.trim();
      if (before.isNotEmpty &&
          !before.contains(' ') &&
          before.length <= 14 &&
          !inside.contains(RegExp(r'\s')) &&
          !tokenNoise.hasMatch(inside) &&
          !bracketCategory.hasMatch(inside) &&
          bracketContent.allMatches(title).length == 1) {
        artist = before;
        song = inside;
      }
    }

    // 3. Song from the 《...》 brackets. Titles often carry a show name next
    //    to the real song, so a pair followed by a season marker or show-suffix
    //    tag ("《音乐缘计划》第二季EP09…", "《衣裳中国》主题曲") is the *show*;
    //    the song is a surviving unmarked pair. With no markers at all the LAST
    //    pair wins (《show》…《song》), and a single pair is the song outright.
    final pairs = bookBracket.allMatches(title).toList();
    if (pairs.isNotEmpty) {
      Match? songPair;
      final unmarked = pairs.where((m) {
        return !showMarker.hasMatch(_afterPair(title, m));
      }).toList();
      songPair = unmarked.isNotEmpty ? unmarked.last : pairs.last;
      song = songPair.group(1)!.trim();
      // A plain-text artist sitting between the last leading 【】/[] bracket
      // and the song bracket beats the bracket content — but only under the
      // two shapes where that is reliably true, because on B站 the bracket is
      // USUALLY the artist ("【周深】《画绢》") and the text between bracket
      // and song is usually junk (dates, 合集 tags, verb phrases):
      //   1. the between text is a collab list ("【声生不息3】 黄绮珊&周深
      //      《岁月》" — &/、 only ever join artists);
      //   2. the bracket is a show-season tag (CJK name ending in a 1–2 digit
      //      season: 声生不息3, 我们的歌5 — not SNH48-style ASCII ids) and the
      //      between text is a single bare name.
      final leadingBrackets = bracketContent
          .allMatches(title.substring(0, songPair.start))
          .toList();
      if (leadingBrackets.isNotEmpty) {
        final between = _noisyClean(
            title.substring(leadingBrackets.last.end, songPair.start));
        final betweenTokens =
            between.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
        if (betweenTokens.isNotEmpty) {
          final bracketText = leadingBrackets.last.group(1)!.trim();
          final collabToken = betweenTokens
              .where((t) => RegExp(r'[&、,，]').hasMatch(t))
              .toList();
          if (collabToken.isNotEmpty) {
            artist = collabToken.first;
          } else if (betweenTokens.length >= 2 &&
              betweenTokens.every(
                  (t) => _looksLikeBareName(t) && !_betweenJunk.contains(t))) {
            // "【声生不息】陈楚生 周深 合作舞台《逆光》": several bare names
            // between a tag bracket and the song bracket are collaborating
            // artists — space-separated collabs carry no & marker. Noise
            // tokens (舞台, 主题曲…) are already filtered by _noisyClean, and
            // the every() gate keeps dates/cities/junk out (verified against
            // the 540-title corpus with zero unintended changes). Exact
            // matches only: substring noise filtering would eat tokens glued
            // to a real name ("陈奕迅新歌" must not drop 陈奕迅).
            artist = betweenTokens.join(' ');
          } else if (_looksLikeShowSeason(bracketText) &&
              betweenTokens.length == 1 &&
              _looksLikeBareName(betweenTokens.first)) {
            artist = betweenTokens.first;
          }
        }
      }
      if (artist.isEmpty || artist == defaultArtist) {
        final beforeTokens = _noisyClean(title.substring(0, songPair.start))
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList();
        // The token nearest the 《》 is most likely the artist's name; when
        // several precede it ("周深 古风《大鱼》") the leading one wins.
        if (beforeTokens.isNotEmpty) {
          artist = beforeTokens.first;
        }
      }
      if (artist.isEmpty || artist == defaultArtist) {
        // "《告白气球》周杰伦丨Hi-Res丨": the name ends at the first bar.
        final after = title
            .substring(songPair.end)
            .split(RegExp(r'[|｜丨︱]'))
            .map((p) => _noisyClean(p).replaceFirst(RegExp(r'^[-–—/_\s]+'), ''))
            .firstWhere((p) => p.isNotEmpty, orElse: () => '');
        final leading =
            RegExp(r'^([\u4e00-\u9fa5A-Za-z0-9_·•.]{2,12})').firstMatch(after);
        if (leading != null && !tokenNoise.hasMatch(leading.group(1)!)) {
          artist = leading.group(1)!;
        }
      }
    }

    // 4. No book brackets: split "Artist - SongTitle" on the cleaned title.
    if (song == null) {
      final clean = _noisyClean(title);
      final parts = clean.split(RegExp(r'\s+[-–—/︱|丨_]\s+'));
      if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
        if (artist.isEmpty || artist == defaultArtist) artist = parts[0];
        song = parts[1];
      } else {
        final dash =
            RegExp(r'^([\u4e00-\u9fa5A-Za-z0-9·•.]{2,10})\s*[-–—]\s*(.+)$')
                .firstMatch(clean);
        if (dash != null) {
          if (artist.isEmpty || artist == defaultArtist) {
            artist = dash.group(1)!;
          }
          song = dash.group(2)!;
        }
      }
      song ??= clean;
    }

    // 5. Nothing structural named an artist: one the library already
    //    knows, anywhere in the title, is better than the UP主.
    if (artist.isEmpty || artist == defaultArtist.trim()) {
      final known = _knownArtistIn(title, song: song);
      final covered = known != null &&
          RegExp(
            '(?:翻唱|翻自|原唱|cover)(?:自)?[\\s:：]*${RegExp.escape(known)}',
            caseSensitive: false,
          ).hasMatch(title);
      if (known != null && !covered) {
        artist = known;
        final rest = song
            .split(' ')
            .where((t) => _normalize(t) != _normalize(known))
            .join(' ')
            .trim();
        if (rest.isNotEmpty) song = rest;
      }
    }

    final finalSong = song.trim();
    return {
      'songTitle': finalSong.isEmpty ? rawTitle : finalSong,
      'artist': artist.isNotEmpty ? artist : defaultArtist,
    };
  }

  /// Structural candidate extraction for DB-backed validation: every 《…》
  /// content, every 【…】 content (whole and space-split), the part after an
  /// "Artist - Song" separator, and every surviving space-separated token.
  static List<Map<String, String>> _generateCandidates(String rawTitle) {
    final title = _preprocess(rawTitle);
    final candidates = <Map<String, String>>[];

    void add(String song,
        [String artistHint = '', int bookIdx = -1, bool showLike = false]) {
      // "光亮MV": the word glued on is not part of the name.
      final s = song.replaceAll(glueNoise, ' ').trim().replaceAll(
            RegExp(r'\s+'),
            ' ',
          );
      // The other side of "A - B" may carry a bracket or noise of its own.
      final hint = _noisyClean(artistHint).trim();
      final norm = _normalize(s);
      if (s.isEmpty || norm.isEmpty || norm.length > 30) return;
      if (tokenNoise.hasMatch(s)) return;
      if (candidates.any((c) => _normalize(c['song']!) == norm)) return;
      candidates.add({
        'song': s,
        'artistHint': hint,
        if (bookIdx >= 0) 'bookIdx': '$bookIdx',
        if (showLike) 'showLike': '1',
      });
    }

    var bookIdx = 0;
    for (final m in bookBracket.allMatches(title)) {
      add(m.group(1)!, '', bookIdx++,
          showMarker.hasMatch(_afterPair(title, m)));
    }
    for (final m in bracketContent.allMatches(title)) {
      final content = m.group(1)!.trim();
      if (content.isEmpty) continue;
      add(content);
      final tokens =
          content.split(RegExp(r'[\s|｜]+')).where((t) => t.isNotEmpty).toList();
      if (tokens.length >= 2) {
        add(tokens.last, tokens.sublist(0, tokens.length - 1).join(' '));
      }
    }
    final sep = separator.firstMatch(title) ?? featSeparator.firstMatch(title);
    if (sep != null) {
      // Drop show/channel metadata after the first bar: "…经典 | 音乐缘计划
      // | Melody Journey | iQIYI奇艺音悦台" — only the pre-bar part is a song.
      final songPart = sep.group(2)!.split(RegExp(r'[|｜丨]')).first.trim();
      if (songPart.isNotEmpty) add(songPart, sep.group(1)!);
      // B站 cover titles are often "Song - Artist" ("遥遥-周深", "不舍-周深")
      // instead of "Artist - Song", and the rule pass cannot know which. When
      // both sides are short bare names, also emit the reversed pairing and
      // let the DB-backed validation disambiguate.
      final g1 = _noisyClean(sep.group(1)!).trim();
      final g2 = _noisyClean(songPart).trim();
      if (_looksLikeBareName(g1) &&
          _looksLikeBareName(g2) &&
          _normalize(g1) != _normalize(g2)) {
        add(g1, g2);
      }
    }
    final bare = title.replaceAll(bracketStripper, ' ');
    // Bare tokens after the first bar separator are show names / uploader
    // channels, never song parts (" | 音乐缘计划 | Melody Journey | iQIYI…").
    final bareHead = bare.split(RegExp(r'[|｜丨]')).first;
    final words = bareHead.split(RegExp(r'\s+'));
    // Consecutive Latin words are one name before they are several
    // ("Bloody Stream", not "Stream").
    final latin = RegExp(r"^[A-Za-z][A-Za-z']*$");
    for (var i = 0; i < words.length; i++) {
      var j = i;
      while (j < words.length && latin.hasMatch(words[j])) {
        j++;
      }
      if (j - i >= 2) add(words.sublist(i, j).join(' '));
      if (j > i) i = j - 1;
    }
    for (final t in words) {
      add(t);
    }
    return candidates.length > 8 ? candidates.sublist(0, 8) : candidates;
  }

  // ---------------------------------------------------------------------------
  // Identification: which song is this video?
  // ---------------------------------------------------------------------------

  static final Map<String, SongIdentity?> _identityMemo = {};

  static final RegExp _liveMarker = RegExp(
    r'现场|\blive\b|演唱会|舞台|直播|音乐节|歌手20\d\d|巡演',
    caseSensitive: false,
  );

  /// Says the video is somebody's rendition (or a lesson, or an instrumental)
  /// rather than the release itself. Its tags then name the *original*
  /// singer, and prove nothing about who is heard.
  static final RegExp _coverMarker = RegExp(
    r'翻唱|翻弹|翻奏|翻自|弹唱|扒谱|教学|教程|伴奏|纯音乐|钢琴|吉他|尤克里里|古筝|'
    r'小提琴|演奏|指弹|合唱|改编|填词|二创|戏腔|\bcover\b|\bremix\b|\bdj\b|\bAI\b',
    caseSensitive: false,
  );

  /// The stronger claim: somebody is performing another artist's song. Who
  /// that somebody is — the UP主, or a singer whose performance the UP主
  /// clipped (周深 covering a song on a birthday stream) — is a separate
  /// question; see the singer search in [identify].
  static final RegExp _renditionMarker = RegExp(
    r'翻唱|翻弹|翻奏|翻自|弹唱|扒谱|教学|教程|演奏|\bcover\b',
    caseSensitive: false,
  );

  /// Tags that describe the upload, not the music.
  static final RegExp _tagNoise = RegExp(
    r'^(?:音乐|歌曲|经典|经典歌曲|流行|流行音乐|华语|华语MV|电台|音响|听歌|歌单|单曲|'
    r'高音质|无损音质|高清无损|现场|音乐现场|演唱会|翻唱|古风|国风|治愈|天籁|好听|'
    r'必听|宝藏|推荐|分享|动感视频|BGM|MV|LIVE|4K|HIFI|Hi-?Fi|Hi-?res|.*打卡.*|.*挑战.*|'
    r'.*大赛.*|.*征集.*|.*音乐季.*|.*分享官.*)$',
    caseSensitive: false,
  );

  /// Who the description says is singing ("演唱：周深", "由周深演唱").
  static final RegExp _describedSinger = RegExp(
    r'(?:演唱|歌手|主唱|vocal|singer|artist)\s*[:：]\s*([^\s,，。;；/|｜]{2,20})|'
    r'由\s*([^\s,，。;；/|｜由]{2,12}?)\s*演唱',
    caseSensitive: false,
  );

  /// NetEase songs for [query], or null when the request itself failed —
  /// which is not the same answer as "nothing found", and must not be taken
  /// for it. A stalled connection is given one more try.
  static Future<List<Map>?> _netEaseSearch(String query,
      {int limit = 10}) async {
    final url = 'https://music.163.com/api/search/get'
        '?s=${Uri.encodeComponent(query)}&type=1&limit=$limit';
    const headers = {'Referer': 'https://music.163.com'};
    final body = await _httpGet(url, headers: headers) ??
        await _httpGet(url, headers: headers);
    if (body == null) return null;
    try {
      final songs = jsonDecode(body)['result']?['songs'] as List? ?? const [];
      return songs.whereType<Map>().toList();
    } catch (_) {
      return null;
    }
  }

  /// "不舍 (Cover 徐佳莹)", "大鱼-原唱:周深": a recording named after the one
  /// it covers.
  static final RegExp _coverOf = RegExp(
    r'(?:cover|原唱|翻自)\s*[:：]?\s*([^()（）\[\]【】《》]+)',
    caseSensitive: false,
  );

  /// Whose song [songName] is, as far as NetEase says: its catalogue marks
  /// recordings as originals or covers, and names who a cover is of. Null
  /// when it could not be asked. [best] is the recording already chosen.
  static Future<Set<String>?> _originalArtists(
      String songName, Map best) async {
    final body = await _httpGet(
      'https://music.163.com/api/cloudsearch/pc'
      '?s=${Uri.encodeComponent(songName)}&type=1&limit=20',
      headers: {'Referer': 'https://music.163.com'},
    );
    if (body == null) return null;
    final List songs;
    try {
      final json = jsonDecode(body);
      if (json['code'] != 200) return null;
      songs = json['result']?['songs'] as List? ?? const [];
    } catch (_) {
      return null;
    }
    final nameNorm = _normalize(songName);
    List<String> performers(Map s) => [
          for (final a in s['ar'] as List? ?? const [])
            if (a is Map && a['name'] is String) a['name'] as String,
        ];
    final named = <String>{};
    final firstRecordings = <String>{};
    for (final s in songs.whereType<Map>()) {
      final raw = '${s['name'] ?? ''}';
      if (!_normalize(raw).startsWith(nameNorm)) continue;
      final of = s['originSongSimpleData'];
      if (of is Map) {
        for (final a in of['artists'] as List? ?? const []) {
          if (a is Map && a['name'] is String) named.add(a['name'] as String);
        }
      }
      for (final m in _coverOf.allMatches(raw)) {
        named.addAll(m.group(1)!.split(RegExp(r'[/／、&,，]')));
      }
      final isOriginal = s['originCoverType'] == 1;
      if (isOriginal && s['id'] == best['id']) {
        named.addAll(performers(s));
      }
      if (isOriginal &&
          _normalize(raw.replaceAll(parenSubtitle, '')) == nameNorm &&
          firstRecordings.isEmpty) {
        firstRecordings.addAll(performers(s));
      }
    }
    // Nobody is named as covered: the first recording marked original is
    // the best guess, and failing that the one already chosen.
    final found = named.isNotEmpty
        ? named
        : firstRecordings.isNotEmpty
            ? firstRecordings
            : _artistsOf(best).toSet();
    return {
      for (final a in found)
        if (_normalize(a).isNotEmpty) _normalize(a),
    };
  }

  static List<String> _artistsOf(Map song) => [
        for (final a in song['artists'] as List? ?? const [])
          if (a is Map &&
              a['name'] is String &&
              (a['name'] as String).isNotEmpty)
            a['name'] as String,
      ];

  /// Identifies the song behind a Bilibili video title against NetEase.
  ///
  /// The title is parsed structurally into candidate (song, artist) readings
  /// ([_generateCandidates]); each is searched once, in parallel, and every
  /// song that comes back is scored on evidence the *video* provides:
  ///
  ///  * its name appears in the title (required — nothing else can vouch for
  ///    a song the title never mentions);
  ///  * its artist appears in the title, or is the uploader;
  ///  * its length matches the video's ([durationSeconds]) — the signal that
  ///    separates a studio cut from a live one and an original from a cover;
  ///  * it is, or is not, a live version, like the title says.
  ///
  /// A name on its own is not enough: unless the artist or the length agrees,
  /// the title must set the name apart (《》, "A - B", or little else in it),
  /// so a vlog that happens to contain 回忆 is not renamed after the song.
  /// Compilations (【合集】, or anything longer than [_longestSong]) are never
  /// one song.
  ///
  /// The best-scoring song with enough evidence is the answer. When the song
  /// is certain but its artist is not in the title, the video is a cover:
  /// the name comes from the database, the singer from the title.
  ///
  /// [context] is the video's title when [rawTitle] is the name of one of
  /// its parts (an album uploaded as P1, P2, …): artists named there count.
  ///
  /// [hints] is what Bilibili knows beyond the title. Its tags usually name
  /// the singer and the song outright, so they are searched as candidates
  /// and — unless the video is a cover ([_coverMarker]) — count as credits
  /// just as the title does. With a singer known, their catalogue is also
  /// searched for a song the title names without setting it apart.
  ///
  /// Returns null when nothing is confirmed (or the network is down); see
  /// [identitySettled] to tell the two apart.
  static Future<SongIdentity?> identify(
    String rawTitle, {
    String uploader = '',
    int durationSeconds = 0,
    String context = '',
    VideoHints hints = VideoHints.none,
  }) async {
    final memoKey =
        _memoKey(rawTitle, uploader, durationSeconds, context, hints);
    if (_identityMemo.containsKey(memoKey)) return _identityMemo[memoKey];

    // A compilation is many songs, not one: 【合集】, 歌单, or simply too long
    // to be a single track. (One part of a multi-part video is judged on its
    // own name and length, with the video's title as [context].)
    // (珍藏 on something song-length is a word for the quality — 【4K珍藏】
    // — not for a collection.)
    final songLength = durationSeconds > 0 && durationSeconds <= 8 * 60;
    final category = bracketContent.allMatches(_preprocess(rawTitle)).any((m) =>
        bracketCategory.hasMatch(
            songLength ? m.group(1)!.replaceAll('珍藏', '') : m.group(1)!));
    if (category ||
        _severalSongs.hasMatch(rawTitle) ||
        durationSeconds > _longestSong) {
      _remember(memoKey, null);
      return null;
    }

    final parsed = cleanTitle(rawTitle, defaultArtist: uploader);
    final parsedArtist = (parsed['artist'] ?? '').trim();
    // An artist the title itself names (as opposed to the uploader default);
    // for a part of a multi-part video, one the video's title names.
    var titleArtist = parsedArtist != uploader.trim() ? parsedArtist : '';
    if (titleArtist.isEmpty && context.isNotEmpty) {
      final named = (cleanTitle(context)['artist'] ?? '').trim();
      if (_looksLikeBareName(named)) titleArtist = named;
    }
    final normRaw = _normalize(_preprocess(rawTitle));
    // Where an artist may be named: the title itself, or — for one part of
    // a multi-part video — the title of the video it belongs to.
    var normCredits = normRaw + _normalize(_preprocess(context));
    final normUploader = _normalize(uploader);
    final rawIsLive = _liveMarker.hasMatch(rawTitle);

    // What the video's tags and description add. On a cover they name the
    // original singer, so there they only help find the song.
    final tags = [
      for (final t in hints.tags)
        if (_normalize(t).length >= 2 &&
            !_tagNoise.hasMatch(t) &&
            !tokenNoise.hasMatch(t) &&
            !bracketCategory.hasMatch(t))
          t,
    ];
    final tagNorms = {for (final t in tags) _normalize(t)};
    final isCover = _coverMarker.hasMatch(rawTitle) ||
        _coverMarker.hasMatch(context) ||
        _coverMarker.hasMatch(hints.zone) ||
        hints.tags.any(_coverMarker.hasMatch) ||
        RegExp(r'原唱\s*[:：]|翻唱|cover', caseSensitive: false)
            .hasMatch(hints.description);
    final isRendition = _renditionMarker.hasMatch(rawTitle) ||
        _renditionMarker.hasMatch(context) ||
        _renditionMarker.hasMatch(hints.zone) ||
        hints.tags.any(_renditionMarker.hasMatch) ||
        RegExp(r'原唱\s*[:：]|翻唱|cover', caseSensitive: false)
            .hasMatch(hints.description);
    // Nor do they when the title names a singer of its own: 【单依纯】大鱼,
    // tagged 周深, is 单依纯 singing.
    final titleNamesSinger = titleArtist.isNotEmpty &&
        (RegExp(r'[&、]').hasMatch(titleArtist) ||
            (_looksLikeBareName(titleArtist) &&
                await _netEaseArtistExists(titleArtist)));
    if (!isCover && !titleNamesSinger) {
      normCredits += '\x00${tagNorms.join('\x00')}';
      for (final m in _describedSinger.allMatches(hints.description)) {
        normCredits += '\x00${_normalize(m.group(1) ?? m.group(2)!)}';
      }
    }
    // A tag that is an artist tells the searches whose song to look for.
    var tagArtist = '';
    if (!titleNamesSinger) {
      final names = tags.where(_looksLikeBareName).take(4).toList();
      final known = await Future.wait(names.map(_netEaseArtistExists));
      final i = known.indexOf(true);
      if (i >= 0) tagArtist = names[i];
    }
    final searchArtist = titleArtist.isNotEmpty ? titleArtist : tagArtist;
    // "翻唱周深《大鱼》", "Cover：买辣椒也用券": named as the one covered.
    final pre = _preprocess(rawTitle);
    bool coveredInTitle(String a) =>
        a.trim().isNotEmpty &&
        RegExp(
          '(?:翻唱|翻自|原唱|cover)(?:自)?[\\s:：]*${RegExp.escape(a.trim())}',
          caseSensitive: false,
        ).hasMatch(pre);
    // Whether the video credits [a]: named in the title, the uploader, or
    // the catalogue's fuller form of the name the title uses ("G.E.M.邓紫棋"
    // for 邓紫棋, "冯沁苑(买辣椒也用券)"). The title's name must stand apart
    // in the fuller one: 周深 does not credit the cover account 周深的水壶.
    final fullerName = titleArtist.length >= 2
        ? RegExp(
            '(?<![\\u4e00-\\u9fa5A-Za-z])${RegExp.escape(titleArtist)}'
            '(?![\\u4e00-\\u9fa5A-Za-z])',
            caseSensitive: false,
          )
        : null;
    bool credited(String a) {
      final n = _normalize(a);
      if (n.isEmpty) return false;
      if (coveredInTitle(a) || coveredInTitle(titleArtist)) {
        return n == normUploader;
      }
      return normCredits.contains(n) ||
          n == normUploader ||
          (fullerName != null && fullerName.hasMatch(a));
    }

    // Bilibili heard a song in the video, and the video names that song:
    // that is which song it is, however the title is worded. Who performs
    // it is read from the title against who the song belongs to.
    final recognised = _recognisedSong(hints, pre + context, normRaw);
    if (recognised != null) {
      final who = await _performers(
        title: '$pre $context',
        uploader: uploader,
        song: recognised,
        originals: hints.musicArtists,
        tags: tags,
        allTags: hints.tags,
        titleArtist: titleArtist,
      );
      // Offline is not an answer: ask again next time.
      if (who.incomplete) return null;
      final own = who.own && !who.rendition;
      final identity = SongIdentity(
        title: recognised,
        artist: who.artist.isEmpty ? uploader : who.artist,
        // The release's artwork, where the video is the song's own artist
        // performing it.
        coverUrl:
            own ? await _releaseCover(recognised, hints.musicArtists) : null,
        exact: own,
      );
      _remember(memoKey, identity);
      return identity;
    }

    final candidates = _generateCandidates(rawTitle);
    final hasUnmarkedBook =
        candidates.any((c) => c.containsKey('bookIdx') && c['showLike'] != '1');
    final usable = [
      for (final c in candidates)
        if (!(c['showLike'] == '1' && hasUnmarkedBook)) c,
    ];

    // "A - B" where exactly one side is a known artist settles which side
    // is the song before any scoring ("遥遥-周深" vs "周深-遥遥").
    String? settledSong;
    String? settledArtist;
    final sep = separator.firstMatch(_preprocess(rawTitle));
    if (sep != null && bookBracket.firstMatch(rawTitle) == null) {
      final left = _noisyClean(sep.group(1)!).trim();
      final right = _noisyClean(sep.group(2)!.split(RegExp(r'[|｜丨]')).first)
          .split(' ')
          .first
          .trim();
      if (_looksLikeBareName(left) && _looksLikeBareName(right)) {
        final known = await Future.wait(
            [_netEaseArtistExists(left), _netEaseArtistExists(right)]);
        if (known[0] != known[1]) {
          settledSong = known[0] ? right : left;
          settledArtist = known[0] ? left : right;
        }
      }
    }

    final queries = <String, Map<String, String>>{};
    for (final c in usable) {
      final song = c['song']!;
      if (settledSong != null &&
          _normalize(song) != _normalize(settledSong) &&
          _looksLikeBareName(song) &&
          !c.containsKey('bookIdx')) {
        continue;
      }
      final hint = (c['artistHint'] ?? '').isNotEmpty
          ? c['artistHint']!
          : (searchArtist != song ? searchArtist : '');
      queries.putIfAbsent('$hint $song'.trim(), () => c);
      // What the parser took for the singer may be anything that stood
      // before the brackets ("奥特曼限定版《孤勇者》"); a search led by it
      // finds nothing. A name the title brackets is asked for on its own too.
      // Nor does one led by a singer who is covering it (【步束】《海底》).
      if (hint.isNotEmpty && c.containsKey('bookIdx')) {
        queries.putIfAbsent(song, () => c);
      }
      if (queries.length >= 7) break;
    }
    // Tags as songs: those the title also contains first — they say which
    // of its words is the name.
    final tagSongs = [
      for (final t in tags)
        if (_normalize(t) != _normalize(searchArtist) &&
            _normalize(t) != normUploader)
          t,
    ]..sort((a, b) {
        int absent(String t) => normRaw.contains(_normalize(t)) ? 0 : 1;
        return absent(a).compareTo(absent(b));
      });
    if (settledSong == null) {
      final asked = {for (final c in queries.values) _normalize(c['song']!)};
      for (final t
          in tagSongs.where((t) => !asked.contains(_normalize(t))).take(2)) {
        queries.putIfAbsent(
            '$searchArtist $t'.trim(), () => {'song': t, 'tag': '1'});
      }
    }
    // The singer's own catalogue, for a name the title runs into its other
    // words ("周深再唱成名曲大鱼震撼全场").
    final catalogue = <String, String>{'song': '', 'catalogue': '1'};
    if (_looksLikeBareName(searchArtist) &&
        settledSong == null &&
        !hasUnmarkedBook) {
      queries.putIfAbsent(searchArtist, () => catalogue);
    }
    if (queries.isEmpty) return null;

    final results = await Future.wait(
      queries.entries.map((q) => _netEaseSearch(
            q.key,
            limit: identical(q.value, catalogue) ? 30 : 10,
          ).catchError((Object _) => null)),
    );
    // A search that failed leaves the picture incomplete: what the others
    // suggest may not be what all of them would have.
    var incomplete = results.contains(null);
    final titleTokens = {
      for (final t in _noisyClean(pre).split(' ')) _normalize(t),
    };

    // "夜曲", "小明 夜曲": little else in the title but the name.
    final cleanTokens = _noisyClean(_preprocess(rawTitle))
        .split(' ')
        .where((t) => t.isNotEmpty && !pureSeparatorToken.hasMatch(t))
        .toList();
    final cleanLength = _normalize(cleanTokens.join()).length;
    final shortTitle = cleanTokens.length <= 2;

    Map? best;
    var bestScore = 0.0;
    var bestExact = false;
    var bestRendition = false;
    var bestApart = false;
    var bestCredited = const <String>[];
    var bestGap = double.infinity;
    var anyResponse = false;
    final seen = <Object?>{};

    void consider(Map<String, String> candidate, List<Map> songs) {
      if (songs.isNotEmpty) anyResponse = true;
      final candNorm = _normalize(candidate['song']!);
      final bookIdx = int.tryParse(candidate['bookIdx'] ?? '') ?? -1;

      for (var rank = 0; rank < songs.length; rank++) {
        final song = songs[rank];
        if (!seen.add(song['id'])) continue;
        final name = ((song['name'] ?? '') as String).trim();
        final cleanName = name.replaceAll(parenSubtitle, '').trim();
        final nameNorm = _normalize(cleanName);
        if (nameNorm.isEmpty || !_isSaneOfficialTitle(cleanName)) continue;

        // The title must actually name this song.
        final specific = RegExp(r'[一-龥]').hasMatch(nameNorm)
            ? nameNorm.length >= 2
            : nameNorm.length >= 4;
        final isolated = nameNorm == candNorm;
        final inRaw = specific && normRaw.contains(nameNorm);
        final fromTag = candidate['tag'] == '1';
        final fromCatalogue = candidate['catalogue'] == '1';
        final named = isolated || inRaw || tagNorms.contains(nameNorm);
        if (!named) continue;
        if (settledSong != null && nameNorm != _normalize(settledSong)) {
          continue;
        }

        final artists = _artistsOf(song);
        final inTitle = [
          for (final a in artists)
            if (credited(a)) a,
        ];
        // On a cover the tags name the original singer: that confirms the
        // song, though not who is heard.
        final original = isCover &&
            inTitle.isEmpty &&
            artists.any((a) => tagNorms.contains(_normalize(a)));
        // Search-farm uploads are named like the query itself ("遥遥 周深").
        final echo = artists.isNotEmpty &&
            inTitle.isEmpty &&
            normRaw.length > nameNorm.length &&
            nameNorm == normRaw;

        final seconds = ((song['duration'] as num?) ?? 0) / 1000.0;
        final gap = durationSeconds > 0 && seconds > 0
            ? (seconds - durationSeconds).abs()
            : double.infinity;

        // A name alone proves little: common words are song names too
        // (经典, 回忆, 故事…). Without the artist or the length agreeing,
        // the title has to set the name apart structurally — in 《》, as
        // one side of "A - B", or by being nearly all there is.
        final corroborated = inTitle.isNotEmpty ||
            original ||
            // Named in the title and tagged by the uploader as well.
            (inRaw && tagNorms.contains(nameNorm)) ||
            gap <= 6 ||
            bookIdx >= 0 ||
            settledSong != null;
        // "Little else" is a name's worth of other text at most ("邓紫棋也是
        // 被逼得没办法了 哈哈" is not a title about 哈哈) — and where the
        // title brackets a name, that is the name it sets apart, not a
        // word beside it.
        final structural = isolated &&
            (!hasUnmarkedBook || bookIdx >= 0) &&
            // A bare number is a date or a count unless bracketed (《11》).
            (bookIdx >= 0 || !RegExp(r'^\d+$').hasMatch(nameNorm)) &&
            ((candidate['artistHint'] ?? '').isNotEmpty ||
                (shortTitle && cleanLength - nameNorm.length <= 7));
        if (!corroborated && !structural) continue;
        // A song only the tags name needs its artist credited too: tags are
        // full of ordinary words that are also song names.
        final onlyTags = !inRaw && (fromTag || !isolated);
        if (onlyTags && inTitle.isEmpty && !original) continue;
        if (fromCatalogue) {
          // Whatever the singer has recorded is not thereby in this video:
          // their name must be credited, and a two-character name has to
          // stand as a word of its own (or the length has to agree).
          if ((inTitle.isEmpty && !original) ||
              nameNorm == _normalize(searchArtist)) {
            continue;
          }
          if (nameNorm.length <= 2 &&
              !titleTokens.contains(nameNorm) &&
              !tagNorms.contains(nameNorm) &&
              gap > 15) {
            continue;
          }
        }

        var score = 2.0 + (nameNorm.length.clamp(1, 8)) * 0.25;
        // A tag is not the title setting a name apart: 大鱼海棠 (the film)
        // is tagged beside 大鱼 (the song).
        if (isolated && !fromTag) score += 1.0;
        // 《》 is how a title says "this is the song".
        if (bookIdx >= 0 && candidate['showLike'] != '1') score += 1.5;
        if (inTitle.isNotEmpty) score += 4.0;
        if (original) score += 2.0;
        if (inTitle.length == artists.length && artists.length > 1) {
          score += 1.0;
        }
        if (gap <= 2) {
          score += 4.0;
        } else if (gap <= 6) {
          score += 2.0;
        } else if (gap <= 15) {
          score += 0.5;
        } else if (gap != double.infinity && gap > 45 && !rawIsLive) {
          // Another recording of the same name (a remix, a cover, a live
          // cut) when the title promises none of those.
          score -= 1.5;
        }
        final isLive = _liveMarker.hasMatch(name) ||
            _liveMarker.hasMatch('${song['album']?['name'] ?? ''}');
        if (isLive == rawIsLive) score += 0.75;
        if (echo) score -= 5.0;
        // Earlier results are the provider's own best guess; later 《…》
        // pairs beat earlier ones (the first is usually the show).
        score -= rank * 0.05;
        score += bookIdx * 0.1;

        if (score > bestScore) {
          bestScore = score;
          best = song;
          // Only the title (or the uploader) can vouch for the artist: a
          // matching length makes a hit likelier, never certain — covers
          // run as long as the songs they cover.
          // Nor can it on a cover whose title sets no song apart: the name
          // there may be the original singer's ("这是周深唱的大鱼？") or the
          // one covering — settled below, against who the song belongs to.
          final apart = bookIdx >= 0 || (isolated && !fromTag);
          bestApart = apart;
          bestRendition = isRendition && !apart && gap > 6;
          bestCredited = inTitle;
          bestGap = gap;
          bestExact = inTitle.isNotEmpty && !bestRendition;
        }
      }
    }

    var qi = 0;
    for (final candidate in queries.values) {
      consider(candidate, results[qi++] ?? const []);
    }
    if (best == null) {
      // Offline or blocked is not "unknown song": stay retryable.
      if (anyResponse && !incomplete) _remember(memoKey, null);
      return null;
    }

    // Bilibili heard some other song, one the title does not name. A word
    // of the title that happens to be a song's name (情歌, 歌手) is then
    // not believed unless the title sets it apart as the song.
    if (hints.musicTitle.isNotEmpty && !bestApart) {
      _remember(memoKey, null);
      return null;
    }

    final name = ((best!['name'] ?? '') as String).trim();
    final cleanName = name.replaceAll(parenSubtitle, '').trim();
    final artists = _artistsOf(best!);

    // On a cover, a name in the title or the tags is either the song's own
    // artist or the one performing it — who may well not be the UP主 (a clip
    // of 周深 covering someone else's song). NetEase knows whose song it is.
    var originals = const <String>{};
    if (isCover && (!bestExact || isRendition)) {
      final asked = await _originalArtists(cleanName, best!);
      if (asked == null) incomplete = true;
      originals = asked ?? {for (final a in artists) _normalize(a)};
      bool own(String a) => originals
          .any((o) => o.contains(_normalize(a)) || _normalize(a).contains(o));
      // Nobody covers their own song: where the only artists the title
      // credits are the song's own and the recording is not theirs (the
      // length differs), someone else is performing it. Credited to anyone
      // else, it is that singer's recording.
      if (asked != null && isRendition && bestCredited.isNotEmpty) {
        final onlyOwn =
            bestCredited.every((a) => own(a) && _normalize(a) != normUploader);
        bestExact = !(onlyOwn && bestGap > 6);
      }
    }
    bool isOriginal(String name) {
      final n = _normalize(name);
      return coveredInTitle(name) ||
          (n.length >= 2 &&
              originals.any((o) => o.contains(n) || n.contains(o)));
    }

    String artist;
    if (bestExact) {
      final named = [
        for (final a in artists)
          if (credited(a) && _normalize(a) != normUploader) a,
      ];
      // A collaboration the title spells its own way (米津玄师 for 米津玄師)
      // is credited in full, as the catalogue lists it.
      // One the catalogue credits to fewer singers than the title names
      // (张信哲&张杰, listed under 张信哲) keeps the title's.
      final partners = titleArtist
          .split(RegExp(r'\s*[&、,，]\s*'))
          .where((p) => p.trim().isNotEmpty)
          .toList();
      final collab = partners.length > 1;
      artist = collab && artists.length < partners.length
          ? partners.join(' & ')
          : (named.isEmpty || collab ? artists : named).join(' & ');
    } else {
      // A cover: the database knows the song, the title knows the singer.
      // The singer is someone named who is not the one being covered: in
      // the title, else in the tags; failing both, the UP主.
      Future<String?> singerInTags() async {
        final names = tags
            .where((t) =>
                _looksLikeBareName(t) &&
                !isOriginal(t) &&
                !_normalize(t).contains(_normalize(cleanName)))
            .take(4)
            .toList();
        final known = await Future.wait(names.map(_netEaseArtistExists));
        final i = known.indexOf(true);
        return i < 0 ? null : names[i];
      }

      artist = settledArtist ??
          // The singer the title's own structure names (【张杰】…) comes
          // before any word in it that happens to be an artist's name.
          (titleNamesSinger &&
                  _normalize(titleArtist) != _normalize(cleanName) &&
                  !isOriginal(titleArtist)
              ? titleArtist
              : null) ??
          await _singerInTitle(rawTitle, song: cleanName, skip: isOriginal) ??
          (isCover ? await singerInTags() : null) ??
          // A fan channel is named after whom it follows (周深图文站).
          [_knownArtistIn(uploader)]
              .nonNulls
              .where((a) => !isOriginal(a))
              .firstOrNull ??
          (!bestRendition &&
                  titleArtist.isNotEmpty &&
                  _normalize(titleArtist) != _normalize(cleanName) &&
                  !isOriginal(titleArtist) &&
                  // Unconfirmed, it is believed only where the title puts
                  // it on purpose — in 【…】, as "A - B", or right against
                  // the song's brackets (刘端端姚晓棠《霸王别姬》) — not as
                  // whatever words stood near the song, and not an edition
                  // (史诗版, 动画原声带).
                  (bracketContent
                          .allMatches(pre)
                          .any((m) => m.group(1)!.contains(titleArtist)) ||
                      RegExp('${RegExp.escape(titleArtist)}'
                              r'(?:[《「『]|\s*[-–—])')
                          .hasMatch(pre)) &&
                  !RegExp(r'版$|原声|合集|\d').hasMatch(titleArtist)
              ? titleArtist
              : uploader);
    }

    // Singers the title itself names settle who is heard: all of them on
    // a duet the catalogue files under one (萨顶顶周深共唱《左手指月》), the
    // one who is not the song's own on a cover the title does not call
    // one, the UP主 where the title says whom it covers (cover周深).
    final who = await _performers(
      title: '$pre $context',
      uploader: uploader,
      song: cleanName,
      originals: [
        ...artists,
        // (Normalised names: only those that read the same either way.)
        ...originals.where(RegExp(r'^[\u4e00-\u9fa5·]+$').hasMatch),
      ],
      tags: tags,
      allTags: hints.tags,
      titleArtist: titleArtist,
    );
    if (who.incomplete) return null;
    if (who.decisive && who.artist.isNotEmpty) {
      artist = who.artist;
      bestExact = who.own && !who.rendition;
    }

    String? cover;
    if (bestExact) cover = await _netEaseCover(best!['id']);

    // An answer short of certain, reached with part of the evidence missing,
    // is not given: it would be written into the library for good.
    if (incomplete && !bestExact) return null;

    final identity = SongIdentity(
      title: cleanName,
      artist: artist,
      coverUrl: cover,
      exact: bestExact,
    );
    _remember(memoKey, identity);
    return identity;
  }

  /// A video about several songs — a medley, a countdown, someone reacting
  /// to a performance — is not one of them.
  static final RegExp _severalSongs = RegExp(
    r'串烧|联唱|盘点|排行榜|\breaction\b|\bmedley\b|\bmashup\b',
    caseSensitive: false,
  );

  /// The song Bilibili recognised in the video ([VideoHints.musicTitle]),
  /// if the video names it too. Recognition hears whatever music plays — in
  /// a vlog or an awards clip that is the backing track — so on its own it
  /// does not make the video that song; the title, or a tag, has to agree.
  static String? _recognisedSong(
      VideoHints hints, String title, String normTitle) {
    final clean = hints.musicTitle
        .replaceAll(parenSubtitle, '')
        .replaceFirst(RegExp(r'\s*[-–—]\s*live\s*$', caseSensitive: false), '')
        .trim();
    final norm = _normalize(clean);
    if (norm.isEmpty || !_isSaneOfficialTitle(clean)) return null;
    // Set apart in brackets, any name will do (《问》, 《SM》 for S&M).
    final bracketed = [
      ...bookBracket.allMatches(title),
      ...bracketContent.allMatches(title),
    ].any((m) => _normalize(m.group(1)!) == norm);
    if (bracketed) return clean;
    // Run into other words, it has to be long enough not to be one of them.
    final specific = RegExp(r'[\u4e00-\u9fa5]').hasMatch(norm)
        ? norm.length >= 2
        : norm.length >= 4;
    if (!specific) return null;
    final named = normTitle.contains(norm) ||
        hints.tags.any((t) => _normalize(t) == norm);
    return named ? clean : null;
  }

  /// Says the performance is somebody's version of another artist's song.
  static final RegExp _versionMarker = RegExp(
    r'翻唱|翻弹|翻奏|翻自|弹唱|扒谱|教学|教程|演奏|伴奏|纯音乐|合唱团|'
    r'\bcover\b|\bremix\b',
    caseSensitive: false,
  );

  /// Who is performing [song] in a video titled [title], given whose song
  /// it is ([originals]).
  ///
  /// The singers a title names are found by looking for names that could be
  /// one — the song's own artists, artists already in the library, tags,
  /// the uploader — and keeping those NetEase knows as a singer. Then:
  ///
  ///  * a name introduced as the one covered ("翻唱周深", "原唱：王菲",
  ///    "Cover 周深") is not performing;
  ///  * where the video is somebody's version ([_versionMarker]), the
  ///    performer is a singer named who is not the song's own (周深翻唱
  ///    《人间》), else the UP主 (翻唱周深《吉量》);
  ///  * otherwise everyone the title names is performing: the one who is
  ///    not the song's own on an unmarked cover (周深《人间》), both on a
  ///    duet (周深/五月天《如烟》);
  ///  * a title that names nobody leaves it to the tags, and then to the
  ///    song's own artists.
  ///
  /// [own] is whether every performer is one of the song's own artists;
  /// [inTitle], whether the answer was read from the title itself;
  /// [decisive], whether it would stand even if [originals] were only the
  /// artists of some recording of the song rather than the song's own;
  /// [incomplete], whether a name could not be looked up (offline).
  static Future<
      ({
        String artist,
        bool own,
        bool inTitle,
        bool rendition,
        bool decisive,
        bool incomplete
      })> _performers({
    required String title,
    required String uploader,
    required String song,
    required List<String> originals,
    required List<String> tags,
    required List<String> allTags,
    required String titleArtist,
  }) async {
    final normTitle = _normalize(title);
    final songNorm = _normalize(song);
    final originalNorms = {
      for (final o in originals)
        if (_normalize(o).length >= 2) _normalize(o),
    };
    // 邓紫棋 is "G.E.M. 邓紫棋"; 周深专辑 is not 周深.
    bool isOwn(String norm) =>
        norm.length >= 2 && originalNorms.any((o) => o.contains(norm));
    bool covered(String name) => RegExp(
          '(?:翻唱|翻自|原唱|cover|致敬|模仿|挑战|演绎|还原)(?:自|的)?'
          '[\\s:：.．·]*${RegExp.escape(name)}',
          caseSensitive: false,
        ).hasMatch(title);

    // A name NetEase could not be asked about may be a singer all the
    // same: the answer is then missing someone, and is not to be kept.
    var unasked = false;
    Future<bool> isSinger(String name) async {
      final norm = _normalize(name);
      if (isOwn(norm) || _knownArtists.containsKey(norm)) return true;
      final known = await (singerLookup ?? _netEaseSinger)(name);
      if (known == null) unasked = true;
      return known ?? false;
    }

    // Names worth looking for, most trusted first.
    final names = <String, String>{};
    void offer(String name) {
      final n = name.trim().replaceAll(RegExp(r'^·+|·+$'), '');
      final norm = _normalize(n);
      final cjk = RegExp(r'[\u4e00-\u9fa5]').hasMatch(norm);
      if (norm.length < (cjk ? 2 : 3) || norm.length > 16) return;
      if (norm == songNorm || songNorm.contains(norm)) return;
      names.putIfAbsent(norm, () => n);
    }

    originals.forEach(offer);
    _knownArtists.values.forEach(offer);
    // From here on, Chinese names only: a Latin word in a tag or a title
    // is an artist's name too often to mean anything (Mayday, Melody).
    final cjkName = RegExp(r'^[\u4e00-\u9fa5·]{2,7}$');
    final tagNames = <String>[];
    for (final tag in tags) {
      if (cjkName.hasMatch(tag)) {
        offer(tag);
        tagNames.add(tag);
      }
    }
    if (cjkName.hasMatch(uploader)) offer(uploader);
    for (final word in _noisyClean(title)
        .split(RegExp(r'[\s\-–—&×xX/／、,，|｜]+'))
        .where(cjkName.hasMatch)
        .take(8)) {
      offer(word);
    }
    for (final partner in titleArtist.split(RegExp(r'\s*[&、,，/／×]\s*'))) {
      if (cjkName.hasMatch(partner.trim())) offer(partner);
    }

    // Where each stands in the title, if it does.
    final found = <({String name, String norm, int at})>[];
    for (final entry in names.entries) {
      final at = normTitle.indexOf(entry.key);
      if (at < 0) continue;
      // A Latin name has to be a word of its own, not letters inside one.
      if (!RegExp(r'[\u4e00-\u9fa5]').hasMatch(entry.key) &&
          !RegExp(
            '(?<![A-Za-z])${RegExp.escape(entry.value)}(?![A-Za-z])',
            caseSensitive: false,
          ).hasMatch(title)) {
        continue;
      }
      found.add((name: entry.value, norm: entry.key, at: at));
    }
    found.sort((a, b) => a.at.compareTo(b.at));
    final verified = await Future.wait(found.map((m) => isSinger(m.name)));
    final inTitle = [
      for (var i = 0; i < found.length; i++)
        if (verified[i]) found[i],
    ];
    // 五月天, not also 五月.
    inTitle.removeWhere(
        (m) => inTitle.any((o) => o.norm != m.norm && o.norm.contains(m.norm)));

    final performing = [
      for (final m in inTitle)
        if (!covered(m.name)) m,
    ];
    // A tag says so when that is all it says (翻唱, 吉他弹唱), not when it
    // is a sentence that happens to hold the word — and only of singing:
    // 演奏 and 伴奏 are tagged on anything with a band in it.
    final sungVersion = RegExp(r'翻唱|翻自|弹唱|\bcover\b', caseSensitive: false);
    final rendition = _versionMarker.hasMatch(title) ||
        allTags
            .any((t) => _normalize(t).length <= 5 && sungVersion.hasMatch(t)) ||
        inTitle.any((m) => covered(m.name));
    final someoneElse = performing.any((m) => !isOwn(m.norm));

    ({
      String artist,
      bool own,
      bool inTitle,
      bool rendition,
      bool decisive,
      bool incomplete
    }) answer(
      Iterable<String> who, {
      required bool fromTitle,
    }) =>
        (
          artist: who.join(' & '),
          own: who.isNotEmpty && who.every((n) => isOwn(_normalize(n))),
          inTitle: fromTitle,
          rendition: rendition,
          // What does not depend on [originals] being the song's true
          // artists: a singer named who is not one of them, or the title
          // saying outright whom it covers.
          decisive: fromTitle &&
              (rendition
                  ? someoneElse || inTitle.any((m) => covered(m.name))
                  : true),
          incomplete: unasked,
        );

    // Singers the tags name, for a title that names none.
    Future<List<String>> taggedSingers() async {
      final candidates = [
        for (final t in tagNames.take(6))
          if (_normalize(t) != songNorm && !songNorm.contains(_normalize(t))) t,
      ];
      final known = await Future.wait(candidates.map(isSinger));
      return [
        for (var i = 0; i < candidates.length; i++)
          if (known[i]) candidates[i],
      ];
    }

    if (rendition) {
      final others = [
        for (final m in performing)
          if (!isOwn(m.norm)) m.name,
      ];
      if (others.isNotEmpty) return answer(others, fromTitle: true);
      // Named only as the ones covered, or not at all: a singer the tags
      // name who is not the song's own, else whoever uploaded it.
      if (inTitle.isEmpty) {
        final tagged = [
          for (final t in await taggedSingers())
            if (!isOwn(_normalize(t))) t,
        ];
        if (tagged.isNotEmpty) return answer(tagged, fromTitle: false);
      }
      return answer([uploader], fromTitle: inTitle.isNotEmpty);
    }

    if (performing.isNotEmpty) {
      return answer(performing.map((m) => m.name), fromTitle: true);
    }
    final tagged = await taggedSingers();
    final others = [
      for (final t in tagged)
        if (!isOwn(_normalize(t))) t,
    ];
    if (others.isNotEmpty) return answer(tagged, fromTitle: false);
    return answer(originals, fromTitle: false);
  }

  static final Map<String, bool> _singerMemo = {};

  /// Whether [name] is a singer NetEase has music videos for. Nearly any
  /// word is some account's artist name there (生米, 民乐, 女中音, 大合唱);
  /// a name the title or the tags use is taken for a performer only when it
  /// is an established one. Null when NetEase could not be asked.
  static Future<bool?> _netEaseSinger(String name) async {
    final key = _normalize(name);
    if (key.isEmpty) return false;
    final cached = _singerMemo[key];
    if (cached != null) return cached;
    final body = await _httpGet(
      'https://music.163.com/api/search/get'
      '?s=${Uri.encodeComponent(name)}&type=100&limit=5',
      headers: {'Referer': 'https://music.163.com'},
    );
    if (body == null) return null;
    try {
      final artists = jsonDecode(body)['result']?['artists'] as List? ?? [];
      final known = artists.whereType<Map>().any((a) =>
          a['name'] is String &&
          _normalize(a['name'] as String) == key &&
          ((a['mvSize'] as num?) ?? 0) > 0);
      if (_singerMemo.length > 300) _singerMemo.clear();
      return _singerMemo[key] = known;
    } catch (e) {
      debugPrint('NetEase singer check error: $e');
      return null;
    }
  }

  /// Replaces the NetEase singer lookup in tests (null: could not ask).
  @visibleForTesting
  static Future<bool?> Function(String name)? singerLookup;

  /// The artwork of [song] as released by one of [artists], or null.
  static Future<String?> _releaseCover(
      String song, List<String> artists) async {
    if (artists.isEmpty) return null;
    final songs = await _netEaseSearch('${artists.first} $song', limit: 5);
    final songNorm = _normalize(song);
    final artistNorms = {for (final a in artists) _normalize(a)};
    for (final s in songs ?? const <Map>[]) {
      final name = '${s['name'] ?? ''}'.replaceAll(parenSubtitle, '');
      if (_normalize(name) != songNorm) continue;
      final by = _artistsOf(s).map(_normalize);
      if (!by
          .any((a) => artistNorms.any((o) => o.contains(a) || a.contains(o)))) {
        continue;
      }
      return _netEaseCover(s['id']);
    }
    return null;
  }

  /// A name in the title that NetEase knows as an artist (CJK names only:
  /// ASCII words like "Melody" are artists too, and prove nothing).
  static Future<String?> _singerInTitle(
    String rawTitle, {
    required String song,
    bool Function(String name)? skip,
  }) async {
    final songNorm = _normalize(song);
    final names = _noisyClean(_preprocess(rawTitle))
        // "周杰伦-晴天" is two names with no space between them.
        .split(RegExp(r'[\s\-–—]+'))
        .where((t) =>
            RegExp(r'^[\u4e00-\u9fa5·]{2,7}$').hasMatch(t) &&
            // 大鱼海棠 beside 大鱼 is the film, not a singer.
            !_normalize(t).contains(songNorm) &&
            !(skip?.call(t) ?? false))
        .take(3);
    for (final name in names) {
      if (await _netEaseArtistExists(name)) return name;
    }
    return null;
  }

  /// Longer than this is a concert or a compilation, not a song.
  static const int _longestSong = 15 * 60;

  static String _memoKey(String rawTitle, String uploader, int seconds,
          String context, VideoHints hints) =>
      '$rawTitle\x00$uploader\x00$seconds\x00$context\x00${hints.key}';

  /// Whether [identify] has already settled this question (found the song,
  /// or established that the databases do not know it). False after a lookup
  /// that failed for lack of a connection — that one is worth asking again.
  static bool identitySettled(
    String rawTitle, {
    String uploader = '',
    int durationSeconds = 0,
    String context = '',
    VideoHints hints = VideoHints.none,
  }) =>
      _identityMemo.containsKey(
          _memoKey(rawTitle, uploader, durationSeconds, context, hints));

  static void _remember(String key, SongIdentity? identity) {
    if (_identityMemo.length > 300) _identityMemo.clear();
    _identityMemo[key] = identity;
  }

  /// The album artwork of a NetEase song, or null.
  static Future<String?> _netEaseCover(Object? songId) async {
    if (songId == null) return null;
    try {
      final body = await _httpGet(
        'https://music.163.com/api/song/detail?ids=%5B$songId%5D',
        headers: {'Referer': 'https://music.163.com'},
      );
      if (body == null) return null;
      final songs = jsonDecode(body)['songs'] as List? ?? const [];
      if (songs.isEmpty) return null;
      final url = songs.first['album']?['picUrl'];
      if (url is! String || url.isEmpty) return null;
      // NetEase serves one stock image for albums without artwork.
      if (url.contains('UeTuwE7pvjBpypWLudqukA') || url.endsWith('/0.jpg')) {
        return null;
      }
      return url.replaceFirst('http://', 'https://');
    } catch (e) {
      debugPrint('NetEase cover lookup error: $e');
      return null;
    }
  }

  /// [identify] as a `{songTitle, artist}` map, falling back to the offline
  /// rule parse ([cleanTitle]) when nothing is confirmed.
  static Future<Map<String, String>> cleanTitleWithValidation(
    String rawTitle, {
    String defaultArtist = '',
  }) async {
    final identity = await identify(rawTitle, uploader: defaultArtist);
    if (identity == null) {
      return cleanTitle(rawTitle, defaultArtist: defaultArtist);
    }
    return {'songTitle': identity.title, 'artist': identity.artist};
  }

  /// Whether [name] is a real NetEase artist (type=100 search), memoized per
  /// session. Used to trust a title token as the singer without a full
  /// "artist song" lyric hit.
  static final Map<String, bool> _artistExistsMemo = {};

  static Future<bool> _netEaseArtistExists(String name) async {
    final key = _normalize(name);
    if (key.isEmpty) return false;
    final cached = _artistExistsMemo[key];
    if (cached != null) return cached;
    final url = 'https://music.163.com/api/search/get'
        '?s=${Uri.encodeComponent(name)}&type=100&limit=5';
    try {
      final body =
          await _httpGet(url, headers: {'Referer': 'https://music.163.com'});
      if (body != null) {
        final json = jsonDecode(body);
        final artists = json['result']?['artists'] as List? ?? [];
        final exists = artists.any((a) {
          final an = (a is Map ? a['name'] as String? : null) ?? '';
          return an.isNotEmpty && _normalize(an) == key;
        });
        if (_artistExistsMemo.length > 200) _artistExistsMemo.clear();
        _artistExistsMemo[key] = exists;
        return exists;
      }
    } catch (e) {
      debugPrint('NetEase artist check error: $e');
    }
    return false;
  }

  /// Matches a provider song name against a search title. Provider names
  /// compare with their parenthesised subtitle stripped ("岁月 (live)" must
  /// match 《岁月》), and a compound "artist song" title also matches on its
  /// post-space part — otherwise short song names (2–3 chars, e.g. 岁月)
  /// could never pass [isTitleMatching]'s length guard against a query like
  /// "黄绮珊&周深 岁月". A query may carry several artist tokens before the
  /// song ("陈楚生 周深 逆光"), so every space-suffix is tried, not just the
  /// first tail.
  static bool matchesSongQuery(String songName, String title) {
    final cleanName = songName.replaceAll(parenSubtitle, '').trim();
    if (isTitleMatching(cleanName, title)) return true;
    final tokens =
        title.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    for (var i = 1; i < tokens.length; i++) {
      if (isTitleMatching(cleanName, tokens.sublist(i).join(' '))) return true;
    }
    return false;
  }

  /// CJK-leaning bracket content ending in a 1–2 digit season marker:
  /// 声生不息3, 我们的歌5. ASCII ids (SNH48) and 4-digit years (歌手2024) are
  /// deliberately excluded — the former are group names, the latter too
  /// ambiguous to trust here.
  static bool _looksLikeShowSeason(String bracketText) =>
      RegExp(r'^[\u4e00-\u9fa5A-Za-z·]+\d{1,2}$').hasMatch(bracketText) &&
      RegExp(r'[\u4e00-\u9fa5]').hasMatch(bracketText);

  /// Tokens that read like names but never are: descriptors that sit between
  /// a tag bracket and the song bracket ("【tag】周深 新歌《X》"). Kept as an
  /// exact-match set — see the multi-name gate in [cleanTitle].
  static const Set<String> _betweenJunk = {
    '新歌',
    '新歌首发',
    '演唱会',
    '全程',
    '直播',
    '预告',
    '花絮',
    '采访',
    '幕后',
    '排练',
    '首唱',
    'reaction',
  };

  /// A single token that reads like one artist name: 2–7 name characters,
  /// nothing else. Descriptors (精选歌单合集, 总选跳, 弹奏…) can still slip
  /// through, which is why this gate only opens behind [_looksLikeShowSeason].
  static bool _looksLikeBareName(String t) =>
      RegExp(r'^[\u4e00-\u9fa5A-Za-z·]{2,7}$').hasMatch(t);

  // Normalize string for candidate matching verification
  static String _normalize(String input) {
    // Keep · (middle dot) which is part of many artist names (陈奕迅·孤勇者)
    return input
        .replaceAll(RegExp(r'[^\u4e00-\u9fa5a-zA-Z0-9·]'), '')
        .toLowerCase();
  }

  /// Structural sanity gate for a DB-confirmed song name. NetEase hosts
  /// episode-level "纯享" tracks whose official title IS the whole video title
  /// ("【纯享】刘端端姚晓棠《霸王别姬》… | 音乐缘计划 | iQIYI奇艺音悦台") — they match
  /// the raw title verbatim and would score top, so anything still carrying
  /// bracket/bar markers or an episode-length title is not a song.
  static bool _isSaneOfficialTitle(String s) {
    if (s.isEmpty || s.length > 24) return false;
    return !RegExp(r'[《》【】\[\]|｜丨]').hasMatch(s);
  }

  static bool isTitleMatching(String candidateName, String targetTitle) {
    final cand = _normalize(candidateName);
    final target = _normalize(targetTitle);
    if (cand.isEmpty || target.isEmpty) return false;
    if (cand == target) return true;
    // CJK 2-char titles like 光亮/起风了 are specific; ASCII 2-char like 11 is not
    final candIsCjk = RegExp(r'[\u4e00-\u9fa5]').hasMatch(cand);
    final targetIsCjk = RegExp(r'[\u4e00-\u9fa5]').hasMatch(target);
    final minLen = (candIsCjk && targetIsCjk) ? 2 : 4;
    if (cand.length < minLen || target.length < minLen) return false;
    // For ASCII short targets still guard 11 vs 2011: require exact for <4
    if (!candIsCjk && !targetIsCjk && (cand.length < 4 || target.length < 4)) {
      return false;
    }
    return cand.contains(target) || target.contains(cand);
  }

  /// Parses LRC text into time-sorted lines.
  ///
  /// Handles the two forms the old parser silently dropped, both of which are
  /// everywhere in real .lrc files:
  ///  * `[mm:ss]` with no fractional part — previously skipped entirely, so
  ///    whole files could import as zero lines.
  ///  * Several timestamps sharing one line (`[00:12.00][01:30.00]副歌`) for a
  ///    repeated chorus — previously only the first was kept, so the chorus
  ///    never highlighted on later passes.
  static final RegExp _lrcTag =
      RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');

  static List<LyricLine> parseLrc(String lrcText) {
    if (lrcText.isEmpty) return [];

    final result = <LyricLine>[];

    for (final line in lrcText.split('\n')) {
      final matches = _lrcTag.allMatches(line).toList();
      if (matches.isEmpty) continue;

      final text = line.replaceAll(_lrcTag, '').trim();
      if (text.isEmpty) continue;

      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3);
        // "5" means .5s, "05" means .05s, "050" means .050s.
        final millis = fraction == null
            ? 0
            : int.parse(fraction.padRight(3, '0').substring(0, 3));
        result.add(LyricLine(
          time: minutes * 60 + seconds + millis / 1000.0,
          text: text,
        ));
      }
    }

    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  /// Serialises lines back to LRC text (inverse of [parseLrc]).
  ///
  /// [offset] is baked into the written times, so text exported from
  /// calibrated lyrics reads back already in sync.
  static String toLrc(List<LyricLine> lines, {double offset = 0.0}) {
    final sb = StringBuffer();
    final timed = lines.length > 1 && lines.last.time > 0;
    for (final line in lines) {
      if (!timed) {
        sb.writeln(line.text);
        continue;
      }
      // Round to whole milliseconds first: `sec.toStringAsFixed(2)` on a value
      // like 59.9996s would otherwise round up to "[mm:60.00]", which parseLrc
      // cannot read back.
      final totalMillis =
          ((line.time + offset).clamp(0.0, 359999.0) * 1000).round();
      final min = totalMillis ~/ 60000;
      final secMillis = totalMillis % 60000;
      final sec = (secMillis / 1000).floor();
      final centis = (secMillis % 1000) ~/ 10;
      final tag = '[${min.toString().padLeft(2, '0')}:'
          '${sec.toString().padLeft(2, '0')}.${centis.toString().padLeft(2, '0')}]';
      sb.writeln('$tag${line.text}');
      if (line.translation != null && line.translation!.isNotEmpty) {
        sb.writeln('$tag${line.translation}');
      }
    }
    return sb.toString();
  }

  // LRCLIB Provider (fallback, global coverage)
  static Future<Lyrics?> fetchFromLRCLIB(String title, {String? artist}) async {
    final queries = [
      if (artist != null && artist.isNotEmpty) '$artist $title',
      if (artist != null && artist.isNotEmpty) '$title $artist',
      title,
    ];
    for (final query in queries) {
      final url =
          'https://lrclib.net/api/search?q=${Uri.encodeComponent(query)}';
      try {
        final body =
            await _httpGet(url, headers: {'User-Agent': 'bilibeats/1.0.0'});
        if (body != null) {
          final items = jsonDecode(body) as List? ?? [];
          for (final item in items) {
            final trackName = (item['trackName'] ?? '') as String;
            if (!isTitleMatching(trackName, title)) continue;
            // Artist check when provided: prefer matching artist
            if (artist != null && artist.isNotEmpty) {
              final artistName = (item['artistName'] ?? '') as String;
              final normArtist = _normalize(artist);
              final normItemArtist = _normalize(artistName);
              // If artist mismatch strongly, skip this item unless title is exact
              if (normArtist.isNotEmpty &&
                  normItemArtist.isNotEmpty &&
                  normArtist != normItemArtist) {
                // Allow if title matches exactly, otherwise require artist contains
                if (_normalize(trackName) != _normalize(title)) {
                  // Check if item artist contains query artist or vice versa
                  if (!normItemArtist.contains(normArtist) &&
                      !normArtist.contains(normItemArtist)) {
                    continue;
                  }
                }
              }
            }
            final rawLrc =
                (item['syncedLyrics'] ?? item['plainLyrics'] ?? '') as String;
            final lines = parseLrc(rawLrc);
            if (lines.isNotEmpty) {
              return Lyrics(
                source: 'lrclib',
                title: trackName.isNotEmpty ? trackName : title,
                artist: (item['artistName'] as String?) ?? artist,
                lines: lines,
              );
            } else if (rawLrc.isNotEmpty) {
              // Plain lyrics fallback as single block
              return Lyrics(
                source: 'lrclib',
                title: trackName.isNotEmpty ? trackName : title,
                artist: (item['artistName'] as String?) ?? artist,
                lines: plainLines(rawLrc),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('LRCLIB fetch error: $e');
      }
    }
    return null;
  }

  // NetEase Cloud Music Provider (Best Chinese coverage)
  static Future<Lyrics?> fetchFromNetEase(String title,
      {String? artist}) async {
    final queries = [
      if (artist != null && artist.isNotEmpty) '$artist $title',
      if (artist != null && artist.isNotEmpty) '$title $artist',
      title,
    ];

    for (final query in queries) {
      final searchUrl =
          'https://music.163.com/api/search/get?s=${Uri.encodeComponent(query)}&type=1&limit=5';
      try {
        final searchBody = await _httpGet(searchUrl,
            headers: {'Referer': 'https://music.163.com'});
        if (searchBody != null) {
          final json = jsonDecode(searchBody);
          final songs = json['result']?['songs'] as List? ?? [];
          // Prefer the song whose artist appears in the query: "周深 不舍"
          // must yield 周深's 不舍, not the most popular 不舍 (a cover by
          // someone else) that happens to match the song name first.
          final queryNorm = _normalize(query);
          (Map, List<LyricLine>)? bestMatch;
          (Map, List<LyricLine>)? queryArtistMatch;
          (Map, List<LyricLine>)? echoMatch;
          for (final song in songs) {
            final songName = (song['name'] ?? '') as String;
            if (!matchesSongQuery(songName, query)) continue;
            final songId = song['id'];
            if (songId is! int || songId <= 0) continue;
            final lyricUrl =
                'https://music.163.com/api/song/lyric?id=$songId&lv=-1&tv=-1';

            final lyricBody = await _httpGet(lyricUrl,
                headers: {'Referer': 'https://music.163.com'});
            if (lyricBody != null) {
              final lyricJson = jsonDecode(lyricBody);
              final rawLrc = (lyricJson['lrc']?['lyric'] ?? '') as String;
              final rawTrans = (lyricJson['tlyric']?['lyric'] ?? '') as String;

              final lines = parseLrc(rawLrc);
              final transLines = parseLrc(rawTrans);

              if (transLines.isNotEmpty) {
                // Both lists are time-sorted, so a single advancing pointer
                // keeps the merge O(n) instead of the previous O(n²)
                // firstWhere-scan per line.
                var ti = 0;
                for (var i = 0; i < lines.length; i++) {
                  final line = lines[i];
                  // Skip translations that are too early for this line.
                  while (ti < transLines.length &&
                      transLines[ti].time < line.time - 0.5) {
                    ti++;
                  }
                  // ti is now the first translation inside the window, if any.
                  if (ti < transLines.length &&
                      (transLines[ti].time - line.time).abs() < 0.5) {
                    lines[i] = LyricLine(
                      time: line.time,
                      text: line.text,
                      translation: transLines[ti].text,
                    );
                  }
                }
              }

              if (lines.isNotEmpty) {
                // Search-farm uploads are titled exactly like the query
                // ("遥遥 周深" for "周深 遥遥"): their title echoes BOTH the
                // song term and the artist term. They outrank real songs in
                // the result list, so rank them last — the real track (遥遥 by
                // 张云雷, say) must win the match.
                final songNameNorm = _normalize(songName);
                final isEcho = artist != null &&
                    artist.isNotEmpty &&
                    songNameNorm.isNotEmpty &&
                    songNameNorm.contains(_normalize(artist)) &&
                    songNameNorm.contains(_normalize(title));
                if (isEcho) {
                  echoMatch ??= (song, lines);
                  continue;
                }
                bestMatch ??= (song, lines);
                final artists = (song['artists'] as List? ?? [])
                    .where((a) => a is Map && a['name'] is String)
                    .map((a) => a['name'] as String)
                    .join(', ');
                if (queryNorm.isNotEmpty &&
                    artists.isNotEmpty &&
                    queryNorm.contains(_normalize(artists))) {
                  queryArtistMatch = (song, lines);
                  break;
                }
              }
            }
          }
          final chosen = queryArtistMatch ?? bestMatch ?? echoMatch;
          if (chosen != null) {
            final (chosenSong, lines) = chosen;
            final songName = (chosenSong['name'] ?? '') as String;
            final artists = (chosenSong['artists'] as List? ?? [])
                .where((a) => a is Map && a['name'] is String)
                .map((a) => a['name'] as String)
                .join(', ');
            return Lyrics(
              source: 'netease',
              title: songName,
              artist: artists.isNotEmpty ? artists : artist,
              lines: lines,
            );
          }
        }
      } catch (e) {
        debugPrint('NetEase lyrics fetch error: $e');
      }
    }

    return null;
  }

  /// Untimed text as lines (all at 0:00, so [Lyrics.synced] is false).
  static List<LyricLine> plainLines(String text) => [
        for (final line in text.split('\n'))
          if (line.trim().isNotEmpty) LyricLine(time: 0, text: line.trim()),
      ];

  /// LRC when the text carries timestamps, plain lines otherwise.
  static List<LyricLine> parseAny(String text) {
    final timed = parseLrc(text);
    return timed.isNotEmpty ? timed : plainLines(text);
  }

  static Future<List<LyricLine>> _netEaseLines(Object songId) async {
    final body = await _httpGet(
      'https://music.163.com/api/song/lyric?id=$songId&lv=-1&tv=-1',
      headers: {'Referer': 'https://music.163.com'},
    );
    if (body == null) return const [];
    final json = jsonDecode(body);
    final lines = parseLrc((json['lrc']?['lyric'] ?? '') as String);
    final trans = parseLrc((json['tlyric']?['lyric'] ?? '') as String);
    var ti = 0;
    for (var i = 0; i < lines.length && trans.isNotEmpty; i++) {
      final line = lines[i];
      while (ti < trans.length && trans[ti].time < line.time - 0.5) {
        ti++;
      }
      if (ti < trans.length && (trans[ti].time - line.time).abs() < 0.5) {
        lines[i] = LyricLine(
          time: line.time,
          text: line.text,
          translation: trans[ti].text,
        );
      }
    }
    return lines;
  }

  /// Every plausible match for a manual search, best first: the picker shows
  /// what the databases actually have rather than a single guess. Unlike the
  /// automatic lookup this does not filter by title — the listener is the
  /// judge here.
  static Future<List<Lyrics>> searchCandidates(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    Future<List<Lyrics>> netEase() async {
      try {
        final body = await _httpGet(
          'https://music.163.com/api/search/get'
          '?s=${Uri.encodeComponent(q)}&type=1&limit=8',
          headers: {'Referer': 'https://music.163.com'},
        );
        if (body == null) return const [];
        final songs = (jsonDecode(body)['result']?['songs'] as List? ?? [])
            .whereType<Map>()
            .where((song) => song['id'] is int)
            .take(6)
            .toList();
        final all = await Future.wait(songs.map((song) async {
          final lines = await _netEaseLines(song['id'] as int)
              .catchError((Object _) => const <LyricLine>[]);
          final artists = (song['artists'] as List? ?? [])
              .where((a) => a is Map && a['name'] is String)
              .map((a) => a['name'] as String)
              .join(', ');
          return Lyrics(
            source: 'netease',
            title: (song['name'] ?? '') as String,
            artist: artists,
            lines: lines,
          );
        }));
        return [
          for (final l in all)
            if (l.isNotEmpty) l
        ];
      } catch (e) {
        debugPrint('NetEase candidate search error: $e');
        return const [];
      }
    }

    Future<List<Lyrics>> lrclib() async {
      try {
        final body = await _httpGet(
          'https://lrclib.net/api/search?q=${Uri.encodeComponent(q)}',
          headers: {'User-Agent': 'bilibeats/1.0.0'},
        );
        if (body == null) return const [];
        final out = <Lyrics>[];
        for (final item in (jsonDecode(body) as List? ?? []).whereType<Map>()) {
          final raw =
              (item['syncedLyrics'] ?? item['plainLyrics'] ?? '') as String;
          final lines = parseAny(raw);
          if (lines.isEmpty) continue;
          out.add(Lyrics(
            source: 'lrclib',
            title: (item['trackName'] ?? '') as String,
            artist: (item['artistName'] ?? '') as String,
            lines: lines,
          ));
          if (out.length == 6) break;
        }
        return out;
      } catch (e) {
        debugPrint('LRCLIB candidate search error: $e');
        return const [];
      }
    }

    final found = await Future.wait([netEase(), lrclib()]);
    final seen = <String>{};
    return [
      for (final lyrics in found.expand((list) => list))
        if (seen.add(lyrics.fingerprint)) lyrics,
    ];
  }

  // Multi-source Waterfall Lyrics Orchestrator
  ///
  /// [song] / [artist] override the title parse — used when the listener has
  /// named the song themselves, which beats anything guessed from a video
  /// title.
  static Future<Lyrics> autoFetchLyrics(
    String rawTitle, {
    String? song,
    String? artist,
  }) async {
    final cleaned = cleanTitle(rawTitle);
    final title = song ?? cleaned['songTitle']!;
    artist ??= cleaned['artist'];

    // Step 1: NetEase (best Chinese coverage, prioritized)
    final neteaseResult = await fetchFromNetEase(title, artist: artist);
    if (neteaseResult != null && neteaseResult.lines.isNotEmpty) {
      return neteaseResult;
    }

    // Step 2: LRCLIB fallback (global coverage, e.g. Western/Japanese)
    try {
      final lrclibResult = await fetchFromLRCLIB(title, artist: artist);
      if (lrclibResult != null && lrclibResult.lines.isNotEmpty) {
        return lrclibResult;
      }
    } catch (e) {
      debugPrint('LRCLIB fallback error: $e');
    }

    return Lyrics(
        source: 'none', title: title, artist: artist, lines: const []);
  }
}
