import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/services/bili_account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// The login moves out of the documents' top level, into the folder iOS
/// leaves out of backups.
void main() {
  test('a login saved by an older version is kept, in its new place', () async {
    final docs = await stubDocs('account_move');
    final old = File('${docs.path}/bilibeat_account.json');
    await old.writeAsString(jsonEncode({
      'schema_version': 1,
      'data': {'cookies': 'SESSDATA=old', 'mid': 7, 'name': 'someone'},
    }));

    await BiliAccountStore.ensureLoaded();
    expect(BiliAccountStore.current.value?.mid, 7);
    expect(await old.exists(), isFalse);
    final moved = File('${docs.path}/bilibeat_private/bilibeat_account.json');
    expect(await moved.readAsString(), contains('SESSDATA=old'));
  });
}
