import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/lyrics.dart';
import 'package:bilibeats/services/lyric_library.dart';
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:bilibeats/theme/app_theme.dart';
import 'package:bilibeats/widgets/lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Kugou and QQ Music as lyric sources, and lyrics timed word by word.
void main() {
  const krc = '﻿[id:\$00000000]\n'
      '[ar:周深]\n'
      '[ti:大鱼]\n'
      '[language:eyJjb250ZW50IjpbeyJ0eXBlIjoxLCJseXJpY0NvbnRlbnQiOltbIiJdLFsiVGhlIHdhdmVzIl1dfV19]\n'
      '[482,609]<0,506,0>周<506,0,0>深 <506,52,0>- <558,51,0>大<609,0,0>鱼\n'
      '[43410,5623]<0,252,0>海<252,405,0>浪<657,404,0>无<1061,405,0>声\n';

  /// As Kugou stores it: magic, then XOR over deflate.
  List<int> packed(String text) {
    const key = [
      0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, //
      0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
    ];
    final deflated = zlib.encode(utf8.encode(text));
    return [
      ...'krc1'.codeUnits,
      for (var i = 0; i < deflated.length; i++) deflated[i] ^ key[i % 16],
    ];
  }

  tearDown(() {
    LyricLibrary.transport = null;
    LyricLibrary.forget();
  });

  test('a Kugou lyric file is read word by word, with its translation', () {
    final lines = LyricLibrary.parseKrc(LyricLibrary.decodeKrc(packed(krc)));
    expect(lines.map((l) => l.text), ['周深 - 大鱼', '海浪无声']);
    final second = lines[1];
    expect(second.time, 43.41);
    expect(second.translation, 'The waves');
    expect(second.words!.map((w) => w.text).join(), '海浪无声');
    expect(second.words![1].start, closeTo(43.662, 1e-9));
    expect(second.words![1].end, closeTo(44.067, 1e-9));
    expect(lines.first.translation, isNull);
  });

  test('word timing survives being saved', () {
    final line = LyricLibrary.parseKrc(krc)[1];
    final back = LyricLine.fromMap(
        jsonDecode(jsonEncode(line.toMap())) as Map<String, dynamic>);
    expect(back.words!.length, 4);
    expect(back.words![2].text, '无');
    expect(back.words![2].start, closeTo(44.067, 1e-9));
    // Lyrics saved by earlier versions carry none.
    expect(LyricLine.fromMap(const {'time': 1.0, 'text': 'a'}).words, isNull);
  });

  group('the recording asked for', () {
    String kugou(List<Map<String, Object>> songs) => jsonEncode({
          'status': 1,
          'data': {'info': songs},
        });

    Map<String, Object> listed(
            String name, String singer, int seconds, String hash) =>
        {
          'songname': name,
          'singername': singer,
          'duration': seconds,
          'hash': hash,
        };

    void serve(String search, {Set<String> withoutLyrics = const {}}) {
      LyricLibrary.transport = (url, body, fetch) async {
        if (url.contains('/search/song')) return search;
        final hash = RegExp(r'hash=(\w+)').firstMatch(url)?.group(1);
        if (url.contains('krcs.kugou.com')) {
          return jsonEncode({
            'candidates': [
              if (!withoutLyrics.contains(hash)) {'id': hash, 'accesskey': 'k'},
            ],
          });
        }
        if (url.contains('lyrics.kugou.com')) {
          final id = RegExp(r'id=(\w+)').firstMatch(url)!.group(1)!;
          return jsonEncode({
            'content': base64.encode(packed('[1000,500]<0,500,0>$id\n'
                '[2000,500]<0,500,0>second\n')),
          });
        }
        return null;
      };
    }

    test('is the one by that singer, nearest the video in length', () async {
      serve(kugou([
        listed('大鱼', '双笙', 300, 'other'),
        listed('大鱼', '周深', 313, 'studio'),
        listed('大鱼 (Live)', '周深、郭沁', 300, 'live'),
        listed('大鱼海棠', '周深', 301, 'different'),
      ]));
      final found = await LyricsEngine.fetchFromLibrary('kugou', '大鱼',
          artist: '周深', durationSeconds: 301);
      expect(found!.source, 'kugou');
      expect(found.lines.first.text, 'live');
      expect(found.artist, '周深, 郭沁');
      expect(found.wordTimed, isTrue);
    });

    test('falls to the next recording when the nearest has no lyrics',
        () async {
      serve(
        kugou([
          listed('大鱼', '周深', 313, 'studio'),
          listed('大鱼 (Live)', '周深', 300, 'live'),
        ]),
        withoutLyrics: {'live'},
      );
      final found = await LyricsEngine.fetchFromLibrary('kugou', '大鱼',
          artist: '周深', durationSeconds: 301);
      expect(found!.lines.first.text, 'studio');
    });

    test('is not somebody else\'s, however well the title fits', () async {
      serve(kugou([listed('大鱼', '双笙', 300, 'other')]));
      expect(
          await LyricsEngine.fetchFromLibrary('kugou', '大鱼',
              artist: '周深', durationSeconds: 300),
          isNull);
    });
  });

  testWidgets('the line being sung fills word by word', (tester) async {
    final position = ValueNotifier(const Duration(milliseconds: 44100));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 500,
          child: LyricsView(
            lyrics: Lyrics(source: 'kugou', lines: LyricLibrary.parseKrc(krc)),
            position: position,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    Map<String, Color?> shades() {
      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere((r) => r.text.toPlainText() == '海浪无声');
      final out = <String, Color?>{};
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          out[span.text!] = span.style?.color;
        }
        return true;
      });
      return out;
    }

    // 44.1 s: 海 (43.41) and 浪 (43.66) have begun, 无 (44.07) only just.
    expect(shades(), {
      '海': null,
      '浪': null,
      '无': null,
      '声': AppColors.white45,
    });
    position.value = const Duration(milliseconds: 43500);
    await tester.pump();
    expect(shades()['浪'], AppColors.white45);
    expect(shades()['海'], isNull);
  });
}
