import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/eh_image_key.dart';

/// The reader provider key doubles as the on-disk cache key, so it has to be
/// *identical* to the key `ImageManager` writes for the same page. A one-off
/// drift is invisible in the UI until a page shows its neighbour's picture.
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
  group('reader cache key matches the downloader', () {
    test('picacg stores under the bare url', () {
      final data = PicacgReadingData('t', 'id', const ['ep']);
      const url = 'https://storage.example/1.jpg';
      expect(data.buildImageKey(1, 0, url), url);
      expect(data.buildImageKey(1, 1, url), url);
    });

    test('jm drops the query string exactly like getJmImage', () {
      final data = JmReadingData('t', 'id', const ['ep'], const ['第1话']);
      const url = 'https://cdn.example/00001.jpg?v=2&t=1';
      expect(data.buildImageKey(1, 0, url), 'https://cdn.example/00001.jpg');
    });

    test('custom source with chapters uses the episode id', () {
      final data = CustomReadingData('comic', 't', null, const {'ep1': '第一章'});
      expect(data.buildImageKey(1, 0, 'u'), 'comicep1u');
    });

    test('custom source without chapters falls back to the comic id', () {
      // getCustomImage receives epsId = id when the source has no chapters.
      // buildImageKey used to force `eps!` here and threw instead of loading.
      final data = CustomReadingData('comic', 't', null, null);
      expect(data.buildImageKey(1, 0, 'u'), 'comiccomicu');
      expect(data.buildImageKey(1, 0, 'u2'), isNot(data.buildImageKey(1, 0, 'u')));
    });

    test('e-hentai page keys are the 1-based downloader keys', () {
      final data = EhReadingData(_gallery());
      expect(data.buildImageKey(1, 0, ''), ehPageCacheKey(_link, 1));
      expect(data.buildImageKey(1, 1, ''), ehPageCacheKey(_link, 2));
      expect(data.buildImageKey(1, 0, ''), isNot(data.buildImageKey(1, 1, '')));
    });
  });
}
