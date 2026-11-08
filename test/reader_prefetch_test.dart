import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';

/// Records which pages the reader asks for.
class _FakeReadingData extends ReadingData {
  _FakeReadingData(this.pageCount);

  static int _nextGroup = 0;

  final int pageCount;
  final int _group = _nextGroup++;

  final List<int> resolvedPages = [];
  final Map<int, _FakeCompleter> pending = {};

  /// When false the real [ReadingData.createImageProvider] is used, which is
  /// needed to inspect the live priority closure of a [StreamImageProvider].
  bool fakeProviders = true;

  void complete(int page) {
    pending.remove(page)?.finish();
  }

  @override
  String get title => 'test';

  @override
  String get id => 'test';

  @override
  String get downloadId => 'test';

  @override
  ComicType get type => ComicType.other;

  @override
  String get sourceKey => 'test';

  @override
  bool get hasEp => false;

  @override
  Map<String, String>? get eps => null;

  @override
  bool get downloaded => false;

  @override
  FavoriteType get favoriteType => FavoriteType.picacg;

  @override
  Future<Res<List<String>>> loadEpNetwork(int ep) async =>
      Res(List.generate(pageCount, (index) => 'page-$index'));

  @override
  Stream<DownloadProgress> loadImageNetwork(int ep, int page, String url) =>
      const Stream.empty();

  @override
  ImageProvider createImageProvider(int ep, int page, String url,
      {int Function()? priorityOf}) {
    if (!fakeProviders) {
      return super.createImageProvider(ep, page, url, priorityOf: priorityOf);
    }
    final pageNumber = page + 1;
    return _FakeImageProvider(_group, pageNumber, (requested, completer) {
      resolvedPages.add(requested);
      pending[requested] = completer;
    });
  }
}

class _FakeImageProvider extends ImageProvider<_FakeImageProvider> {
  _FakeImageProvider(this.group, this.page, this.onLoad);

  final int group;
  final int page;
  final void Function(int page, _FakeCompleter completer) onLoad;

  @override
  Future<_FakeImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _FakeImageProvider key, ImageDecoderCallback decode) {
    final completer = _FakeCompleter();
    onLoad(page, completer);
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is _FakeImageProvider && other.group == group && other.page == page;

  @override
  int get hashCode => Object.hash(group, page);
}

class _FakeCompleter extends ImageStreamCompleter {
  /// Finishes without an image. The scheduler only cares that the page is no
  /// longer pending. `silent` keeps the fake out of FlutterError.
  void finish() {
    reportError(exception: StateError('fake page done'), silent: true);
  }
}

/// Counts how often a widget actually started a load.
class _CountingProvider extends ImageProvider<_CountingProvider> {
  int loadCount = 0;

  @override
  Future<_CountingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _CountingProvider key, ImageDecoderCallback decode) {
    loadCount++;
    return _NeverCompletingCompleter();
  }
}

/// A load that stays pending and never reports anything, like a page whose
/// download was dropped silently by the priority policy.
class _NeverCompletingCompleter extends ImageStreamCompleter {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> originalSettings;

  setUp(() {
    originalSettings = List<String>.of(appdata.settings);
    appdata.settings[9] = '1'; // left-to-right page mode
    appdata.settings[28] = '2'; // preload two pages
  });

  tearDown(() {
    appdata.settings.setAll(0, originalSettings);
  });

  test('pages are ranked around the page the reader is looking at', () {
    final data = _FakeReadingData(100);
    final logic = ComicReadingPageLogic(1, data, 1, () {});
    logic.urls = List.generate(100, (index) => 'url-$index');
    logic.updatePrefetchAnchor(10);

    expect(logic.loadPriorityForPage(10), ImageLoadPriority.current);
    expect(logic.loadPriorityForPage(11), ImageLoadPriority.adjacent);
    expect(logic.loadPriorityForPage(12), ImageLoadPriority.nearby);
    expect(logic.loadPriorityForPage(13), ImageLoadPriority.prefetch);
    expect(logic.loadPriorityForPage(9), ImageLoadPriority.nearby,
        reason: 'the page just left stays warm for an accidental flip back');
    expect(logic.loadPriorityForPage(8), ImageLoadPriority.skip,
        reason: 'pages behind the reader must stop downloading');
    expect(logic.loadPriorityForPage(16), ImageLoadPriority.prefetch,
        reason: 'still possibly built by a continuous list');
    expect(logic.loadPriorityForPage(18), ImageLoadPriority.skip,
        reason: 'far ahead: do not speculate that far');

    // Changing the page moves the whole window.
    logic.index = 20;
    expect(logic.prefetchAnchor, 20);
    expect(logic.loadPriorityForPage(10), ImageLoadPriority.skip,
        reason: 'the old page loses its claim on the network');
    expect(logic.loadPriorityForPage(20), ImageLoadPriority.current);
    logic.stopPrefetch();
  });

  test('a new chapter invalidates the previous chapter downloads', () {
    final data = _FakeReadingData(20)..fakeProviders = false;
    final logic = ComicReadingPageLogic(1, data, 1, () {});
    logic.urls = List.generate(20, (index) => 'url-$index');
    logic.updatePrefetchAnchor(1);

    final provider = logic.imageProviderFor(1) as StreamImageProvider;
    expect(provider.loadPriority, ImageLoadPriority.current);

    logic.chapterToken++;
    expect(provider.loadPriority, ImageLoadPriority.skip);
    logic.stopPrefetch();
  });

  test('preloading starts after the current page and goes one page at a time',
      () async {
    final data = _FakeReadingData(20);
    final logic = ComicReadingPageLogic(1, data, 1, () {});
    logic.urls = List.generate(20, (index) => 'url-$index');
    logic.startPrefetch();

    await pumpEventQueue();
    expect(data.resolvedPages, [1],
        reason: 'only the visible page is requested first');

    data.complete(1);
    await pumpEventQueue();
    expect(data.resolvedPages, [1, 2],
        reason: 'preloading waits for the visible page, then starts at +1');

    data.complete(2);
    await pumpEventQueue();
    expect(data.resolvedPages, [1, 2, 3],
        reason: 'the next page only starts after the previous one finished');

    data.complete(3);
    await pumpEventQueue();
    expect(data.resolvedPages, [1, 2, 3],
        reason: 'settings[28] = 2 caps the window at two pages ahead');

    logic.stopPrefetch();
  });

  test('flipping forward moves the preload window immediately', () async {
    final data = _FakeReadingData(20);
    final logic = ComicReadingPageLogic(1, data, 1, () {});
    logic.urls = List.generate(20, (index) => 'url-$index');
    logic.startPrefetch();

    await pumpEventQueue();
    data.complete(1);
    await pumpEventQueue();
    expect(data.resolvedPages, [1, 2]);

    // The user jumps to page 10 while page 2 is still downloading.
    logic.index = 10;
    await pumpEventQueue();
    expect(data.resolvedPages.last, 10,
        reason: 'the new visible page is watched/requested first');

    // Page 2 is now far behind and must be dropped rather than completed.
    expect(logic.loadPriorityForPage(2), ImageLoadPriority.skip);

    data.complete(2); // release the old prefetch listener
    data.complete(10);
    await pumpEventQueue();
    expect(data.resolvedPages, [1, 2, 10, 11],
        reason: 'preloading resumes from the new position');

    logic.stopPrefetch();
  });

  test('moving to another page notifies the images once per move', () {
    final data = _FakeReadingData(20);
    final logic = ComicReadingPageLogic(1, data, 1, () {});
    logic.urls = List.generate(20, (index) => 'url-$index');

    var notifications = 0;
    logic.anchorRevision.addListener(() => notifications++);

    logic.updatePrefetchAnchor(5);
    expect(notifications, 1);

    logic.updatePrefetchAnchor(5);
    expect(notifications, 1, reason: 'rebuilding the same page changes nothing');

    logic.index = 9;
    expect(notifications, 2, reason: 'a real move must wake the pages that '
        'lost their download');
    expect(logic.loadPriorityForPage(9), ImageLoadPriority.current);
    logic.stopPrefetch();
  });

  testWidgets('a page that lost its download asks again as soon as it is seen',
      (tester) async {
    final provider = _CountingProvider();
    final anchorRevision = ValueNotifier<int>(0);
    addTearDown(anchorRevision.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: ComicImage(image: provider, refreshOn: anchorRevision),
      ),
    ));
    await tester.pump();
    expect(provider.loadCount, 1);

    // The reader moved away: the provider aborts the download, evicts the key
    // and reports nothing, so the widget keeps a spinner and has no callback
    // left to learn that the page is wanted again.
    imageCache.evict(provider);

    await tester.pump();
    expect(provider.loadCount, 1,
        reason: 'nothing restarts on its own while the reader sits still');

    anchorRevision.value++;
    await tester.pump();
    expect(provider.loadCount, 2,
        reason: 'the page retries immediately instead of waiting 2.5s');

    // A page that already has its image must not restart anything.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
