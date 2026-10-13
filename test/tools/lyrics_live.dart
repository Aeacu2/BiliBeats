// Run by hand: flutter test test/tools/lyrics_live.dart
//
// Asks the real services for a few songs' lyrics and prints where each came
// from and whether it is timed word by word.
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lyrics, live', () async {
    const songs = [
      ('大鱼', '周深', 313),
      ('打上花火', 'DAOKO', 289),
      ('Counting Stars', 'OneRepublic', 257),
      ('光亮', '周深', 0),
      ('起风了', '买辣椒也用券', 325),
      ('Lemon', '米津玄師', 256),
      ('Shape of You', 'Ed Sheeran', 233),
      ('若把你', 'Kirsty刘瑾睿', 197),
      ('不存在的歌名甲乙丙', '周深', 200),
    ];
    for (final (title, artist, seconds) in songs) {
      for (final source in ['kugou', 'qq']) {
        final l = await LyricsEngine.fetchFromLibrary(source, title,
            artist: artist, durationSeconds: seconds);
        // ignore: avoid_print
        print('$title / $artist  $source: ${l == null ? '-' : '${l.lines.length} lines, words=${l.wordTimed}, '
            'translated=${l.lines.any((x) => x.translation != null)}, as "${l.title}" by ${l.artist}; '
            '${l.lines.skip(3).take(1).map((x) => '${x.time} ${x.text}').join()}'}');
      }
      final auto = await LyricsEngine.autoFetchLyrics('',
          song: title, artist: artist, durationSeconds: seconds);
      // ignore: avoid_print
      print('   auto -> ${auto.source} (${auto.lines.length})');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
