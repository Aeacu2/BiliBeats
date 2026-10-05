import 'package:bilibeats/models/video_hints.dart';
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// Naming a song from the music Bilibili recognised in the video
/// ([VideoHints.musicTitle]) — offline: the singers involved are the song's
/// own artists or in the library, so nothing has to be looked up.
///
/// Titles, tags and recognised music are those of real videos
/// (`test/fixtures/zhoushen_videos.json`).
void main() {
  setUpAll(() {
    useHermeticHttp();
    LyricsEngine.knownArtists = ['周深'];
    // No word of these titles but the song's own artists and 周深 is a
    // singer; NetEase is not asked.
    LyricsEngine.singerLookup = (name) async => false;
  });

  tearDownAll(() => LyricsEngine.singerLookup = null);

  Future<SongIdentity?> identify(
    String title, {
    required String uploader,
    required String music,
    required List<String> by,
    List<String> tags = const [],
    int seconds = 240,
  }) =>
      LyricsEngine.identify(
        title,
        uploader: uploader,
        durationSeconds: seconds,
        hints: VideoHints(
          tags: tags,
          owner: uploader,
          musicTitle: music,
          musicArtists: by,
        ),
      );

  group('a cover: the singer the title names, not the song\'s own', () {
    test('周深《人间》, tagged with the original singer', () async {
      final found = await identify(
        '直播！周深《人间》完整版2026生日4K+Hi-Res+字幕',
        uploader: '微音视',
        tags: ['直播', '周深', '王菲', '好听', '人间', '4K', '高音质'],
        music: '人间',
        by: ['王菲'],
      );
      expect(found?.title, '人间');
      expect(found?.artist, '周深');
      // Not the release itself: its artwork is not borrowed.
      expect(found?.exact, isFalse);
    });

    test('周深翻唱《人间》', () async {
      final found = await identify(
        '周深翻唱《人间》。没招了，耳机插错了地方：这就是人间吧！2025生日直播',
        uploader: '世人寻黄金乡我找月亮',
        tags: ['周深', '王菲', '人间', '生日直播', '生米'],
        music: '人间',
        by: ['王菲'],
      );
      expect(found?.artist, '周深');
    });

    test('the original singer in a note is not performing', () async {
      final found = await identify(
        '周深《达拉崩吧》（原唱：洛天依/言和）｜无水印收藏版',
        uploader: 'Live搬运工',
        tags: ['周深', '言和', '洛天依', '歌手', '达拉崩吧'],
        music: '达拉崩吧',
        by: ['ilem', '洛天依', '言和'],
      );
      expect(found?.artist, '周深');
    });

    test('the song is the one heard, not another word of the title', () async {
      final found = await identify(
        '周深《Unstoppable》神级回眸惊艳全场【2023最美的夜】',
        uploader: '卡布叻_周深',
        tags: ['音乐现场', 'bilibili最美的夜', '最美的夜2022'],
        music: 'Unstoppable',
        by: ['Sia'],
      );
      expect(found?.title, 'Unstoppable');
      expect(found?.artist, '周深');
    });
  });

  group('a duet: everyone the title names', () {
    test('周深/五月天《如烟》, recognised as the live recording', () async {
      final found = await identify(
        '【官方Live MV】周深/五月天《如烟》5525+2版',
        uploader: '相信音乐',
        tags: ['周深', '音乐现场', '4K', '五月天', '如烟', '官方MV'],
        music: '如烟 (Live)',
        by: ['五月天', '周深'],
        seconds: 342,
      );
      expect(found?.title, '如烟');
      expect(found?.artist, '周深 & 五月天');
      expect(found?.exact, isTrue);
    });

    test('… and as the studio one, which is 五月天\'s alone', () async {
      final found = await identify(
        '20260509五月天 周深 如烟',
        uploader: '灬炎和永远灬',
        tags: ['周深', '五月天', '4k', '五月天演唱会', '如烟', '华语现场'],
        music: '如烟',
        by: ['五月天'],
        seconds: 340,
      );
      expect(found?.artist, '五月天 & 周深');
    });

    test('a quality tag in brackets is not a compilation', () async {
      final found = await identify(
        '【4K珍藏】五月天x周深《如烟》神级现场！有没有那么一种时间永远不改变！',
        uploader: 'B612音乐',
        tags: ['音乐现场', '周深', '阿信', '演奏', '演唱会', '五月天', '乐器'],
        music: '如烟 (Live)',
        by: ['五月天', '周深'],
        seconds: 342,
      );
      expect(found?.artist, '五月天 & 周深');
    });
  });

  group('somebody\'s version of the singer\'s song: the UP主', () {
    test('翻唱周深…《吉量》', () async {
      final found = await identify(
        '爽了！翻唱周深春晚《吉量》我妈睡我房间听我“叮叮当当”了一晚上！反正我是唱爽了！',
        uploader: '叫我船长Cppptt',
        tags: ['周深', '翻唱', '唱歌', '音乐', 'COVER'],
        music: '吉量',
        by: ['周深'],
      );
      expect(found?.title, '吉量');
      expect(found?.artist, '叫我船长Cppptt');
      expect(found?.exact, isFalse);
    });

    test('《光亮》周深 翻唱', () async {
      final found = await identify(
        '《光亮》周深 翻唱|厦大校十佳非专业组一等奖|致最无畏的你',
        uploader: '胡乐乐乐乐乐乐乐',
        tags: ['周深', '翻唱', '张函瑞', '十佳歌手', '厦门大学'],
        music: '光亮',
        by: ['周深'],
      );
      expect(found?.artist, '胡乐乐乐乐乐乐乐');
    });

    test('童声演绎周深代表作《光亮》', () async {
      final found = await identify(
        '唱出无限希望！童声演绎周深代表作《光亮》',
        uploader: '天使童声合唱团',
        tags: ['天籁', '周深', '天使童声合唱团', '童声', '周深光亮'],
        music: '光亮',
        by: ['周深'],
      );
      expect(found?.title, '光亮');
      expect(found?.artist, '天使童声合唱团');
    });
  });

  group('the singer\'s own song', () {
    test('a title that names nobody is the song\'s own artist\'s', () async {
      final found = await identify(
        'DAY3 全场丝滑秒接大合唱的璀璨冒险人',
        uploader: '小海豚和软糖',
        tags: ['周深', '大合唱', 'LIVE', '演唱会', '璀璨冒险人'],
        music: '璀璨冒险人',
        by: ['周深'],
        seconds: 172,
      );
      expect(found?.title, '璀璨冒险人');
      expect(found?.artist, '周深');
      expect(found?.exact, isTrue);
    });

    test('words run into the name are not part of it', () async {
      final found = await identify(
        '周深专辑《反深代词》《少管我》MV正式上线！',
        uploader: '周深工作室',
        tags: ['原创音乐', 'MV', '周深', '少管我', '反深代词'],
        music: '少管我',
        by: ['周深'],
      );
      expect(found?.title, '少管我');
      expect(found?.artist, '周深');
    });

    test('a one-character name counts when the title brackets it', () async {
      final found = await identify(
        '周深含着生日蛋糕唱《问》有多好听哈哈哈哈哈哈',
        uploader: '粒粒粒粒栗',
        tags: ['蛋糕', '唱功', '周深', '问', '生日直播'],
        music: '问',
        by: ['陈淑桦'],
        seconds: 126,
      );
      expect(found?.title, '问');
      expect(found?.artist, '周深');
    });
  });

  test('a name that could not be looked up leaves the song unnamed', () async {
    LyricsEngine.singerLookup = (name) async => null; // offline
    addTearDown(() => LyricsEngine.singerLookup = (name) async => false);
    // Any other word of the title may be a second singer; an answer that
    // leaves one out would be written into the library for good.
    final found = await identify(
      '史诗级联动！萨顶顶 周深 共唱《左手指月》现场',
      uploader: '央视新闻',
      tags: ['周深', '左手指月', '萨顶顶'],
      music: '左手指月',
      by: ['萨顶顶'],
    );
    expect(found, isNull);
  });

  group('music the video does not name is only its backing track', () {
    test('an awards clip is not the song playing behind it', () async {
      final found = await identify(
        '邓紫棋演唱会吉尼斯世界纪录颁奖过程完整8k直拍！！！恭喜解解！！！',
        uploader: '小饼干_GEM',
        tags: ['邓紫棋', '演唱会'],
        music: "Someday I'll Fly",
        by: ['G.E.M.邓紫棋'],
      );
      expect(found, isNull);
    });

    test('a medley is not the one song that was recognised', () async {
      final found = await identify(
        '【周深】20191116 演唱会 王菲作品串烧《我愿意+红豆+匆匆那年+闷+人间》吉他弹唱',
        uploader: '周深资讯站',
        tags: ['周深', '吉他弹唱', '人间', '匆匆那年', '红豆'],
        music: '红豆',
        by: ['王菲'],
        seconds: 548,
      );
      expect(found, isNull);
    });
  });
}
