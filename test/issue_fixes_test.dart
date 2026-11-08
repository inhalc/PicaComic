import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/tools/image_integrity.dart';
import 'package:pica_comic/tools/io_extensions.dart';

void main() {
  group('cache expiry semantics (#282)', () {
    test('zero or negative duration marks an entry as permanent', () {
      expect(cacheExpiresAt(0, 1000), 0);
      expect(cacheExpiresAt(-1, 1000), 0);
      expect(cacheExpiresAt(500, 1000), 1500);
    });

    test('permanent entries never expire, timed entries do', () {
      expect(isCacheExpired(0, 9999999999999), isFalse);
      expect(isCacheExpired(1500, 1499), isFalse);
      expect(isCacheExpired(1500, 1500), isTrue);
      expect(isCacheExpired(1500, 2000), isTrue);
    });
  });

  group('download integrity (#130)', () {
    test('a truncated response is detected', () {
      expect(isTruncatedResponse(1000, null), isFalse);
      expect(isTruncatedResponse(1000, 0), isFalse);
      expect(isTruncatedResponse(1000, 1000), isFalse);
      expect(isTruncatedResponse(990, 1000), isFalse,
          reason: 'small trailing differences are tolerated');
      expect(isTruncatedResponse(100, 1000), isTrue);
    });

    test('checkImageComplete rejects only real truncation', () {
      expect(() => checkImageComplete(1000, 1000, 'u'), returnsNormally);
      expect(() => checkImageComplete(100, 1000, 'u'), throwsException);
      expect(() => checkImageComplete(100, null, 'u'), returnsNormally);
    });

    test('progress target tolerates a missing Content-Length', () {
      expect(imageProgressTarget(null, 5), 6);
      expect(imageProgressTarget(100, 5), 101);
    });

    test('magic bytes provide a fallback extension', () {
      expect(fallbackImageExtension([0xFF, 0xD8, 0xFF]), '.jpg');
      expect(fallbackImageExtension([0x89, 0x50, 0x4E, 0x47]), '.png');
      expect(fallbackImageExtension([0x47, 0x49, 0x46, 0x38]), '.gif');
      expect(
          fallbackImageExtension([
            0x52,
            0x49,
            0x46,
            0x46,
            0,
            0,
            0,
            0,
            0x57,
            0x45,
            0x42,
            0x50
          ]),
          '.webp');
      expect(fallbackImageExtension([0x3C, 0x68, 0x74, 0x6D]), '');
    });
  });

  group('streaming directory size (#202 / #259)', () {
    test('counts nested files without materialising the listing', () async {
      final dir = await Directory.systemTemp.createTemp('pica-size-');
      addTearDown(() => dir.delete(recursive: true));
      await Directory('${dir.path}/sub').create(recursive: true);
      await File('${dir.path}/a.bin').writeAsBytes(Uint8List(10));
      await File('${dir.path}/sub/b.bin').writeAsBytes(Uint8List(20));
      expect(await dir.size, 30);

      // Many small cache files used to be collected in one listSync() call.
      for (var i = 0; i < 200; i++) {
        await File('${dir.path}/sub/f$i').writeAsBytes(Uint8List(1));
      }
      expect(await dir.size, 230);
    });
  });
}
