import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// Writes queued for the same file are coalesced: whatever is skipped must
/// still be on disk when its caller is told the save is done.
void main() {
  late Directory docs;

  setUpAll(() async {
    docs = await stubDocs('write_coalescing');
  });

  test('a burst of changes all land, however many writes are skipped',
      () async {
    await DatabaseService.getPlaylists();
    final created = await Future.wait([
      for (var i = 0; i < 20; i++) DatabaseService.createPlaylist('list $i'),
    ]);

    final file = File('${docs.path}/bilibeat_playlists.json');
    final saved = (jsonDecode(await file.readAsString())['data'] as List)
        .map((p) => (p as Map)['id'])
        .toSet();
    expect(saved, containsAll(created.map((p) => p.id)));
    expect(saved, contains('favorites'));
  });

  test('each caller sees its own change on disk once it returns', () async {
    for (var i = 0; i < 5; i++) {
      final saves = [
        DatabaseService.setPref('a', i),
        DatabaseService.setPref('b', i),
      ];
      await saves.first;
      final prefs = jsonDecode(
          await File('${docs.path}/bilibeat_prefs.json').readAsString());
      expect(prefs['data']['a'], i);
      await saves.last;
      final after = jsonDecode(
          await File('${docs.path}/bilibeat_prefs.json').readAsString());
      expect(after['data'], {'a': i, 'b': i});
    }
  });
}
