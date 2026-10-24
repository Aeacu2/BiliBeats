import 'package:bilibeats/models/lyrics.dart';
import 'package:bilibeats/models/subtitles.dart';
import 'package:bilibeats/services/bili_account.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:bilibeats/services/subtitle_match.dart';
import 'package:bilibeats/widgets/trim_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

/// A song's lyrics, a line every four seconds from [start].
List<LyricLine> song(List<String> lines, {double start = 10}) => [
      for (var i = 0; i < lines.length; i++)
        LyricLine(time: start + i * 4, text: lines[i]),
    ];

Subtitles heard(List<String> lines,
        {double start = 10,
        bool ai = true,
        String Function(String)? mishear}) =>
    Subtitles(language: 'ai-zh', ai: ai, lines: [
      for (var i = 0; i < lines.length; i++)
        SubtitleLine(
          from: start + i * 4,
          to: start + i * 4 + 3,
          text: mishear == null ? lines[i] : mishear(lines[i]),
        ),
    ]);

const daYu = [
  '海浪无声将夜幕深深淹没',
  '漫过天空尽头的角落',
  '大鱼在梦境的缝隙里游过',
  '凝望你沉睡的轮廓',
  '看海天一色听风起雨落',
  '执子手吹散苍茫茫烟波',
  '大鱼的翅膀已经太辽阔',
  '我松开时间的绳索',
  '怕你飞远去怕你离我而去',
  '更怕你永远停留在这里',
];

void main() {
  group('comparing subtitles with lyrics', () {
    test('the song heard in the video is confirmed, and its shift found', () {
      // Heard 2.5 s later than the lyrics say, a word misheard here and there.
      final match = SubtitleMatcher.compare(
        heard(daYu, start: 12.5, mishear: (l) => l.replaceAll('鱼', '于')),
        song(daYu),
      );
      expect(match.confirms, isTrue);
      expect(match.offset, closeTo(2.5, 0.01));
      expect(match.firstSung, 12.5);
    });

    test('a chorus sung again does not pull the shift off', () {
      final lyrics = song([...daYu, ...daYu.take(4)]);
      final subs = heard([...daYu, ...daYu.take(4)], start: 7);
      final match = SubtitleMatcher.compare(subs, lyrics);
      expect(match.offset, closeTo(-3, 0.01));
    });

    test('another song is not confirmed', () {
      final other = song([
        '我曾经跨过山和大海',
        '也穿过人山人海',
        '我曾经拥有着的一切',
        '转眼都飘散如烟',
        '我曾经失落失望失掉所有方向',
        '直到看见平凡才是唯一的答案',
      ]);
      final match = SubtitleMatcher.compare(heard(daYu), other);
      expect(match.confirms, isFalse);
      expect(match.offset, isNull);
    });

    test('a few lines of the song inside a long talk are not enough', () {
      final talk = [
        for (var i = 0; i < 30; i++) '今天给大家分享一下我最近的生活第$i部分',
      ];
      final match = SubtitleMatcher.compare(
          heard([...talk, ...daYu.take(3)]), song(daYu));
      expect(match.confirms, isFalse);
    });

    test('lyrics with no times confirm but give no shift', () {
      final match =
          SubtitleMatcher.compare(heard(daYu), song(daYu), timed: false);
      expect(match.confirms, isTrue);
      expect(match.offset, isNull);
    });
  });

  group('subtitles as lyrics', () {
    test('a song comes back in lines; talk does not', () {
      expect(
          SubtitleMatcher.looksSung(heard([...daYu, ...daYu.take(4)])), isTrue);
      final talk = [
        '大家好欢迎回到我的频道今天我们聊一聊最近很火的一首歌',
        '这首歌其实是两年前发行的但是最近突然在短视频平台上爆了',
        '我觉得原因有很多首先是它的旋律非常抓耳一听就能记住',
        '其次是歌词写得很有画面感很多人都说听了以后很想去看海',
        '我自己第一次听的时候是在地铁上当时就循环了好几遍',
        '然后我们来看一下编曲部分前奏用的是钢琴加上一点弦乐',
        '副歌部分加入了鼓点整个情绪一下子就被推上去了',
        '最后说一下演唱这位歌手的高音非常稳气息也很足',
        '好了今天的分享就到这里如果你喜欢的话记得一键三连',
        '我们下期再见拜拜',
      ];
      expect(SubtitleMatcher.looksSung(heard(talk)), isFalse);
      // The uploader's own captions on a short-lined video are lyrics.
      expect(SubtitleMatcher.looksSung(heard(daYu, ai: false)), isTrue);
    });
  });

  group('Bilibili answers', () {
    test('the uploader\'s Chinese subtitles are preferred', () {
      final picked = BilibiliSdk.pickSubtitle([
        {'lan': 'ai-zh', 'type': 1, 'subtitle_url': '//a/ai.json'},
        {'lan': 'en-US', 'type': 0, 'subtitle_url': '//a/en.json'},
        {'lan': 'zh-CN', 'type': 0, 'subtitle_url': '//a/zh.json'},
        {'lan': 'ja', 'type': 0, 'subtitle_url': ''},
      ]);
      expect(picked?['lan'], 'zh-CN');
      expect(
          BilibiliSdk.pickSubtitle([
            {'lan': 'ai-zh', 'type': 1, 'subtitle_url': ''},
          ]),
          isNull);
    });

    test('a subtitle file is read in order', () {
      final subs = BilibiliSdk.parseSubtitleBody(
        '{"body":[{"from":5.2,"to":7,"content":"漫过天空"},'
        '{"from":1.0,"to":3,"content":"海浪无声"},{"from":9,"to":9.5,"content":" "}]}',
        language: 'ai-zh',
        ai: true,
      )!;
      expect([for (final l in subs.lines) l.text], ['海浪无声', '漫过天空']);
      expect(subs.lines.first.from, 1.0);
    });

    test('a QR login reports each step, and the session at the end', () {
      expect(BilibiliSdk.parseQrPoll({'code': 86101})?.state,
          QrLoginState.waiting);
      expect(BilibiliSdk.parseQrPoll({'code': 86090})?.state,
          QrLoginState.scanned);
      expect(BilibiliSdk.parseQrPoll({'code': 86038})?.state,
          QrLoginState.expired);
      final done = BilibiliSdk.parseQrPoll({
        'code': 0,
        'url': 'https://passport.biligame.com/x/passport-login/web/crossDomain'
            '?DedeUserID=42&DedeUserID__ckMd5=ab&Expires=1&SESSDATA=x%2Cy%2Cz'
            '&bili_jct=jct&gourl=https%3A%2F%2Fwww.bilibili.com',
      })!;
      expect(done.state, QrLoginState.done);
      expect(BiliAccount.cookieValue(done.cookies!, 'SESSDATA'), 'x%2Cy%2Cz');
      expect(BiliAccount.cookieValue(done.cookies!, 'bili_jct'), 'jct');
      expect(done.cookies, isNot(contains('gourl')));
    });

    test('the account check needs a login', () {
      expect(
          BilibiliSdk.parseNav(
              '{"code":0,"data":{"isLogin":true,"mid":42,"uname":"小明"}}',
              'SESSDATA=x'),
          isA<BiliAccount>()
              .having((a) => a.mid, 'mid', 42)
              .having((a) => a.name, 'name', '小明'));
      expect(
          BilibiliSdk.parseNav(
              '{"code":-101,"data":{"isLogin":false}}', 'SESSDATA=x'),
          isNull);
    });

    test('favourites keep videos that can still be downloaded', () {
      final tracks = BilibiliSdk.parseFavoritePage({
        'medias': [
          {
            'type': 2,
            'bvid': 'BV1ok',
            'title': '周深《大鱼》',
            'upper': {'name': 'UP'},
            'cover': 'http://i0.hdslb.com/c.jpg',
            'duration': 300,
            'attr': 0,
            'ugc': {'first_cid': 7},
          },
          {'type': 2, 'bvid': 'BV1gone', 'title': '已失效视频', 'attr': 9},
          {'type': 12, 'bvid': 'BV1audio', 'title': '音频'},
        ],
        'has_more': false,
      });
      expect(tracks.map((t) => t.id), ['BV1ok_p1']);
      expect(tracks.single.cid, 7);
      expect(tracks.single.coverUrl, 'https://i0.hdslb.com/c.jpg');
    });

    test('the watch history yields its music only', () {
      final tracks = BilibiliSdk.parseHistory({
        'list': [
          {
            'title': '大鱼 翻唱',
            'tag_name': '翻唱',
            'author_name': 'UP',
            'duration': 280,
            'history': {'bvid': 'BV1song', 'cid': 3, 'page': 2},
          },
          {
            'title': '游戏实况',
            'tag_name': '单机游戏',
            'history': {'bvid': 'BV1game', 'cid': 4, 'page': 1},
          },
          {
            'title': '吉他入门',
            'tag_name': '音乐教学',
            'history': {'bvid': 'BV1lesson', 'cid': 5, 'page': 1},
          },
        ],
      });
      expect(tracks.map((t) => t.id), ['BV1song_p2']);
    });
  });

  test('only the login cookies are kept from a browser\'s', () {
    expect(
      BiliAccount.sessionCookies(
          'buvid3=abc; SESSDATA=s; _uuid=u; bili_jct=j; DedeUserID=1'),
      'SESSDATA=s; bili_jct=j; DedeUserID=1',
    );
    expect(BiliAccount.hasSession('buvid3=abc'), isFalse);
  });

  group('a suggested trim', () {
    test('starts where the recording starts, by the lyrics\' shift', () {
      // Talk first; the recording (its intro before the first line
      // included) starts at 18 s: every line is heard 18 s after its time
      // in the lyrics. The recording is 50 s long.
      final video = Subtitles(language: 'ai-zh', ai: true, lines: [
        const SubtitleLine(from: 1, to: 6, text: '大家好今天给大家带来一首我很喜欢的歌希望你们喜欢'),
        for (var i = 0; i < daYu.length; i++)
          SubtitleLine(from: 28.0 + i * 4, to: 31.0 + i * 4, text: daYu[i]),
        const SubtitleLine(from: 75, to: 79, text: '谢谢大家记得点赞投币收藏我们下期再见'),
      ]);
      final cut = suggestTrim(
          video,
          Lyrics(source: 'netease', lines: song(daYu)),
          const Duration(seconds: 90),
          recordingSeconds: 50)!;
      expect(cut.start, const Duration(seconds: 18));
      expect(cut.end, const Duration(seconds: 68));
    });

    test('without the recording\'s length, only the start is offered', () {
      final cut = suggestTrim(
          heard(daYu, start: 30),
          Lyrics(source: 'netease', lines: song(daYu)),
          const Duration(seconds: 90))!;
      expect(cut.start, const Duration(seconds: 20));
      expect(cut.end, isNull);
    });

    test('is not offered when the song fills the video', () {
      expect(
          suggestTrim(
              heard(daYu, start: 11),
              Lyrics(source: 'netease', lines: song(daYu)),
              const Duration(seconds: 60),
              recordingSeconds: 58),
          isNull);
    });

    test('needs timed lyrics the subtitles confirm', () {
      expect(
          suggestTrim(
              heard(daYu, start: 30), null, const Duration(seconds: 90)),
          isNull);
    });
  });
}
