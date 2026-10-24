import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/track.dart';
import '../models/video_hints.dart';
import 'bili_http.dart';
import 'fingerprint_service.dart';
import 'wbi_signer.dart';

/// Thrown when every applicable Bilibili request for an operation failed at
/// the transport/API level. Callers distinguish this from a successful empty
/// result (`[]` = no matches): a throw means "couldn't load", never "missing".
class BiliApiException implements Exception {
  final String message;
  const BiliApiException(this.message);
  @override
  String toString() => 'BiliApiException: $message';
}

class BilibiliSdk {
  static const String _baseUrl = 'https://api.bilibili.com';

  /// 音乐 partition. Covers 原创音乐 / 翻唱 / 演奏 / VOCALOID / 音乐现场 / MV /
  /// 音乐综合 — everything a music player has any business showing.
  static const int _musicZoneId = 3;
  static final HttpClient _httpClient = biliHttpClient(
      connectionTimeout: const Duration(seconds: 15),
      maxConnectionsPerHost: 10);

  static final RegExp _htmlTagRegex = RegExp(r'<[^>]+>');

  static final RegExp _htmlEntity =
      RegExp(r'&(amp|lt|gt|quot|apos|nbsp|#\d{1,7}|#x[0-9a-fA-F]{1,6});');

  /// The search API answers in HTML: `&amp;`, `&quot;`, `&#39;`.
  @visibleForTesting
  static String unescapeHtml(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(_htmlEntity, (m) {
      final name = m.group(1)!;
      switch (name) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        case 'nbsp':
          return ' ';
      }
      final code = name.startsWith('#x')
          ? int.tryParse(name.substring(2), radix: 16)
          : int.tryParse(name.substring(1));
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    });
  }

  static Future<String?> _httpGet(String rawUrl, {String? cookies}) async {
    try {
      final req = await _httpClient
          .getUrl(Uri.parse(rawUrl))
          .timeout(const Duration(seconds: 10));
      req.headers.set('Referer', 'https://www.bilibili.com');
      req.headers.set('User-Agent', kBiliUserAgent);
      if (cookies != null && cookies.isNotEmpty) {
        req.headers.set('Cookie', cookies);
      }
      // A request given up on is aborted: left alone it keeps one of the
      // four connections the pool allows this host.
      final res = await req.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          req.abort();
          throw TimeoutException('Bilibili request timed out');
        },
      );
      if (res.statusCode == 200) {
        return await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10));
      } else {
        await res.listen((_) {}).cancel();
        debugPrint('Bilibili HTTP ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('Bilibili HTTP fetch error: $e');
    }
    return null;
  }

  /// A BV number standing on its own: every one starts `BV1` and is twelve
  /// characters. Without the boundaries any word holding "bv" plus ten
  /// letters ("subversiveness") read as a video id.
  static final RegExp _bvId = RegExp(
    r'(?<![A-Za-z0-9])BV(1[A-Za-z0-9]{9})(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  /// An av number standing on its own ("av170001", not "wav24bit").
  static final RegExp _avId = RegExp(
    r'(?<![A-Za-z0-9])av(\d+)(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  // Extract BV or AV ID from input query
  static String? extractBvOrAvId(String input) {
    // Upper-case prefix; the rest of a BV number is case-sensitive.
    final bvMatch = _bvId.firstMatch(input);
    if (bvMatch != null) return 'BV${bvMatch.group(1)}';

    // The API's `aid` parameter expects bare digits, not the "av" prefix.
    return _avId.firstMatch(input)?.group(1);
  }

  /// Resolve Bilibili short links (b23.tv / bili2233.cn / acg.tv) that do not
  /// contain a BV directly. Returns the resolved URL or extracted id, or null.
  static Future<String?> _resolveShortLink(String input) async {
    // Find first URL in the input (share text often is `【标题】 https://b23.tv/xxx`)
    // Also handle bare domain without scheme: `b23.tv/xxx`
    final urlMatch =
        RegExp(r'(?:https?://)?(?:www\.)?(?:b23\.tv|bili2233\.cn|acg\.tv)/[^\s]+',
                    caseSensitive: false)
                .firstMatch(input) ??
            RegExp(r'https?://[^\s]+').firstMatch(input);
    if (urlMatch == null) return null;
    var urlStr = urlMatch.group(0)!;
    if (!urlStr.startsWith('http')) urlStr = 'https://$urlStr';
    // Strip trailing punctuation that is not part of URL
    urlStr = urlStr.replaceAll(RegExp(r'[\)\]】」』）.,;!]+$'), '');
    if (!urlStr.contains('b23.tv') &&
        !urlStr.contains('bili2233.cn') &&
        !urlStr.contains('acg.tv')) {
      return null;
    }
    try {
      final parsed = Uri.parse(urlStr);
      final uri =
          parsed.scheme == 'http' ? parsed.replace(scheme: 'https') : parsed;
      // The share host itself, over TLS — not any address that happens to
      // contain its name.
      const hosts = ['b23.tv', 'bili2233.cn', 'acg.tv'];
      if (uri.scheme != 'https' ||
          !hosts.any((h) => uri.host == h || uri.host.endsWith('.$h'))) {
        return null;
      }
      // The redirect itself names the video: read it rather than follow it
      // to a whole page (and to wherever else it might point).
      final first =
          await _httpClient.getUrl(uri).timeout(const Duration(seconds: 5));
      first.followRedirects = false;
      first.headers.set('User-Agent', kBiliUserAgent);
      first.headers.set('Referer', 'https://www.bilibili.com/');
      final hop = await first.close().timeout(const Duration(seconds: 5));
      final target = hop.headers.value(HttpHeaders.locationHeader);
      await hop.listen((_) {}).cancel();
      if (target != null) {
        final bv = extractBvOrAvId(target);
        if (bv != null) return bv;
      }
      if (hop.isRedirect && target != null) {
        final next = uri.resolve(target);
        if (next.scheme != 'https' ||
            !(next.host == 'bilibili.com' ||
                next.host.endsWith('.bilibili.com') ||
                hosts
                    .any((h) => next.host == h || next.host.endsWith('.$h')))) {
          return null;
        }
      }
      final req =
          await _httpClient.getUrl(uri).timeout(const Duration(seconds: 5));
      req.headers.set('User-Agent', kBiliUserAgent);
      req.headers.set('Referer', 'https://www.bilibili.com/');
      // Let HttpClient follow redirects automatically; we inspect redirects
      final res = await req.close().timeout(const Duration(seconds: 5));
      // Drain body to reuse connection
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5))
          .catchError((_) => '');
      // Check redirect history
      if (res.redirects.isNotEmpty) {
        final bv = extractBvOrAvId(res.redirects.last.location.toString());
        if (bv != null) return bv;
      }
      // Some short links return 200 with HTML containing canonical BV
      final bvInBody = _bvId.firstMatch(body);
      if (bvInBody != null) return 'BV${bvInBody.group(1)}';
      // Fallback: Location header even when not in redirects list
      final loc = res.headers.value(HttpHeaders.locationHeader);
      if (loc != null) {
        final bv = extractBvOrAvId(loc);
        if (bv != null) return bv;
      }
    } catch (e) {
      debugPrint('Resolve short link failed: $e');
    }
    return null;
  }

  /// One of the video endpoints (`view`, `view/detail/tag`). The plain form
  /// is tried first; when risk control refuses it (412) the WBI-signed form,
  /// sent as an identified device, usually still answers.
  static Future<String?> _viewBody(
      String path, String paramKey, String id) async {
    final plain = await _httpGet('$_baseUrl/x/web-interface/$path'
        '?$paramKey=${Uri.encodeQueryComponent(id)}');
    if (plain != null && !isRiskControlled(plain)) return plain;
    try {
      final cookies = await FingerprintService.getCookieString();
      final signed = await WbiSigner.signParams({
        paramKey: id,
        ...FingerprintService.getDmImgParams(),
      });
      final query = signed.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value.toString())}')
          .join('&');
      return await _httpGet(
        '$_baseUrl/x/web-interface/wbi/$path?$query',
        cookies: cookies,
      );
    } catch (e) {
      debugPrint('Signed $path request failed: $e');
      return null;
    }
  }

  /// Music zones whose name says the video is a rendition. Bilibili no
  /// longer sends zone names, only these ids.
  static const Map<int, String> _renditionZones = {31: '翻唱', 59: '演奏'};

  // Fetch Video Info by BV or AV ID.
  //
  // Contract: transport/API failure throws [BiliApiException]; an
  // invalid or unavailable video resolves to [] (a successful "no match").
  static Future<List<Track>> fetchVideoInfo(String idInput) async {
    final id = extractBvOrAvId(idInput) ?? idInput.trim();
    final paramKey = id.toLowerCase().startsWith('bv') ? 'bvid' : 'aid';
    final body = await _viewBody('view', paramKey, id);
    if (body == null) {
      throw const BiliApiException('video info request failed');
    }
    final dynamic json;
    try {
      json = jsonDecode(body);
    } catch (e) {
      throw BiliApiException('video info parse failed: $e');
    }
    try {
      return _tracksOfView(json);
    } catch (e) {
      // An answer in a shape this build does not know is a failed lookup,
      // not a crash and not "no such video".
      throw BiliApiException('video info in an unexpected shape: $e');
    }
  }

  static List<Track> _tracksOfView(dynamic json) {
    if (json is! Map) throw const FormatException('not an object');
    if (json['code'] == 0 && json['data'] != null) {
      final data = json['data'];
      final bvid = data['bvid'] as String;
      final title = data['title'] as String;
      var pic = (data['pic'] as String? ?? '').replaceAll('http:', 'https:');
      if (pic.startsWith('//')) pic = 'https:$pic';
      final owner = data['owner'] ?? {};
      final uploader = owner['name'] as String? ?? '未知UP主';
      final totalDuration = data['duration'] as int? ?? 0;
      final pages = data['pages'] as List? ?? [];

      if (pages.isEmpty) {
        return [
          Track(
            id: '${bvid}_p1',
            bvid: bvid,
            cid: data['cid'] as int? ?? 0,
            title: title,
            rawTitle: title,
            uploader: uploader,
            coverUrl: pic,
            duration: totalDuration,
          )
        ];
      }

      return pages.map((p) {
        final cid = p['cid'] as int;
        final pageNo = p['page'] as int;
        final partTitle = p['part'] as String? ?? title;
        final pageDuration = p['duration'] as int? ?? totalDuration;

        return Track(
          id: '${bvid}_p$pageNo',
          bvid: bvid,
          cid: cid,
          title: pages.length > 1 ? '$title - P$pageNo: $partTitle' : title,
          rawTitle: title,
          uploader: uploader,
          coverUrl: pic,
          duration: pageDuration,
        );
      }).toList();
    }

    return [];
  }

  static final Map<String, VideoHints> _hintsMemo = {};

  /// The tags, description, zone and uploader of [bvid], and the music
  /// Bilibili recognised in the part [cid] — evidence for naming the song
  /// when the title alone does not settle it. Never throws: offline (or
  /// refused) is [VideoHints.none], and is asked again next time.
  static Future<VideoHints> fetchVideoHints(String bvid, {int cid = 0}) async {
    if (bvid.isEmpty) return VideoHints.none;
    final memoKey = '$bvid/$cid';
    final cached = _hintsMemo[memoKey];
    if (cached != null) return cached;

    final bodies = await Future.wait([
      _viewBody('view', 'bvid', bvid),
      _httpGet('$_baseUrl/x/web-interface/view/detail/tag?bvid=$bvid'),
    ]);
    final view = _dataOf(bodies[0]);
    final tags = _dataOf(bodies[1]);
    if (view is! Map && tags is! List) return VideoHints.none;

    // A track that came from a search carries no cid; it is the first part.
    final part = cid != 0
        ? cid
        : view is Map && view['cid'] is int
            ? view['cid'] as int
            : 0;
    final music = part == 0 ? null : await _recognisedMusic(bvid, part);

    final hints = VideoHints(
      tags: [
        // Topic tags name a campaign (音乐分享官), not the video's content.
        if (tags is List)
          for (final t in tags)
            if (t is Map && t['tag_type'] != 'topic' && t['tag_name'] is String)
              (t['tag_name'] as String).trim(),
      ],
      description: view is Map ? '${view['desc'] ?? ''}'.trim() : '',
      zone: view is Map
          ? '${view['tname'] ?? ''} ${view['tname_v2'] ?? ''} '
                  '${_renditionZones[view['tid']] ?? ''}'
              .trim()
          : '',
      owner: view is Map && view['owner'] is Map
          ? '${view['owner']['name'] ?? ''}'.trim()
          : '',
      musicTitle: music?.title ?? '',
      musicArtists: music?.artists ?? const [],
      cover: view is Map && view['pic'] is String
          ? (view['pic'] as String).replaceFirst('http:', 'https:')
          : '',
      complete: view is Map && tags is List && music != null,
    );
    // Half an answer (one request failed) is used but not kept.
    if (hints.complete) {
      if (_hintsMemo.length > 300) _hintsMemo.clear();
      _hintsMemo[memoKey] = hints;
    }
    return hints;
  }

  /// The `data` of a code-0 answer, or null.
  static Object? _dataOf(String? body) {
    if (body == null) return null;
    try {
      final json = jsonDecode(body);
      return json is Map && json['code'] == 0 ? json['data'] : null;
    } catch (_) {
      return null;
    }
  }

  /// The song Bilibili's own recognition found in one part of a video — the
  /// "发现《…》" card under its player. An empty title when it found none;
  /// null when it could not be asked.
  static Future<({String title, List<String> artists})?> _recognisedMusic(
      String bvid, int cid) async {
    const nothing = (title: '', artists: <String>[]);
    try {
      final cookies = await FingerprintService.getCookieString();
      final signed = await WbiSigner.signParams({'bvid': bvid, 'cid': cid});
      final query = signed.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value.toString())}')
          .join('&');
      final player = _dataOf(await _httpGet(
        '$_baseUrl/x/player/wbi/v2?$query',
        cookies: cookies,
      ));
      Object? id;
      if (player is Map) {
        final card = player['bgm_info'];
        id = card is Map ? card['music_id'] : null;
      } else {
        // The signed player request is the first thing risk control
        // refuses. The video's detail page lists the same card among its
        // tags, and answers when the player does not.
        final detail = _dataOf(await _viewBody('view/detail', 'bvid', bvid));
        if (detail is! Map) return null;
        id = recognisedMusicIdIn(detail, cid);
        if (id == null) return null;
      }
      if (id is! String || id.isEmpty) return nothing;

      final detail = _dataOf(await _httpGet(
        '$_baseUrl/x/copyright-music-publicity/bgm/detail'
        '?music_id=${Uri.encodeQueryComponent(id)}',
        cookies: cookies,
      ));
      if (detail is! Map) return null;
      return parseRecognisedMusic(detail);
    } catch (e) {
      debugPrint('Recognised music lookup failed: $e');
      return null;
    }
  }

  /// The id of the music a `view/detail` answer lists for the part [cid]:
  /// empty when it lists none for that part, null when the answer is not
  /// in a shape to tell.
  @visibleForTesting
  static String? recognisedMusicIdIn(Map detail, int cid) {
    final tags = detail['Tags'];
    if (tags is! List) return null;
    for (final t in tags) {
      if (t is! Map || t['tag_type'] != 'bgm') continue;
      final id = t['music_id'];
      if (id is! String || id.isEmpty) continue;
      // The card belongs to one part; its link says which.
      final part =
          RegExp(r'[?&]cid=(\d+)').firstMatch('${t['jump_url'] ?? ''}');
      if (part == null || part.group(1) == '$cid') return id;
    }
    return '';
  }

  /// Reads a `bgm/detail` answer: the title, and the artists it lists as
  /// one string ("五月天,周深", "宋雨琦/五月天").
  @visibleForTesting
  static ({String title, List<String> artists}) parseRecognisedMusic(
      Map detail) {
    final title = detail['music_title'];
    final artists = detail['origin_artist'];
    return (
      title: title is String ? title.trim() : '',
      artists: [
        if (artists is String)
          for (final name in artists.split(RegExp(r'[,，/／、]')))
            if (name.trim().isNotEmpty) name.trim(),
      ],
    );
  }

  // Fetch audio stream URL (prefers standard MP4/M4A container for native MediaPlayer compatibility)
  ///
  /// The result also carries `loudness` (integrated LUFS, as a string) when
  /// Bilibili has measured the video — the same figure its own player uses
  /// for 音量均衡.
  static Future<Map<String, String>?> fetchAudioStream(
      String bvid, int cid) async {
    try {
      // A search result is the video; what downloads is its first part.
      // When there are several, the song is that part: its name, its length.
      var part = const <String, String>{};
      if (cid == 0) {
        final infoList = await fetchVideoInfo(bvid);
        if (infoList.isNotEmpty) {
          cid = infoList.first.cid;
          if (infoList.length > 1) {
            part = {
              'partTitle': infoList.first.title,
              'partDuration': '${infoList.first.duration}',
            };
          }
        }
      }
      if (cid == 0) return null;

      // fnval=16 requests DASH; the response still carries a plain `durl`
      // MP4/M4A stream for most videos, which we prefer for native playback.
      final rawParams = {
        'bvid': bvid,
        'cid': cid,
        'fnval': 16,
        'fnver': 0,
        'fourk': 1,
        // Asks for the `volume` block (EBU R128 measurements).
        'voice_balance': 1,
      };

      final signed = await WbiSigner.signParams(rawParams);
      final queryStr = signed.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value.toString())}')
          .join('&');
      final url = '$_baseUrl/x/player/wbi/playurl?$queryStr';

      final body = await _httpGet(url);
      if (body != null) {
        final json = jsonDecode(body);
        final stream = parseAudioStream(json);
        if (stream != null) return {...stream, ...part};
        final refusal = unavailableReason(json);
        if (refusal != null) return {'unavailable': refusal};
      }
    } catch (e) {
      debugPrint('Failed to fetch audio stream: $e');
    }

    return null;
  }

  /// Bilibili's codes for "too many requests" and its own trouble: worth
  /// asking again in a while, unlike every other refusal.
  static const Set<int> _transientCodes = {-352, -412, -500, -503, -509, -799};

  /// Why Bilibili will not give this video's audio to anyone (deleted,
  /// hidden, members only, another region), when that is what it said;
  /// null for a request that merely failed.
  @visibleForTesting
  static String? unavailableReason(dynamic json) {
    if (json is! Map) return null;
    final code = json['code'];
    if (code is! int || code == 0 || _transientCodes.contains(code)) {
      return null;
    }
    final message = json['message'];
    return message is String && message.isNotEmpty && message != '$code'
        ? message
        : '视频无法播放';
  }

  /// Reads a `playurl` answer: the stream to download, and Bilibili's
  /// loudness measurement when it sent one. Null when it names no stream.
  @visibleForTesting
  static Map<String, String>? parseAudioStream(dynamic json) {
    if (json is! Map || json['code'] != 0 || json['data'] is! Map) return null;
    final data = json['data'] as Map;
    final volume = data['volume'];
    final measured = volume is Map ? volume['measured_i'] : null;
    final loudness = <String, String>{
      if (measured is num && measured < 0) 'loudness': '$measured',
    };

    // The plain stream (standard m4a/mp4 container) is preferred.
    final durl = data['durl'];
    if (durl is List && durl.isNotEmpty && durl.first is Map) {
      final url = (durl.first as Map)['url'];
      if (url is String && url.isNotEmpty) {
        return {
          'url': url.replaceAll('http:', 'https:'),
          'quality': '高品质 AAC/M4A',
          ...loudness,
        };
      }
    }

    // Otherwise the best DASH audio track.
    final dash = data['dash'];
    final audio = dash is Map ? dash['audio'] : null;
    if (audio is List && audio.isNotEmpty) {
      int bandwidth(dynamic a) => a is Map && a['bandwidth'] is num
          ? (a['bandwidth'] as num).toInt()
          : 0;
      final sorted = [...audio]..sort((a, b) => bandwidth(b) - bandwidth(a));
      final best = sorted.first;
      if (best is Map) {
        String? url;
        for (final key in ['baseUrl', 'base_url']) {
          final v = best[key];
          if (v is String && v.isNotEmpty) url ??= v;
        }
        // backupUrl is a list.
        final backup = best['backupUrl'] ?? best['backup_url'];
        if (url == null && backup is List && backup.isNotEmpty) {
          final v = backup.first;
          if (v is String && v.isNotEmpty) url = v;
        }
        if (url != null) {
          return {
            'url': url.replaceAll('http:', 'https:'),
            'quality': '320k DASH',
            ...loudness,
          };
        }
      }
    }
    return null;
  }

  /// Integrated loudness (LUFS) of one video part, or null when Bilibili has
  /// no measurement or the request failed.
  static Future<double?> fetchLoudness(String bvid, int cid) async {
    final info = await fetchAudioStream(bvid, cid);
    return double.tryParse(info?['loudness'] ?? '');
  }

  // Search Bilibili catalog for ANY query.
  //
  // Contract: a successful request with no matches resolves to []. Every
  // applicable request/fallback attempt failing throws [BiliApiException].
  static final Set<String> _unfilteredQueries = {};

  static Future<List<Track>> search(String query, {int page = 1}) async {
    if (query.trim().isEmpty) return [];

    // A BV number or a link never goes through the keyword search: asking for
    // something by id means you want exactly it, whatever zone it lives in.
    // When there is no such video the text was not an id after all ("AV1
    // 编码"), and is searched for like any other.
    final directId = extractBvOrAvId(query);
    if (directId != null) {
      // One video is one page: there is nothing further to scroll to.
      if (page > 1) return [];
      final direct = await fetchVideoInfo(directId);
      if (direct.isNotEmpty) return direct;
    }
    // Handle Bilibili short share links (b23.tv / bili2233.cn) that hide the BV
    // behind a redirect. The pasted share text is often `【标题】 https://b23.tv/xxx`
    if (query.contains('b23.tv') ||
        query.contains('bili2233.cn') ||
        query.contains('acg.tv')) {
      try {
        final resolved =
            await _resolveShortLink(query).timeout(const Duration(seconds: 6));
        if (resolved != null) {
          final viaResolved = await fetchVideoInfo(resolved);
          if (viaResolved.isNotEmpty) return viaResolved;
        }
      } catch (e) {
        debugPrint('Short link resolve error: $e');
      }
    }

    // Music zone first. If that comes back empty — no matches there, or an API
    // that quietly rejects the filter — fall back to an unfiltered search
    // rather than telling the user their song does not exist. A transport
    // failure is not an empty result: retry unfiltered once (the other
    // endpoint may still answer), and only throw if that fails too.
    // Later pages stay in whichever of the two the first page came from:
    // page 3 of the music zone is not followed by page 4 of everything.
    final key = query.trim();
    if (page > 1) {
      return _searchOnce(query,
          musicOnly: !_unfilteredQueries.contains(key), page: page);
    }
    List<Track>? musical;
    try {
      musical = await _searchOnce(query, musicOnly: true, page: page);
    } catch (e) {
      debugPrint('Music-zone search failed, trying unfiltered: $e');
    }
    if (musical != null && musical.isNotEmpty) {
      _unfilteredQueries.remove(key);
      return musical;
    }
    if (_unfilteredQueries.length > 200) _unfilteredQueries.clear();
    _unfilteredQueries.add(key);
    return _searchOnce(query, musicOnly: false, page: page);
  }

  /// A single search attempt: WBI-signed primary plus the plain fallback API.
  /// Throws [BiliApiException] when no usable response arrived at all; a
  /// usable response with no matches resolves to [].
  static Future<List<Track>> _searchOnce(String query,
      {required bool musicOnly, int page = 1}) async {
    final String? body;
    try {
      // Obtain buvid3/buvid4 device fingerprint (required by B站 anti-bot)
      final cookieStr = await FingerprintService.getCookieString();

      // Get dm_img risk-control simulation parameters
      final dmParams = FingerprintService.getDmImgParams();

      final rawParams = <String, dynamic>{
        'search_type': 'video',
        'keyword': query.trim(),
        'page': page,
        'order': 'totalrank',
        // This is a music player: a keyword search that returns lectures,
        // gameplay and news is noise.
        if (musicOnly) 'tids': _musicZoneId,
        // dm_img 风控参数 — 缺少会导致 -352 / 412
        ...dmParams,
      };

      final signed = await WbiSigner.signParams(rawParams);
      final queryStr = signed.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value.toString())}')
          .join('&');
      final searchUrl = '$_baseUrl/x/web-interface/wbi/search/type?$queryStr';

      var primary = await _httpGet(searchUrl, cookies: cookieStr);
      // -352 / 412 are B站 risk-control codes; check them on the decoded JSON
      // rather than string-matching (which breaks on whitespace variations).
      if (isRiskControlled(primary)) {
        primary = null;
      }
      if (primary != null) {
        body = primary;
      } else {
        // Fallback: standard web search API
        final fallbackUrl = '$_baseUrl/x/web-interface/search/type'
            '?search_type=video'
            '${musicOnly ? "&tids=$_musicZoneId" : ""}'
            '&page=$page'
            '&keyword=${Uri.encodeComponent(query.trim())}';
        body = await _httpGet(fallbackUrl, cookies: cookieStr);
      }
    } catch (e) {
      throw BiliApiException('search request failed: $e');
    }
    if (body == null) {
      throw const BiliApiException('all search attempts failed');
    }
    // A refusal carries no results; reading it as "nothing found" told the
    // listener their song does not exist.
    if (isRiskControlled(body)) {
      throw const BiliApiException('search refused by risk control');
    }

    final dynamic json;
    try {
      json = jsonDecode(body);
    } catch (e) {
      throw BiliApiException('search parse failed: $e');
    }

    if (json is! Map) {
      throw const BiliApiException('search answer in an unexpected shape');
    }
    // Any other refusal (rate limit, bad signature, server error) is a
    // failure too, not an empty result.
    final code = json['code'];
    if (code is int && code != 0) {
      throw BiliApiException('search answered code $code');
    }
    final data = json['data'];
    final dynamic rawResult = data is Map ? data['result'] : null;
    List? resultsList;
    if (rawResult is List) {
      resultsList = rawResult;
    } else if (rawResult is Map && rawResult['video'] is List) {
      resultsList = rawResult['video'] as List;
    }

    if (resultsList != null) {
      final tracks = <Track>[];

      for (final item in resultsList) {
        if (item is! Map) continue;
        final bvid = item['bvid'];
        if (bvid is! String || bvid.isEmpty) continue;

        final rawTitle = item['title'] as String? ?? '';
        final cleanTitle = unescapeHtml(rawTitle.replaceAll(_htmlTagRegex, ''));
        final author = unescapeHtml(item['author'] as String? ?? 'UP主');
        final pic =
            (item['pic'] as String? ?? '').replaceAll('http:', 'https:');

        int durationSec = 0;
        final durRaw = item['duration'];
        if (durRaw is String) {
          final parts =
              durRaw.split(':').map((e) => int.tryParse(e) ?? 0).toList();
          if (parts.length == 2) {
            durationSec = parts[0] * 60 + parts[1];
          } else if (parts.length == 3) {
            durationSec = parts[0] * 3600 + parts[1] * 60 + parts[2];
          }
        } else if (durRaw is int) {
          durationSec = durRaw;
        }

        // Search results are always the video's first part, and the search
        // API does not return a cid — hence the page-based id: keying on
        // cid would have produced `bvid_0` here and `bvid_<cid>` for the
        // same video opened by BV number, i.e. two entries for one song
        // with separate download state.
        tracks.add(Track(
          id: '${bvid}_p1',
          bvid: bvid,
          cid: item['cid'] as int? ?? 0,
          title: cleanTitle,
          rawTitle: cleanTitle,
          uploader: author,
          coverUrl: pic.startsWith('//') ? 'https:$pic' : pic,
          duration: durationSec,
        ));
      }

      return tracks;
    }
    return [];
  }

  /// Music sub-zones whose videos are songs: original, cover, VOCALOID,
  /// performance, MV, live, general and electronic. Reviews, rankings and
  /// lessons (乐评盘点, 音乐教学) are about songs, not songs.
  static const Set<int> songZones = {28, 31, 30, 59, 193, 29, 130, 194};

  /// What Bilibili lists beside [bvid] (相关推荐): the videos people who
  /// watch it go on to watch. Only songs ([songZones]) are kept, with their
  /// play counts. Throws [BiliApiException] when it could not be asked.
  static Future<List<({Track track, int views})>> related(String bvid) async {
    final body = await _viewBody('archive/related', 'bvid', bvid);
    if (body == null || isRiskControlled(body)) {
      throw BiliApiException('related to $bvid: no answer');
    }
    return parseRelated(body);
  }

  @visibleForTesting
  static List<({Track track, int views})> parseRelated(String body) {
    final data = _dataOf(body);
    if (data is! List) return const [];
    final out = <({Track track, int views})>[];
    for (final item in data) {
      if (item is! Map) continue;
      final bvid = item['bvid'];
      if (bvid is! String || bvid.isEmpty) continue;
      // A video without a zone id is let through (title and length are
      // still checked by the caller): should Bilibili stop sending the old
      // ids, recommendations thin out rather than vanish.
      final tid = item['tid'];
      if (tid is int && tid != 0 && !songZones.contains(tid)) continue;
      final title = unescapeHtml('${item['title'] ?? ''}').trim();
      final owner = item['owner'];
      final pic = '${item['pic'] ?? ''}'.replaceFirst('http:', 'https:');
      final stat = item['stat'];
      out.add((
        track: Track(
          id: '${bvid}_p1',
          bvid: bvid,
          cid: item['cid'] is int ? item['cid'] as int : 0,
          title: title,
          rawTitle: title,
          uploader: owner is Map ? '${owner['name'] ?? ''}'.trim() : '',
          coverUrl: pic.startsWith('//') ? 'https:$pic' : pic,
          duration: item['duration'] is int ? item['duration'] as int : 0,
        ),
        views: stat is Map && stat['view'] is int ? stat['view'] as int : 0,
      ));
    }
    return out;
  }

  /// True when the response is B站's risk-control rejection: code -352 or
  /// 412, or — the quiet form — code 0 with a `v_voucher` to solve a captcha
  /// with and no results. Either should trigger the fallback API.
  @visibleForTesting
  static bool isRiskControlled(String? body) {
    if (body == null) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final code = decoded['code'];
        if (code == -352 || code == 412) return true;
        final data = decoded['data'];
        return data is Map && data['v_voucher'] != null;
      }
    } catch (_) {
      // Not JSON at all — not a clean rejection, treat as a normal response.
    }
    return false;
  }
}
