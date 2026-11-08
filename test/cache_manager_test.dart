import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';

/// Integration coverage for the disk cache fixes in issues #282 / #202.
/// Uses a temporary sandbox so it never touches real app data.
Future<int> _fileCount() async => await Directory(CacheManager.cachePath)
    .list(recursive: true)
    .where((entity) => entity is File)
    .length;

void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-cache-test-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cacheRoot';
    CacheManager.instance = null;
  });

  tearDownAll(() async {
    await root.delete(recursive: true);
  });

  test('persistent cache survives cleanup; overwrite leaves no orphan',
      () async {
    final manager = CacheManager();
    await manager.writeCache('permanent', Uint8List(32), 0);
    expect(await manager.findCache('permanent'), isNotNull);
    await manager.checkCache();
    expect(await manager.findCache('permanent'), isNotNull,
        reason: 'CacheExpiredTime.persistent used to expire immediately');

    final before = await _fileCount();
    await manager.writeCache('permanent', Uint8List(64));
    expect(await _fileCount(), before,
        reason: 'rewriting a key must delete the previous file');
  });

  test('expired entries are removed on lookup', () async {
    final manager = CacheManager();
    await manager.writeCache('short-lived', Uint8List(8), 1);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await manager.findCache('short-lived'), isNull);
  });

  test('limit enforcement terminates and protects permanent entries',
      () async {
    final manager = CacheManager();
    await manager.writeCache('keep', Uint8List(16), 0);
    await manager.writeCache('evict', Uint8List(16));
    manager.setLimitSize(0);
    await manager.checkCache().timeout(const Duration(seconds: 5));
    expect(await manager.findCache('keep'), isNotNull);
    expect(await manager.findCache('evict'), isNull);
  });
}
