import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:bilibeats/services/song_judge.dart';
import 'package:bilibeats/services/song_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SongReading _reading(
  String? song,
  List<String> performers, {
  double confidence = 0.99,
  bool own = false,
}) =>
    SongReading(
      pNone: song == null ? 0.99 : 0.01,
      pOwn: own ? 0.99 : 0.01,
      song: song,
      performers: performers,
      own: own,
      names: const {},
      confidence: confidence,
    );

const _dayu = SongIdentity(
  title: '大鱼',
  artist: '周深',
  exact: true,
  coverUrl: 'https://example.com/dayu.jpg',
);

void main() {
  String? told(SongIdentity? id) =>
      id == null ? null : '${id.title} / ${id.artist}';

  test('without the model the catalogue answers alone', () {
    expect(SongJudge.decide(catalogue: _dayu, reading: null), same(_dayu));
    expect(SongJudge.decide(catalogue: null, reading: null), isNull);
  });

  test('where both read the same, the catalogue\'s answer stands whole', () {
    final found = SongJudge.decide(
      catalogue: _dayu,
      reading: _reading('大鱼', ['周深'], confidence: 0.4),
    );
    // …artwork and all, however unsure the model was.
    expect(found, same(_dayu));
  });

  test('a name written two ways is one name', () {
    const gem = SongIdentity(title: '光年之外', artist: 'G.E.M.邓紫棋', exact: true);
    expect(
      SongJudge.decide(catalogue: gem, reading: _reading('光年之外', ['邓紫棋'])),
      same(gem),
    );
  });

  test('a video the model sees no song in is not named', () {
    // 篇章 is a song's name, and a word in "兰州 迟到的 篇章…".
    const word = SongIdentity(title: '篇章', artist: '薛之谦', exact: false);
    expect(
        SongJudge.decide(catalogue: word, reading: _reading(null, [])), isNull);
  });

  test(
      'a model sure of another singer is believed, under the catalogue\'s '
      'name for the song', () {
    // 周深《人间》: the catalogue credits 王菲, whose song it is.
    const renjian = SongIdentity(
      title: '人间',
      artist: '王菲',
      exact: true,
      coverUrl: 'https://example.com/renjian.jpg',
    );
    final found = SongJudge.decide(
      catalogue: renjian,
      reading: _reading('人间', ['周深']),
    );
    expect(told(found), '人间 / 周深');
    // Not the release itself: its artwork does not come along.
    expect(found!.exact, isFalse);
    expect(found.coverUrl, isNull);
  });

  test('a model unsure of what it reads names nothing against the catalogue',
      () {
    const renjian = SongIdentity(title: '人间', artist: '王菲', exact: true);
    expect(
      SongJudge.decide(
        catalogue: renjian,
        reading: _reading('人间', ['周深'], confidence: 0.6),
      ),
      isNull,
    );
  });

  test('a song the catalogue does not know is named by a sure model', () {
    final found = SongJudge.decide(
      catalogue: null,
      reading: _reading('たぶん', ['YOASOBI']),
    );
    expect(told(found), 'たぶん / YOASOBI');
    expect(
      SongJudge.decide(
        catalogue: null,
        reading: _reading('たぶん', ['YOASOBI'], confidence: 0.5),
      ),
      isNull,
    );
  });

  test('several performers are credited together, in the title\'s order', () {
    final found = SongJudge.decide(
      catalogue: const SongIdentity(title: '如烟', artist: '五月天', exact: true),
      reading: _reading('如烟', ['周深', '五月天']),
    );
    expect(told(found), '如烟 / 周深 & 五月天');
  });

  test('a cover by an uploader with no name is credited to nobody', () {
    expect(
      SongJudge.decide(
        catalogue: null,
        reading: _reading('借过一下', [''], own: true),
      ),
      isNull,
    );
  });
}
