import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/track_credit.dart';

void main() {
  test('rawTitle survives serialization round-trip', () {
    const t = Track(
      id: 'BV1QYBeBGEcU_p1',
      bvid: 'BV1QYBeBGEcU',
      cid: 1,
      title: '音乐缘计划',
      rawTitle: '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台',
      uploader: '周深工作室',
      coverUrl: '',
      duration: 300,
    );
    final rt = Track.fromMap(t.toMap());
    expect(rt.rawTitle, t.rawTitle);
    expect(rt.title, t.title);
  });

  test('metadata edit keeps rawTitle, overwrites display title', () {
    const t = Track(
      id: 'x',
      bvid: 'BV1QYBeBGEcU',
      cid: 1,
      title: '音乐缘计划',
      rawTitle: '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台',
      uploader: '周深工作室',
      coverUrl: '',
      duration: 300,
    );
    final edited = t.copyWith(title: '全世界下雨', uploader: '周深');
    expect(edited.title, '全世界下雨');
    expect(edited.rawTitle, t.rawTitle);
  });

  test('legacy track without rawTitle falls back to title', () {
    final t = Track.fromMap({
      'id': 'x',
      'bvid': 'BV1QYBeBGEcU',
      'cid': 1,
      'title': '音乐缘计划',
      'uploader': '周深工作室',
      'coverUrl': '',
      'duration': 300,
    });
    expect(t.rawTitle, '音乐缘计划');
  });

  group('naming', () {
    const raw = '【周深】《大鱼》现场';
    const video = Track(
      id: 'x',
      bvid: 'BV1',
      cid: 1,
      title: raw,
      rawTitle: raw,
      uploader: '某UP主',
      coverUrl: '',
      duration: 300,
    );

    test('an untouched download is not named; its artist is parsed', () {
      expect(video.isNamed, isFalse);
      expect(TrackCredit.artistOf(video), '周深');
    });

    test('editing only the artist still counts as naming', () {
      // The title is unchanged, so nothing but the flag says the artist
      // field is now the listener's.
      final edited = video.copyWith(uploader: '周深 & 郭沁', named: true);
      expect(edited.isNamed, isTrue);
      expect(TrackCredit.artistOf(edited), '周深 & 郭沁');
      expect(Track.fromMap(edited.toMap()).isNamed, isTrue);
    });

    test('a library saved before the flag: a changed title means named', () {
      final legacy = Track.fromMap({
        ...video.toMap(),
        'title': '大鱼',
        'uploader': '周深',
      });
      expect(legacy.named, isFalse);
      expect(legacy.isNamed, isTrue);
    });

    test('a part of a multi-part video is not named, and knows its name', () {
      final part = Track.fromMap({
        ...video.toMap(),
        'title': '$raw - P3: 晴天',
      });
      expect(part.partTitle, '晴天');
      expect(part.isNamed, isFalse);
      expect(video.partTitle, isNull);
    });
  });
}
