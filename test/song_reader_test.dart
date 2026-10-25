import 'dart:io';

import 'package:bilibeats/services/song_reader.dart';
import 'package:bilibeats/services/song_reader_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The on-device model, on videos of the kinds the rules get wrong.
///
/// The weights are not in the repository (assets/song_model/README.md):
/// without them these are skipped, as the app then goes by the rules alone.
void main() {
  const dir = 'assets/song_model';
  final present = File('$dir/song_model.bin').existsSync();
  late final SongReader reader = SongReader.load(
    File('$dir/song_model.bin').readAsBytesSync(),
    File('$dir/song_vocab.txt').readAsStringSync(),
    File('$dir/song_singers.txt').readAsStringSync(),
  );

  group('reads', () {
    test('the singer covering, not whose song it is', () {
      final r = reader.read(
        title: '直播！周深《人间》完整版2026生日4K+Hi-Res+字幕',
        uploader: '微音视',
        tags: ['直播', '周深', '王菲', '好听', '人间', '4K', '高音质'],
        musicTitle: '人间',
        musicArtists: ['王菲'],
        durationSeconds: 283,
      );
      expect(r.song, '人间');
      expect(r.performers, ['周深']);
      expect(r.own, isFalse);
      expect(r.confidence, greaterThan(0.9));
    });

    test('the uploader, on a cover that names whom it covers', () {
      final r = reader.read(
        title: '《甲乙丙丁》粤语版 表妹灵魂翻唱!! ｜“不再认得 先生贵姓” Cover李佳薇',
        uploader: '糖糖YuzeTang',
        tags: ['港乐', '粤语翻唱', '甲乙丙丁', '翻唱', '女声翻唱', '李佳薇'],
        musicTitle: '甲乙丙丁 (你我怎么两清伴奏)',
        musicArtists: ['李佳薇'],
        durationSeconds: 208,
      );
      expect(r.song, '甲乙丙丁');
      expect(r.own, isTrue);
      expect(r.performers, ['糖糖YuzeTang']);
    });

    test('both singers of a duet', () {
      final r = reader.read(
        title: '《最美和声》萧敬腾、林惠敏《天天想你》',
        uploader: '糠粑',
        tags: ['萧敬腾', '最美和声', '天天想你'],
        musicTitle: '天天想你',
        musicArtists: ['张雨生'],
        durationSeconds: 260,
      );
      expect(r.song, '天天想你');
      expect(r.performers, ['萧敬腾', '林惠敏']);
    });

    test('no song in a video that is about something else', () {
      // 篇章 is a song's name; here it is a word.
      final r = reader.read(
        title: '兰州 迟到的 篇章…',
        uploader: '薛之谦',
        tags: ['vlog', '兰州', '演唱会'],
        durationSeconds: 357,
      );
      expect(r.song, isNull);
      expect(r.pNone, greaterThan(0.5));
    });

    test('a song named in kana', () {
      final r = reader.read(
        title: '【YOASOBI】たぶん【Ayase×ikura】Music Video',
        uploader: '妄想Delusions',
        tags: ['日语MV', 'YOASOBI', 'ikura'],
        musicTitle: 'たぶん',
        musicArtists: ['YOASOBI'],
        durationSeconds: 258,
      );
      expect(r.song, 'たぶん');
      expect(r.performers, contains('YOASOBI'));
    });
  }, skip: present ? false : 'the song model is not installed');

  test('the service reads in an isolate, from the app\'s assets', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final support = await Directory.systemTemp.createTemp('bilibeat_model');
    addTearDown(() => support.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => support.path);
    final r = await SongReaderService.read(
      title: '周深《大鱼》',
      uploader: '某剪辑站',
      tags: ['周深', '大鱼'],
      durationSeconds: 300,
    );
    expect(r?.song, '大鱼');
    expect(r?.performers, ['周深']);
    // Unpacked whole: the stamp is written last.
    expect(File('${support.path}/song_model/song_model.json').existsSync(),
        isTrue);
  }, skip: present ? false : 'the song model is not installed');

  test('readings in a row share one loaded model', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final support = await Directory.systemTemp.createTemp('bilibeat_model');
    addTearDown(() => support.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => support.path);
    Future<SongReading?> read(String title) => SongReaderService.read(
          title: title,
          uploader: '某剪辑站',
          tags: ['周深'],
          durationSeconds: 300,
        );
    await read('周深《大鱼》');
    // Asked together, answered each in turn.
    final both = await Future.wait([read('周深《大鱼》'), read('周深《光亮》')]);
    expect(both.map((r) => r?.song), ['大鱼', '光亮']);
  }, skip: present ? false : 'the song model is not installed');
}
