import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/track.dart';
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
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        return await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10));
      } else {
        await res.drain<void>();
        debugPrint('Bilibili HTTP ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('Bilibili HTTP fetch error: $e');
    }
    return null;
  }

  // Extract BV or AV ID from input query
  static String? extractBvOrAvId(String input) {
    final trimmed = input.trim();
    final bvMatch = RegExp(r'(BV[a-zA-Z0-9]{10})', caseSensitive: false)
        .firstMatch(trimmed);
    if (bvMatch != null) {
      final raw = bvMatch.group(1)!;
      // Normalize prefix to upper-case BV, keep the 10-char suffix case-sensitive
      if (raw.length == 12) return 'BV${raw.substring(2)}';
      return raw;
    }

    final avMatch =
        RegExp(r'av(\d+)', caseSensitive: false).firstMatch(trimmed);
    // The API's `aid` parameter expects bare digits, not the "av" prefix.
    if (avMatch != null) return avMatch.group(1);

    return null;
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
      final uri = Uri.parse(urlStr);
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
        final finalLoc = res.redirects.last.location.toString();
        final bv = extractBvOrAvId(finalLoc);
        if (bv != null) return bv;
        // Also try body regex in case redirect landed on HTML
        final bvInBody = RegExp(r'(BV[a-zA-Z0-9]{10})', caseSensitive: false)
            .firstMatch(finalLoc);
        if (bvInBody != null) return bvInBody.group(1);
        return finalLoc;
      }
      // Some short links return 200 with HTML containing canonical BV
      final bvInBody =
          RegExp(r'(BV[a-zA-Z0-9]{10})', caseSensitive: false).firstMatch(body);
      if (bvInBody != null) return bvInBody.group(1);
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

  // Fetch Video Info by BV or AV ID.
  //
  // Contract: transport/API failure throws [BiliApiException]; an
  // invalid or unavailable video resolves to [] (a successful "no match").
  static Future<List<Track>> fetchVideoInfo(String idInput) async {
    final id = extractBvOrAvId(idInput) ?? idInput.trim();
    final paramKey = id.toLowerCase().startsWith('bv') ? 'bvid' : 'aid';
    final url = '$_baseUrl/x/web-interface/view?$paramKey=$id';

    final body = await _httpGet(url);
    if (body == null) {
      throw const BiliApiException('video info request failed');
    }
    final dynamic json;
    try {
      json = jsonDecode(body);
    } catch (e) {
      throw BiliApiException('video info parse failed: $e');
    }
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

  // Fetch audio stream URL (prefers standard MP4/M4A container for native MediaPlayer compatibility)
  ///
  /// The result also carries `loudness` (integrated LUFS, as a string) when
  /// Bilibili has measured the video — the same figure its own player uses
  /// for 音量均衡.
  static Future<Map<String, String>?> fetchAudioStream(
      String bvid, int cid) async {
    try {
      if (cid == 0) {
        final infoList = await fetchVideoInfo(bvid);
        if (infoList.isNotEmpty) {
          cid = infoList.first.cid;
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
        if (json['code'] == 0 && json['data'] != null) {
          final measured = json['data']?['volume']?['measured_i'];
          final loudness = <String, String>{
            if (measured is num && measured < 0) 'loudness': '$measured',
          };
          // Check durl list (standard m4a/mp4 container)
          final durlList = json['data']?['durl'] as List? ?? [];
          if (durlList.isNotEmpty) {
            final streamUrl = durlList.first['url'] as String?;
            if (streamUrl != null && streamUrl.isNotEmpty) {
              return {
                'url': streamUrl.replaceAll('http:', 'https:'),
                'quality': '高品质 AAC/M4A',
                ...loudness,
              };
            }
          }

          // Fallback to DASH audio list if durl empty
          final audioList = json['data']?['dash']?['audio'] as List? ?? [];
          if (audioList.isNotEmpty) {
            audioList.sort((a, b) =>
                (b['bandwidth'] as int? ?? 0) - (a['bandwidth'] as int? ?? 0));
            final best = audioList.first;
            // backupUrl is a List; reading it via the ?? chain would make
            // `as String?` throw a TypeError when only the backup exists.
            String? streamUrl =
                best['baseUrl'] as String? ?? best['base_url'] as String?;
            if (streamUrl == null || streamUrl.isEmpty) {
              final backup = best['backupUrl'];
              if (backup is List && backup.isNotEmpty) {
                streamUrl = backup.first as String?;
              }
            }
            if (streamUrl != null && streamUrl.isNotEmpty) {
              return {
                'url': streamUrl.replaceAll('http:', 'https:'),
                'quality': '320k DASH',
                ...loudness,
              };
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch audio stream: $e');
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
  static Future<List<Track>> search(String query, {int page = 1}) async {
    if (query.trim().isEmpty) return [];

    // A BV number or a link never goes through the keyword search: asking for
    // something by id means you want exactly it, whatever zone it lives in.
    final directId = extractBvOrAvId(query);
    if (directId != null) {
      return await fetchVideoInfo(directId);
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
          final resolvedId = extractBvOrAvId(resolved) ?? resolved;
          // Avoid infinite loop if resolved is same as original
          if (resolvedId != query.trim()) {
            final viaResolved = await fetchVideoInfo(resolvedId);
            if (viaResolved.isNotEmpty) return viaResolved;
          }
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
    List<Track>? musical;
    try {
      musical = await _searchOnce(query, musicOnly: true, page: page);
    } catch (e) {
      debugPrint('Music-zone search failed, trying unfiltered: $e');
    }
    if (musical != null && musical.isNotEmpty) return musical;
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
      if (_riskControlled(primary)) {
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

    final dynamic json;
    try {
      json = jsonDecode(body);
    } catch (e) {
      throw BiliApiException('search parse failed: $e');
    }

    final dynamic rawResult = json['data']?['result'];
    List? resultsList;
    if (rawResult is List) {
      resultsList = rawResult;
    } else if (rawResult is Map && rawResult['video'] is List) {
      resultsList = rawResult['video'] as List;
    }

    if (resultsList != null) {
      final tracks = <Track>[];

      for (final item in resultsList) {
        final bvid = item['bvid'] as String?;
        if (bvid == null || bvid.isEmpty) continue;

        final rawTitle = item['title'] as String? ?? '';
        final cleanTitle = rawTitle.replaceAll(_htmlTagRegex, '');
        final author = item['author'] as String? ?? 'UP主';
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

  /// True when the response is B站's risk-control rejection (-352 / 412),
  /// which should trigger the unfiltered fallback search API.
  static bool _riskControlled(String? body) {
    if (body == null) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final code = decoded['code'];
        return code == -352 || code == 412;
      }
    } catch (_) {
      // Not JSON at all — not a clean rejection, treat as a normal response.
    }
    return false;
  }
}
