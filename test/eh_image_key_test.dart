import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/eh_image_key.dart';

const _link = 'https://e-hentai.org/g/4316840/0123456789/';

Gallery _gallery() => Gallery(
      'title',
      'Doujinshi',
      '2026-01-01',
      'uploader',
      4.5,
      '4.5',
      'cover.jpg',
      <String, List<String>>{},
      <Comment>[],
      null,
      false,
      _link,
      '10',
      20,
      <String>[],
      'jpg',
      1200,
      null,
    );

void main() {
  group('e-hentai page cache key', () {
    test('reader index maps to the 1-based key used by the downloader', () {
      final data = EhReadingData(_gallery());
      // buildImageKey receives the 0-based index from createImageProvider,
      // while ImageManager stores the file under the 1-based page number.
      expect(data.buildImageKey(1, 0, ''), ehPageCacheKey(_link, 1));
      expect(data.buildImageKey(1, 1, ''), ehPageCacheKey(_link, 2));
      expect(data.buildImageKey(1, 9, ''), ehPageCacheKey(_link, 10));
    });

    test('a page never asks for the previous page cache entry', () {
      final data = EhReadingData(_gallery());
      for (var index = 1; index < 12; index++) {
        // The regression: page index N resolved "${link}N", which is the
        // previous page's key in 1-based numbering, so the reader showed the
        // picture before the one it was asked for.
        expect(
          data.buildImageKey(1, index, ''),
          isNot(ehPageCacheKey(_link, index)),
        );
      }
    });

    test('consecutive pages have distinct keys', () {
      final data = EhReadingData(_gallery());
      final keys = [
        for (var index = 0; index < 20; index++)
          data.buildImageKey(1, index, '')
      ];
      expect(keys.toSet().length, keys.length);
    });
  });
}
