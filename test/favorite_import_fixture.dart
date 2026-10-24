import 'dart:convert';
import 'package:bilibeats/services/bili_account.dart';

const importAccount =
    BiliAccount(cookies: 'SESSDATA=fixture', mid: 77, name: '听歌的人');

Future<String?> favoriteImportResponse(String url, {String? cookies}) async {
  final uri = Uri.parse(url);
  Map<String, dynamic> data;
  if (uri.path.endsWith('/nav')) {
    data = {
      'isLogin': true,
      'mid': importAccount.mid,
      'uname': importAccount.name
    };
  } else if (uri.path.contains('/folder/')) {
    data = {
      'list': [
        {'id': 88, 'title': '夜里听', 'media_count': 4}
      ]
    };
  } else if (uri.path.contains('/resource/')) {
    data = {
      'has_more': false,
      'medias': [
        for (final (i, title, duration) in [
          (1, '周深《大鱼》现场', 240),
          (2, '今天聊聊音乐与生活', 420),
          (3, '《起风了》翻唱', 280),
          (4, '一场完整的演唱会', 3600)
        ])
          {
            'type': 2,
            'bvid': 'BVimport$i',
            'title': title,
            'duration': duration,
            'upper': {'name': '音乐收藏'},
            'cover': '',
            'ugc': {'first_cid': i}
          },
      ]
    };
  } else if (uri.path.endsWith('/view')) {
    final bv = uri.queryParameters['bvid']!;
    data = {
      'bvid': bv,
      'title': '周深《大鱼》现场',
      'pic': '',
      'cid': 1,
      'duration': 240,
      'owner': {'name': '音乐收藏'},
      'pages': [
        {'cid': 1, 'page': 1, 'part': '大鱼', 'duration': 120},
        {'cid': 2, 'page': 2, 'part': '光亮', 'duration': 120},
      ]
    };
  } else {
    data = {};
  }
  return jsonEncode({'code': 0, 'data': data});
}
