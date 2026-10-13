import 'dart:convert';
import 'dart:io';

import 'song_model.dart';

void main(List<String> args) {
  final dir = args[0];
  final model = SongModel.load(File('$dir/song_model.bin').readAsBytesSync(), File('$dir/song_singers.txt').readAsStringSync());
  final ref = (jsonDecode(File('$dir/reference.json').readAsStringSync()) as List).cast<Map>();
  var same = 0;
  final watch = Stopwatch()..start();
  for (final r in ref) {
    final music = r['music'] as Map?;
    final g = model.guess(
      title: r['title'] as String,
      uploader: r['up'] as String,
      tags: List<String>.from(r['tags'] as List),
      musicTitle: music == null ? '' : (music['t'] as String? ?? ''),
      musicArtists: music == null ? const [] : List<String>.from(music['a'] as List? ?? const []),
      durationSeconds: r['dur'] as int,
    );
    final want = r['answer'] as Map?;
    final got = g == null ? null : {'song': g.song, 'performers': g.performers};
    if (jsonEncode(want) == jsonEncode(got)) {
      same++;
    } else if (same + 12 > ref.indexOf(r)) {
      print('${r['title']}\n  python ${jsonEncode(want)}\n  dart   ${jsonEncode(got)}');
    }
  }
  print('$same/${ref.length} identical, ${watch.elapsedMilliseconds ~/ ref.length} ms per video');
}
