import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/services/song_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart reader against what the trained model reads in Python
/// (tool/song_model/export_plm.py writes both the weights and the answers).
///
///   READER_DIR=out flutter test test/tools/song_reader_parity.dart
void main() {
  test('reads what the Python model reads', () {
    final dir = Platform.environment['READER_DIR'];
    if (dir == null) {
      markTestSkipped('READER_DIR not set');
      return;
    }
    final reader = SongReader.load(
      File('$dir/song_model.bin').readAsBytesSync(),
      File('$dir/song_vocab.txt').readAsStringSync(),
      File('$dir/song_singers.txt').readAsStringSync(),
    );
    final videos =
        (jsonDecode(File('$dir/reference.json').readAsStringSync()) as List)
            .cast<Map>();
    final limit = int.tryParse(Platform.environment['READER_LIMIT'] ?? '') ??
        videos.length;
    var same = 0, close = 0, n = 0;
    final watch = Stopwatch()..start();
    final wrong = <String>[];
    for (final v in videos.take(limit)) {
      n++;
      final music = v['music'] as Map?;
      final r = reader.read(
        title: v['title'] as String,
        uploader: v['up'] as String,
        tags: List<String>.from(v['tags'] as List),
        musicTitle: music == null ? '' : music['t'] as String? ?? '',
        musicArtists: List<String>.from(music?['a'] as List? ?? const []),
        durationSeconds: v['dur'] as int,
      );
      final want = v['answer'] as Map?;
      final got =
          r.song == null ? null : {'song': r.song, 'performers': r.performers};
      if (jsonEncode(want) == jsonEncode(got)) {
        same++;
      } else if (wrong.length < 12) {
        wrong.add('${v['title']}\n  python ${jsonEncode(want)}'
            '\n  dart   ${jsonEncode(got)}');
      }
      if ((r.pNone - (v['pNone'] as num)).abs() < 0.02 &&
          (r.pOwn - (v['pOwn'] as num)).abs() < 0.02 &&
          (r.confidence - (v['conf'] as num? ?? r.confidence)).abs() < 0.03) {
        close++;
      }
    }
    // ignore: avoid_print
    print('$same/$n identical answers, $close/$n probabilities within 0.02, '
        '${watch.elapsedMilliseconds ~/ n} ms per video\n${wrong.join('\n')}');
    expect(same, n);
    expect(close, n);
  }, timeout: const Timeout(Duration(minutes: 30)));
}
