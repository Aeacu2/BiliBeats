import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeats/models/video_hints.dart';
import 'package:bilibeats/services/lyrics_engine.dart';

bool? _networkChecked;
bool _networkAvailable = false;

/// Probes connectivity to the lyric provider once per run; every live-NetEase
/// test starts with this so the suite stays green offline and in CI, and no
/// test result depends on NetEase's current ranking changing.
Future<void> _skipIfOffline() async {
  if (_networkChecked != null) {
    if (!_networkAvailable) markTestSkipped('requires music.163.com');
    return;
  }
  _networkChecked = true;
  try {
    final socket = await Socket.connect(
      'music.163.com',
      443,
      timeout: const Duration(seconds: 4),
    );
    socket.destroy();
    _networkAvailable = true;
  } catch (_) {
    markTestSkipped('requires music.163.com');
  }
}

void main() {
  test('cleanTitle: 周深-世界赠予我的 (with noise)', () {
    final res = LyricsEngine.cleanTitle(
      '周深-世界赠予我的 4k最高音质无损纯享 重混音修音版本【Hi-Res无损】',
      defaultArtist: '琉云星',
    );
    expect(res['songTitle'], '世界赠予我的');
    expect(res['artist'], '周深');
  });

  test('cleanTitle: 画绢 + 衣裳中国 (show tag disambiguation)', () {
    final res = LyricsEngine.cleanTitle(
      '【周深】《画绢》央视《衣裳中国》主题曲 完整版 4K',
      defaultArtist: '周深图文站',
    );
    expect(res['songTitle'], '画绢');
    expect(res['artist'], '周深');
  });

  // "在百万豪装录音棚大声听周深《大鱼》": the singer is glued to the phrase
  // saying where the uploader played the song, and must not be dropped with
  // it (the UP主 was credited instead).
  group('cleanTitle: studio-listening uploads credit the singer', () {
    const titles = {
      '在百万豪装录音棚大声听周深《大鱼》【Hi-res】': ['周深', '大鱼'],
      '在百万豪装录音棚大声听周深的《光亮》【Hi-res】': ['周深', '光亮'],
      '在百万豪装录音棚大声听 周深《起风了》【Hi-res】': ['周深', '起风了'],
      '周深《花开忘忧》百万豪装录音棚大声听【Hi-res】': ['周深', '花开忘忧'],
      '【周深】在百万豪装录音棚大声听《小美满》': ['周深', '小美满'],
      '百万级装备听《大鱼》- 周深【Hi-Res无损】': ['周深', '大鱼'],
      '用百万级音响听周深《浮光》是什么体验': ['周深', '浮光'],
      '戴上耳机听周深《璀璨冒险人》【Hi-Res】': ['周深', '璀璨冒险人'],
      '《告白气球》周杰伦丨百万级录音棚试听丨【Hi-Res无损】': ['周杰伦', '告白气球'],
      '在百万豪装录音棚大声听Aimer《Ref:rain》【Hi-res】': ['Aimer', 'Ref:rain'],
      '在百万豪装录音棚大声听买辣椒也用券《起风了》【Hi-res】': ['买辣椒也用券', '起风了'],
    };
    titles.forEach((title, expected) {
      test(title, () {
        final res = LyricsEngine.cleanTitle(title, defaultArtist: 'JLRS-LeoFM');
        expect(res['artist'], expected[0]);
        expect(res['songTitle'], expected[1]);
      });
    });
  });

  test('identify: studio-listening upload is the singer\'s, not the UP主\'s',
      () async {
    await _skipIfOffline();
    for (final title in [
      '在百万豪装录音棚大声听周深《大鱼》【Hi-res】',
      '周深《花开忘忧》百万豪装录音棚大声听【Hi-res】',
    ]) {
      final id = await LyricsEngine.identify(title, uploader: 'JLRS-LeoFM');
      expect(id?.artist, '周深', reason: title);
    }
  });

  test('cleanTitle: a note inside the song brackets does not end them', () {
    final res = LyricsEngine.cleanTitle(
      '周深《大梦归（《兰香如故》主题曲）》百万豪装录音棚大声听',
      defaultArtist: 'JLRS-LeoFM',
    );
    expect(res['artist'], '周深');
    expect(res['songTitle'], '大梦归');
  });

  group('cleanTitle: artists the library already knows', () {
    setUp(() => LyricsEngine.knownArtists = ['周深', '毛不易']);
    tearDown(() => LyricsEngine.knownArtists = const []);

    test('a title with no structure is credited to them', () {
      final res = LyricsEngine.cleanTitle(
        '周深 大鱼 百万豪装录音棚大声听',
        defaultArtist: 'JLRS-LeoFM',
      );
      expect(res['artist'], '周深');
      expect(res['songTitle'], '大鱼');
    });

    test('even run into the words around them', () {
      final res = LyricsEngine.cleanTitle(
        '周深再唱成名曲大鱼震撼全场',
        defaultArtist: '夕照影音',
      );
      expect(res['artist'], '周深');
    });

    test('an artist the title names structurally is not overridden', () {
      final res = LyricsEngine.cleanTitle(
        '【郁可唯】《路过人间》致敬周深',
        defaultArtist: '某UP主',
      );
      expect(res['artist'], '郁可唯');
    });

    test('but not the one a cover says it is of', () {
      final res = LyricsEngine.cleanTitle('女生翻唱周深大鱼', defaultArtist: '某UP主');
      expect(res['artist'], '某UP主');
    });

    test('a title naming nobody known stays with the UP主', () {
      final res = LyricsEngine.cleanTitle('今晚月色真美', defaultArtist: '某UP主');
      expect(res['artist'], '某UP主');
    });
  });

  group('identify: titles that used to mislead it', () {
    Future<void> check(String title, String uploader, String? song,
        [String? artist]) async {
      await _skipIfOffline();
      final id = await LyricsEngine.identify(title, uploader: uploader);
      expect(id?.title, song, reason: title);
      if (artist != null) expect(id?.artist, artist, reason: title);
    }

    test('the bracketed name is the song, not a word beside it', () async {
      await check('致敬先烈 《如愿》', '脸圆霸学习版', '如愿', '脸圆霸学习版');
      await check('以爱之名 你还愿意吗｜《起风了》', 'MoreLight室内乐团', '起风了', 'MoreLight室内乐团');
      await check('【史诗版】《漠河舞厅》——Epic Symphony Cover', '北极星电台', '漠河舞厅', '北极星电台');
    });

    test('words before the brackets do not spoil the search', () async {
      await check('奥特曼限定版《孤勇者》，致那黑夜中的呜咽与怒吼', '大古音乐', '孤勇者', '大古音乐');
    });

    test('a word glued to the name is not part of it', () async {
      await check('周深 - 光亮MV', '红色希望之队', '光亮', '周深');
    });

    test('the singer the title labels beats a word that is also an artist',
        () async {
      await check('【张杰】北斗星空22周年《也许你就在对岸》生日快乐', 'JASON-张杰音乐馆', '也许你就在对岸', '张杰');
    });

    test('a singer covering a bracketed song is still found', () async {
      await check('【步束】《海底》翻唱，悠扬婉转的治愈之歌（补档）', '语丶冰FrozenWord', '海底', '步束');
      await check('王菲&amp;窦靖童合唱《誓言》', '有怪兽Biu', '誓言', '王菲 & 窦靖童');
      await check('【从前从前有个人爱你很久】周杰伦-晴天MV', '烤鱼老椰', '晴天', '周杰伦');
    });

    test('a date is not a song', () async {
      await check('2026 8.2李荣浩录屏', '小杨爱c辣', null);
    });

    test('a sentence ending in a word is not a title about that word',
        () async {
      await check('邓紫棋也是被逼得没办法了 哈哈', '逍遥炎龙o', null);
    });
  });

  group('identify: what Bilibili knows beyond the title', () {
    const studio = VideoHints(
      tags: ['大鱼', '高音质', '周深', '大鱼海棠', '动感视频', '录音棚', '音响', 'Hi-Fi'],
    );
    const amateur = VideoHints(
      tags: ['大鱼', '周深', '大鱼海棠', '女生翻唱', '国庆快乐', '学生翻唱', 'ktv翻唱'],
    );

    test('tags name the song and singer a title leaves out', () async {
      await _skipIfOffline();
      final id = await LyricsEngine.identify(
        '这首歌一开口就跪了，建议戴耳机',
        uploader: 'JLRS-LeoFM',
        durationSeconds: 316,
        hints: studio,
      );
      expect(id?.title, '大鱼');
      expect(id?.artist, '周深');
      expect(id?.exact, isTrue);
    });

    test('without them such a title is not guessed at', () async {
      await _skipIfOffline();
      final id = await LyricsEngine.identify(
        '这首歌一开口就跪了，建议戴耳机',
        uploader: 'JLRS-LeoFM',
        durationSeconds: 316,
      );
      expect(id, isNull);
    });

    test('on a cover the tags name the song, the UP主 sings it', () async {
      await _skipIfOffline();
      for (final title in ['宿舍随便唱唱', '这是周深唱的大鱼？？！！！']) {
        final id = await LyricsEngine.identify(
          title,
          uploader: '半生已熟的米',
          durationSeconds: 168,
          hints: amateur,
        );
        expect(id?.title, '大鱼', reason: title);
        expect(id?.artist, '半生已熟的米', reason: title);
        expect(id?.exact, isFalse, reason: title);
      }
    });

    // A cover is not thereby the UP主's: it may be a clip of a singer
    // covering someone else's song.
    test('a clipped cover is the singer\'s, named in the title', () async {
      await _skipIfOffline();
      for (final title in [
        '【周深】《不舍》cover 2025生日直播',
        '周深翻唱《不舍》2025生日直播',
        '单依纯翻唱周深《大鱼》',
      ]) {
        final id = await LyricsEngine.identify(title, uploader: '某剪辑站');
        expect(id?.artist, title.startsWith('单依纯') ? '单依纯' : '周深',
            reason: title);
      }
    });

    test('a clipped cover is the singer\'s, named only in the tags', () async {
      await _skipIfOffline();
      final id = await LyricsEngine.identify(
        '生日直播唱的这首不舍也太好哭了',
        uploader: '某剪辑站',
        durationSeconds: 200,
        hints: const VideoHints(tags: ['周深', '不舍', '翻唱', '生日直播']),
      );
      expect(id?.title, '不舍');
      expect(id?.artist, '周深');
    });

    test('a fan channel\'s clip is the singer it is named after', () async {
      await _skipIfOffline();
      LyricsEngine.knownArtists = ['周深'];
      addTearDown(() => LyricsEngine.knownArtists = const []);
      final id = await LyricsEngine.identify(
        '生日直播唱的这首不舍也太好哭了',
        uploader: 'ForCharlie_周深图文站',
        durationSeconds: 200,
        hints: const VideoHints(tags: ['不舍', '翻唱', '生日直播']),
      );
      expect(id?.title, '不舍');
      expect(id?.artist, '周深');
    });

    test(
        'nobody covers their own song: the original artist named on a '
        'rendition is the one covered', () async {
      await _skipIfOffline();
      final cover = await LyricsEngine.identify(
        '周深《大鱼》钢琴翻弹',
        uploader: '某钢琴UP',
        durationSeconds: 200,
      );
      expect(cover?.title, '大鱼');
      expect(cover?.artist, '某钢琴UP');
      expect(cover?.exact, isFalse);
    });

    test('a singer\'s own cover of someone else\'s song is theirs', () async {
      await _skipIfOffline();
      final id = await LyricsEngine.identify(
        '周深 漂洋过海来看你 cover',
        uploader: '某剪辑站',
        durationSeconds: 183,
      );
      expect(id?.title, '漂洋过海来看你');
      expect(id?.artist, '周深');
    });

    test('tags do not overrule the singer the title names', () async {
      await _skipIfOffline();
      final id = await LyricsEngine.identify(
        '【单依纯】大鱼 歌手2025',
        uploader: '某剪辑站',
        durationSeconds: 250,
        hints: const VideoHints(tags: ['周深', '大鱼', '单依纯', '歌手2025']),
      );
      expect(id?.title, '大鱼');
      expect(id?.artist, '单依纯');
    });

    test('the singer\'s catalogue finds a name run into the title', () async {
      await _skipIfOffline();
      final id = await LyricsEngine.identify(
        '周深再唱成名曲大鱼神级吟唱震撼全场',
        uploader: '夕照影音',
        durationSeconds: 312,
        hints: const VideoHints(tags: ['天籁', '吟唱', '大鱼', '周深', '神级']),
      );
      expect(id?.title, '大鱼');
      expect(id?.artist, '周深');
    });
  });

  test('cleanTitle: simple Artist - Song with spaces', () {
    final res = LyricsEngine.cleanTitle(
      '毛不易 - 一程山路',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '一程山路');
    expect(res['artist'], '毛不易');
  });

  test('cleanTitle: 邓紫棋《11》with book brackets', () {
    final res = LyricsEngine.cleanTitle(
      '邓紫棋《11》官方MV',
      defaultArtist: 'UP主',
    );
    expect(res['songTitle'], '11');
    expect(res['artist'], '邓紫棋');
  });

  test('cleanTitle: book bracket with artist after', () {
    final res = LyricsEngine.cleanTitle('《大鱼》周深');
    expect(res['songTitle'], '大鱼');
    expect(res['artist'], '周深');
  });

  test('cleanTitle: preserves normal tokens without noise keywords', () {
    final res = LyricsEngine.cleanTitle(
      '陈奕迅 - 十年',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '十年');
    expect(res['artist'], '陈奕迅');
  });

  test('cleanTitleWithValidation: 周深-世界赠予我的', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '周深-世界赠予我的 4k最高音质无损纯享 重混音修音版本【Hi-Res无损】',
      defaultArtist: '琉云星',
    );
    expect(res['songTitle'], '世界赠予我的');
    // Artist should be 周深 from either rule-based or cross-validation
    expect(res['artist'], '周深');
  });

  test(
      'cleanTitleWithValidation: 【姚贝娜&amp;单依纯 心火】collab bracket (DB disambiguation)',
      () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '【姚贝娜&amp;单依纯 心火】音乐是我们最珍贵的琥珀，致敬。',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '心火');
    expect(res['artist'], contains('姚贝娜'));
    expect(res['artist'], contains('单依纯'));
  });

  test('cleanTitle: 【姚贝娜&amp;单依纯 心火】with HTML entity & collab', () {
    final res = LyricsEngine.cleanTitle(
      '【姚贝娜&amp;单依纯 心火】音乐是我们最珍贵的琥珀，致敬。',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '心火');
    expect(res['artist'], '姚贝娜&单依纯');
  });

  test('cleanTitle: 【Artist&Artist Song】without HTML entity', () {
    final res = LyricsEngine.cleanTitle(
      '【张杰&张碧晨 只要平凡】我不是药神',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '只要平凡');
    expect(res['artist'], '张杰&张碧晨');
  });

  test('cleanTitle: show《音乐缘计划》+ song《全世界下雨》multi-bracket', () {
    final res = LyricsEngine.cleanTitle(
      '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '全世界下雨');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: show-vs-song book brackets', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '全世界下雨');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: repeated taps are idempotent (memoized)',
      () async {
    await _skipIfOffline();
    const raw = '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台';
    final a =
        await LyricsEngine.cleanTitleWithValidation(raw, defaultArtist: '某UP主');
    final b =
        await LyricsEngine.cleanTitleWithValidation(raw, defaultArtist: '某UP主');
    expect(a, b);
    expect(a['songTitle'], isNotEmpty);
  });

  test('cleanTitle: show metadata after | separator is ignored', () {
    final res = LyricsEngine.cleanTitle(
      '【纯享】刘端端姚晓棠《霸王别姬》 舞台携手再现传世经典 | 音乐缘计划 | Melody Journey | iQIYI奇艺音悦台',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '霸王别姬');
    expect(res['artist'], '刘端端姚晓棠');
  });

  test('cleanTitleWithValidation: show metadata after | separator', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '【纯享】刘端端姚晓棠《霸王别姬》 舞台携手再现传世经典 | 音乐缘计划 | Melody Journey | iQIYI奇艺音悦台',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '霸王别姬');
    expect(res['artist'], '刘端端姚晓棠');
  });

  // Regression: 【show】 plain-artist 《song》. The leading bracket is the
  // show tag (声生不息3), not the artist — the plain text between the bracket
  // and the song bracket is. Used to return 声生不息3 as the artist, which
  // also poisoned the auto lyric search.
  test('cleanTitle: 【show】 plain artist 《song》 — plain artist wins', () {
    final res = LyricsEngine.cleanTitle(
      '【声生不息3】 黄绮珊&周深 《岁月》',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '岁月');
    expect(res['artist'], '黄绮珊&周深');
  });

  // The bracket artist must still win when nothing sits between bracket and
  // song, even with noise tokens in between (dropped by _noisyClean).
  test('cleanTitle: 【artist】 noise 《song》 keeps bracket artist', () {
    final res = LyricsEngine.cleanTitle(
      '【周深】 4K高清 《大鱼》',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '大鱼');
    expect(res['artist'], '周深');
  });

  // Regression (3.11.0 report): space-separated collab after a show bracket
  // with NO season digit. The & marker rule and the season-digit rule both
  // missed it, so the bracket show name survived as the artist and
  // validation laundered it (孙燕姿's 逆光 isn't by anyone in the title).
  test('cleanTitle: 【show】 space-separated collab 《song》', () {
    final res = LyricsEngine.cleanTitle(
      '【声生不息】陈楚生 周深 合作舞台《逆光》 爱在“逆光”中前行',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '逆光');
    expect(res['artist'], '陈楚生 周深');
  });

  // Regression (3.11.3, rule above in live form): the hinted "陈楚生 周深
  // 逆光" search carries two artist tokens; the match against the provider's
  // song name must survive them (isTitleMatching's length guard alone rejects
  // the 2-char 逆光 against the full query). Without this, the hinted query
  // yielded nothing and the bare 逆光 fallback resurrected 孙燕姿's studio
  // version — the 3.11.1 fix regressed.
  test(
      'matchesSongQuery: multi-token artist hints still match short song names',
      () {
    expect(
      LyricsEngine.matchesSongQuery('逆光 (live)', '陈楚生 周深 逆光'),
      isTrue,
    );
    expect(
      LyricsEngine.matchesSongQuery('逆光', '陈楚生 周深 逆光'),
      isTrue,
    );
    expect(
      LyricsEngine.matchesSongQuery('岁月 (live)', '黄绮珊&周深 岁月'),
      isTrue,
    );
    expect(
      LyricsEngine.matchesSongQuery('世界赠予我的', '周深 世界赠予我的'),
      isTrue,
    );
  });

  // Regression (3.11.3): whole-word English glue noise (Cover/MV/Live) must
  // not eat real words — 周深 - Alive must split into artist 周深 / song
  // Alive, and Discover/Deliver-like tokens must survive _noisyClean.
  test('cleanTitle: English glue noise does not eat real words', () {
    final res = LyricsEngine.cleanTitle('周深 - Alive', defaultArtist: '某UP主');
    expect(res['songTitle'], 'Alive');
    expect(res['artist'], '周深');
  });

  // Regression (3.11.3): a standalone bar token must survive _noisyClean so
  // step 4's "Artist - Song" split still fires (the bar-split previously ran
  // before the pureSeparatorToken check and destroyed it).
  test('cleanTitle: standalone / separator still splits Artist / Song', () {
    final res = LyricsEngine.cleanTitle('周深 / 大鱼', defaultArtist: '某UP主');
    expect(res['songTitle'], '大鱼');
    expect(res['artist'], '周深');
  });

  // Regression (singer misrecognition report): the 4 songs 遥遥 / 有可能的
  // 夜晚 / 不舍 / 聊聊 are all 周深's, but cross-validation returned garbage
  // artists (the offline fallback) because the correct singer present in the
  // raw B站 title was never considered. Titles below are the real B站 titles.
  test('cleanTitleWithValidation: 遥遥-周深 (reversed dash)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '遥遥-周深',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '遥遥');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 不舍-周深 (reversed dash)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '不舍-周深',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '不舍');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 【纯净版】有可能的夜晚 周深 歌手2020 高清', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '【纯净版】有可能的夜晚 周深 歌手2020 高清',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '有可能的夜晚');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 周深翻唱《不舍》2025生日直播', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '周深翻唱《不舍》2025生日直播',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '不舍');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 周深 遥遥 (artist before song)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '周深 遥遥',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '遥遥');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 聊聊-周深 (reversed dash)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '聊聊-周深',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '聊聊');
    expect(res['artist'], '周深');
  });
}
