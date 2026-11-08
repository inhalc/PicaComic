import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';

// 1x1, 3-frame GIF. Longer than 64 bytes so the payload validator accepts it.
const String _tinyGif =
    'R0lGODlhAQABAIAAAAAAAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQBAQAAACwAAAAAAQABAAACAUQAIfkEAQEAAAAsAAAAAAEAAQAAAgFEACH5BAEBAAAALAAAAAABAAEAAAIBRAA7';

Future<ui.Codec> _decode(ui.ImmutableBuffer buffer,
        {ui.TargetImageSize Function(int, int)? getTargetSize}) =>
    PaintingBinding.instance
        .instantiateImageCodecWithSize(buffer, getTargetSize: getTargetSize);

/// A provider whose network load never completes: the exact situation of a
/// socket that died after the response headers (VPN switch, NAT timeout).
class _StalledProvider extends BaseImageProvider<_StalledProvider> {
  _StalledProvider(this.key);

  @override
  final String key;

  int loadCalls = 0;

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) {
    loadCalls++;
    return Completer<Uint8List>().future;
  }

  @override
  Future<_StalledProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }
}

Future<ImageInfo> _firstFrame(ImageStreamCompleter completer) {
  final result = Completer<ImageInfo>();
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!result.isCompleted) result.complete(info);
    },
    onError: (Object error, StackTrace? stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  completer.addListener(listener);
  return result.future
      .whenComplete(() => completer.removeListener(listener));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-image-deadlock-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cacheRoot';
    CacheManager.instance = null;
  });

  tearDownAll(() async {
    await root.delete(recursive: true);
  });

  test('a cached page still loads when every download slot is stalled',
      () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final cachedKey = 'cached-page-$stamp';
    await CacheManager()
        .writeCache(cachedKey, base64Decode(_tinyGif), 0);

    final stalled = <ImageStreamCompleter>[];
    for (var i = 0; i < 4; i++) {
      final provider = _StalledProvider('stalled-$stamp-$i');
      stalled.add(provider.loadImage(provider, _decode));
    }

    // Wait until the four stalled requests really own every slot.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (BaseImageProvider.runningLoads < 4 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(BaseImageProvider.runningLoads, greaterThanOrEqualTo(4),
        reason: 'the stalled requests must occupy the download pool');

    final provider = _StalledProvider(cachedKey);
    final info = await _firstFrame(provider.loadImage(provider, _decode))
        .timeout(const Duration(seconds: 3),
            onTimeout: () => throw StateError(
                'A page that is already on disk never became available: '
                'the disk cache is still queued behind the download slots.'));

    expect(info.image.width, 1);
    info.dispose();
    expect(provider.loadCalls, 0,
        reason: 'a cache hit must not start a network download');

    for (final completer in stalled) {
      if (completer is ThrottledImageStreamCompleter) {
        completer.stop();
      }
    }
  });
}
