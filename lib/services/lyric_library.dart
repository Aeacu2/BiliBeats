import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/lyrics.dart';
import 'bili_http.dart';

/// A recording as a music service lists it.
@immutable
class LibrarySong {
  /// `kugou` or `qq`.
  final String source;
  final String title;
  final List<String> artists;
  final int seconds;
  final String album;

  /// What the service's lyric request wants: Kugou's file hash, QQ's mid.
  final String key;

  const LibrarySong({
    required this.source,
    required this.title,
    required this.artists,
    required this.seconds,
    required this.key,
    this.album = '',
  });

  @override
  String toString() => 'LibrarySong($source, $title, $artists, ${seconds}s)';
}

/// Kugou and QQ Music: what they list under a search, and their lyrics.
///
/// Two more catalogues beside NetEase. They list recordings NetEase has no
/// rights to, Kugou times its lyrics word by word, and a song two of them
/// list under the same singer is more surely that singer's than one
/// catalogue's word for it.
class LyricLibrary {
  LyricLibrary._();

  static final HttpClient _client = biliHttpClient();
  static const Duration _timeout = Duration(seconds: 10);

  /// Requests that got no usable answer (see LyricsEngine.httpFailures).
  static int failures = 0;

  /// Stands in for the network in tests and in tools that replay a labelled
  /// set: given the request and the real fetch, it may answer itself.
  @visibleForTesting
  static Future<String?> Function(
      String url, String? body, Future<String?> Function() fetch)? transport;

  static Future<String?> _request(String url,
      {String? body, Map<String, String> headers = const {}}) {
    Future<String?> fetch() => _fetch(url, body: body, headers: headers);
    final via = transport;
    return via == null ? fetch() : via(url, body, fetch);
  }

  static Future<String?> _fetch(String url,
      {String? body, required Map<String, String> headers}) async {
    try {
      final uri = Uri.parse(url);
      final req =
          await (body == null ? _client.getUrl(uri) : _client.postUrl(uri))
              .timeout(_timeout);
      req.headers.set('User-Agent', kBiliUserAgent);
      headers.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(body));
      }
      final res = await req.close().timeout(_timeout, onTimeout: () {
        req.abort();
        throw TimeoutException('library request timed out');
      });
      if (res.statusCode == 200) {
        return await res.transform(utf8.decoder).join().timeout(_timeout);
      }
      await res.drain<void>();
    } catch (e) {
      debugPrint('Library HTTP error: $e');
    }
    failures++;
    return null;
  }

  static final Map<String, List<LibrarySong>> _searchMemo = {};

  @visibleForTesting
  static void forget() => _searchMemo.clear();

  /// What [source] lists for [query], best first; null when it could not be
  /// asked (which is not "it lists nothing").
  static Future<List<LibrarySong>?> search(String source, String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final memoKey = '$source\n$q';
    final known = _searchMemo[memoKey];
    if (known != null) return known;
    final found = source == 'qq' ? await _searchQq(q) : await _searchKugou(q);
    if (found != null) {
      if (_searchMemo.length > 400) _searchMemo.clear();
      _searchMemo[memoKey] = found;
    }
    return found;
  }

  static Future<List<LibrarySong>?> _searchKugou(String q) async {
    final body = await _request(
        'https://mobiles.kugou.com/api/v3/search/song?format=json&page=1'
        '&pagesize=20&showtype=1&keyword=${Uri.encodeQueryComponent(q)}');
    if (body == null) return null;
    try {
      final json = jsonDecode(body);
      final info = json['data']?['info'];
      if (info is! List) return json['status'] == 1 ? const [] : null;
      return [
        for (final s in info.whereType<Map>())
          if (s['hash'] is String && (s['hash'] as String).isNotEmpty)
            LibrarySong(
              source: 'kugou',
              title: '${s['songname'] ?? ''}'.trim(),
              artists: _names('${s['singername'] ?? ''}'),
              seconds: (s['duration'] as num?)?.toInt() ?? 0,
              album: '${s['album_name'] ?? ''}',
              key: s['hash'] as String,
            ),
      ];
    } catch (e) {
      debugPrint('Kugou search unreadable: $e');
      failures++;
      return null;
    }
  }

  static Future<List<LibrarySong>?> _searchQq(String q) async {
    final body = await _request(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      headers: const {'Referer': 'https://y.qq.com/'},
      body: jsonEncode({
        'comm': {'ct': '19', 'cv': '1859', 'uin': '0'},
        'req': {
          'method': 'DoSearchForQQMusicDesktop',
          'module': 'music.search.SearchCgiService',
          'param': {
            'grp': 1,
            'num_per_page': 15,
            'page_num': 1,
            'query': q,
            'search_type': 0,
          },
        },
      }),
    );
    if (body == null) return null;
    try {
      final req = jsonDecode(body)['req'];
      if (req is! Map || req['code'] != 0) {
        failures++;
        return null;
      }
      final list = req['data']?['body']?['song']?['list'];
      if (list is! List) return const [];
      LibrarySong? song(Map s) {
        final mid = s['mid'];
        if (mid is! String || mid.isEmpty) return null;
        return LibrarySong(
          source: 'qq',
          title: '${s['title'] ?? s['name'] ?? ''}'.trim(),
          artists: [
            for (final a in (s['singer'] as List? ?? const []).whereType<Map>())
              if (a['name'] is String && (a['name'] as String).isNotEmpty)
                a['name'] as String,
          ],
          seconds: (s['interval'] as num?)?.toInt() ?? 0,
          album: '${(s['album'] as Map?)?['name'] ?? ''}',
          key: mid,
        );
      }

      return [
        for (final s in list.whereType<Map>())
          ...[
            // Other recordings of the same song (live, remastered) are folded
            // under the first: the one sought is often among them.
            song(s),
            for (final g in (s['grp'] as List? ?? const []).whereType<Map>())
              song(g),
          ].whereType<LibrarySong>(),
      ];
    } catch (e) {
      debugPrint('QQ search unreadable: $e');
      failures++;
      return null;
    }
  }

  static List<String> _names(String joined) => [
        for (final name in joined.split(RegExp(r'[、,，/&]')))
          if (name.trim().isNotEmpty) name.trim(),
      ];

  // ---------------------------------------------------------------------------
  // Lyrics
  // ---------------------------------------------------------------------------

  /// [song]'s lyrics, or null when the service has none (or did not answer).
  /// [parseLrc] is the engine's reader for line-timed text.
  static Future<Lyrics?> lyrics(
    LibrarySong song, {
    required List<LyricLine> Function(String text) parseLrc,
  }) async {
    final lines = song.source == 'qq'
        ? await _qqLines(song, parseLrc)
        : await _kugouLines(song);
    if (lines == null || lines.isEmpty) return null;
    return Lyrics(
      source: song.source,
      title: song.title,
      artist: song.artists.join(', '),
      lines: lines,
    );
  }

  static Future<List<LyricLine>?> _kugouLines(LibrarySong song) async {
    final found = await _request(
        'https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword='
        '&duration=${song.seconds * 1000}&hash=${song.key}&album_audio_id=');
    if (found == null) return null;
    try {
      final candidates = jsonDecode(found)['candidates'];
      if (candidates is! List || candidates.isEmpty) return const [];
      final pick = candidates.first as Map;
      final file = await _request('https://lyrics.kugou.com/download?ver=1'
          '&client=pc&id=${pick['id']}&accesskey=${pick['accesskey']}'
          '&fmt=krc&charset=utf8');
      if (file == null) return null;
      final content = jsonDecode(file)['content'];
      if (content is! String || content.isEmpty) return const [];
      return parseKrc(decodeKrc(base64.decode(content)));
    } catch (e) {
      debugPrint('Kugou lyrics unreadable: $e');
      return null;
    }
  }

  static Future<List<LyricLine>?> _qqLines(
      LibrarySong song, List<LyricLine> Function(String text) parseLrc) async {
    final body = await _request(
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg'
      '?songmid=${song.key}&format=json&nobase64=1&g_tk=5381',
      headers: const {'Referer': 'https://y.qq.com/'},
    );
    if (body == null) return null;
    try {
      final json = jsonDecode(body);
      final lines = parseLrc('${json['lyric'] ?? ''}');
      final trans = parseLrc('${json['trans'] ?? ''}');
      return withTranslation(lines, trans);
    } catch (e) {
      debugPrint('QQ lyrics unreadable: $e');
      return null;
    }
  }

  /// Pairs each line with the translated line timed with it.
  static List<LyricLine> withTranslation(
      List<LyricLine> lines, List<LyricLine> trans) {
    if (trans.isEmpty) return lines;
    final out = List<LyricLine>.of(lines);
    var ti = 0;
    for (var i = 0; i < out.length; i++) {
      final line = out[i];
      while (ti < trans.length && trans[ti].time < line.time - 0.5) {
        ti++;
      }
      if (ti < trans.length && (trans[ti].time - line.time).abs() < 0.5) {
        final text = trans[ti].text.trim();
        if (text.isEmpty || text == '//') continue;
        out[i] = LyricLine(
          time: line.time,
          text: line.text,
          translation: text,
          words: line.words,
        );
      }
    }
    return out;
  }

  static const List<int> _krcKey = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, //
    0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
  ];

  /// A `.krc` file as text: four bytes of magic, then the rest XORed with a
  /// fixed key and deflated.
  @visibleForTesting
  static String decodeKrc(List<int> file) {
    if (file.length < 5) return '';
    final plain = Uint8List(file.length - 4);
    for (var i = 0; i < plain.length; i++) {
      plain[i] = file[i + 4] ^ _krcKey[i % _krcKey.length];
    }
    return utf8.decode(zlib.decode(plain), allowMalformed: true);
  }

  static final RegExp _krcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  static final RegExp _krcWord = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
  static final RegExp _krcLanguage = RegExp(r'^\[language:([^\]]*)\]');

  /// Kugou's format: `[line start,length]<word offset,length,0>word…`, in
  /// milliseconds, with translations packed in a `[language:…]` tag.
  static List<LyricLine> parseKrc(String text) {
    final lines = <LyricLine>[];
    List? translated;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.replaceFirst('﻿', '').trimRight();
      final language = _krcLanguage.firstMatch(line);
      if (language != null) {
        translated = _krcTranslation(language.group(1)!);
        continue;
      }
      final timed = _krcLine.firstMatch(line);
      if (timed == null) continue;
      final start = int.parse(timed.group(1)!);
      final words = [
        for (final w in _krcWord.allMatches(timed.group(3)!))
          if (w.group(3)!.isNotEmpty)
            LyricWord(
              start: (start + int.parse(w.group(1)!)) / 1000,
              end: (start + int.parse(w.group(1)!) + int.parse(w.group(2)!)) /
                  1000,
              text: w.group(3)!,
            ),
      ];
      final plain = words.isEmpty
          ? timed.group(3)!.trim()
          : words.map((w) => w.text).join().trim();
      // Kept even when empty: translations are matched by line number.
      lines.add(LyricLine(
        time: start / 1000,
        text: plain,
        words: words.isEmpty ? null : words,
      ));
    }
    final out = <LyricLine>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.text.isEmpty) continue;
      String? translation;
      if (translated != null && i < translated.length) {
        final row = translated[i];
        final t = row is List && row.isNotEmpty ? '${row.first}'.trim() : '';
        if (t.isNotEmpty) translation = t;
      }
      out.add(translation == null
          ? line
          : LyricLine(
              time: line.time,
              text: line.text,
              translation: translation,
              words: line.words,
            ));
    }
    return out;
  }

  /// The translated lines (type 1; type 0 is a romanisation) of a KRC
  /// `language` tag, one row per lyric line.
  static List? _krcTranslation(String tag) {
    try {
      final json = jsonDecode(utf8.decode(base64.decode(tag)));
      for (final part in (json['content'] as List? ?? const [])) {
        if (part is Map && part['type'] == 1 && part['lyricContent'] is List) {
          return part['lyricContent'] as List;
        }
      }
    } catch (_) {
      // No translation is not an error.
    }
    return null;
  }
}
