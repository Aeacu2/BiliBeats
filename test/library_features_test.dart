import 'package:bilibeat/models/lyrics.dart';
import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/audio_player_handler.dart';
import 'package:bilibeat/services/lyrics_engine.dart';
import 'package:bilibeat/state/library_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_player.dart';

Track _t(String id, String title, String uploader, {String? raw}) => Track(
      id: id,
      bvid: id,
      cid: 1,
      title: title,
      rawTitle: raw ?? title,
      uploader: uploader,
      coverUrl: '',
      duration: 200,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Loudness normalization', () {
    BiliBeatAudioHandler handler() => BiliBeatAudioHandler(
          player: FakeAudioPlayer(),
          manageAudioSession: false,
        );

    test('brings loud and quiet tracks to the same target', () {
      final h = handler();
      // −14 LUFS target: a −9 track is cut 5 dB, a −20 one lifted 6 dB.
      expect(h.gainFor(-9), closeTo(-5, 0.001));
      expect(h.gainFor(-20), closeTo(6, 0.001));
      expect(h.gainFor(-14), 0);
    });

    test('never swings further than its limits', () {
      final h = handler();
      expect(h.gainFor(5), -14);
      expect(h.gainFor(-40), 8);
    });

    test('an unmeasured track is assumed typical, not left at full volume', () {
      expect(handler().gainFor(null), lessThan(0));
    });

    test('switched off, nothing is changed', () async {
      final h = handler();
      h.normalizeVolume.value = false;
      expect(h.gainFor(-6), 0);
      expect(h.gainFor(null), 0);
    });
  });

  group('Artists', () {
    test('a named song is credited to its artist field', () {
      final track = _t('1', '大鱼', '周深', raw: '【4K】周深《大鱼》现场');
      expect(LibraryController.artistOf(track), '周深');
    });

    test('an untouched download reads the artist from the video title', () {
      final track = _t('2', '【周深】大鱼 现场版', '某个UP主');
      expect(LibraryController.artistOf(track), '周深');
    });

    test('falls back to the uploader when the title names nobody', () {
      final track = _t('3', '好听的歌', '翻唱小明');
      expect(LibraryController.artistOf(track), '翻唱小明');
    });

    test('a collaboration counts for each artist', () {
      expect(
        LibraryController.artistNamesOf(_t('4', '岁月', '黄绮珊 & 周深', raw: 'x')),
        ['黄绮珊', '周深'],
      );
      expect(
        LibraryController.artistNamesOf(_t('5', '逆光', '陈楚生/周深', raw: 'x')),
        ['陈楚生', '周深'],
      );
      // A stage name with a space is one artist.
      expect(
        LibraryController.artistNamesOf(_t('6', '句号', 'G.E.M. 邓紫棋', raw: 'x')),
        ['G.E.M. 邓紫棋'],
      );
    });
  });

  group('Title parsing', () {
    Map<String, String> parse(String title, [String uploader = 'UP主']) =>
        LyricsEngine.cleanTitle(title, defaultArtist: uploader);

    test('官方MV leaves no residue on the song', () {
      final r = parse('周杰伦 - 晴天 官方MV');
      expect(r['songTitle'], '晴天');
      expect(r['artist'], '周杰伦');
    });

    test('a bracket after a lone name is the song, not the artist', () {
      final r = parse('G.E.M.邓紫棋【光年之外】MV');
      expect(r['songTitle'], '光年之外');
      expect(r['artist'], 'G.E.M.邓紫棋');
    });

    test('a leading bracket is still the artist', () {
      final r = parse('【周深】大鱼');
      expect(r['artist'], '周深');
    });

    test('Japanese quotation brackets name the song', () {
      final r = parse('YOASOBI「夜に駆ける」Official Music Video');
      expect(r['songTitle'], '夜に駆ける');
      expect(r['artist'], 'YOASOBI');
    });

    test('a marker only condemns the pair it follows', () {
      final r = parse('【周深】《画绢》央视《衣裳中国》主题曲 完整版 4K', '周深图文站');
      expect(r['songTitle'], '画绢');
      expect(r['artist'], '周深');
    });
  });

  group('Lyrics text', () {
    test('plain text becomes untimed lines', () {
      final lines = LyricsEngine.parseAny('第一句\n\n第二句\n');
      expect(lines.map((l) => l.text), ['第一句', '第二句']);
      expect(Lyrics(source: 'user', lines: lines).synced, isFalse);
    });

    test('LRC is still read as LRC', () {
      final lines = LyricsEngine.parseAny('[00:01.00]a\n[00:05.00]b');
      expect(lines.map((l) => l.time), [1.0, 5.0]);
    });

    test('exporting bakes the calibration offset into the times', () {
      final lrc = LyricsEngine.toLrc(
        const [LyricLine(time: 10, text: 'a'), LyricLine(time: 20, text: 'b')],
        offset: -1.5,
      );
      expect(LyricsEngine.parseLrc(lrc).map((l) => l.time), [8.5, 18.5]);
    });

    test('untimed lyrics export as plain text', () {
      final text = LyricsEngine.toLrc(const [
        LyricLine(time: 0, text: 'a'),
        LyricLine(time: 0, text: 'b'),
      ]);
      expect(text.trim(), 'a\nb');
    });
  });
}
