part of pica_reader;

/// Loads the pages that come after the current one, one at a time.
///
/// Previously every built page fired its own `precacheImage` burst for the
/// next N pages. Swiping quickly therefore queued downloads for every page
/// that passed through the viewport, and the page the user stopped on had to
/// wait behind all of them. On a slow connection that looked like "I flipped
/// ten pages, and it is still loading the ones I already passed".
///
/// This scheduler follows the reader instead:
///
/// * it only asks for pages ahead of the current one;
/// * it waits until the current page is decoded, so the link is first spent
///   on the page on screen and only then on speculation;
/// * it loads one page at a time, so the preload window fills at the speed the
///   network actually has instead of splitting bandwidth N ways;
/// * when the reader moves, queued/finished-by-now pages are dropped by
///   [ComicReadingPageLogic.loadPriorityForPage] and the next page is chosen
///   from the new position.
class ReaderPrefetchScheduler {
  ReaderPrefetchScheduler(this.logic);

  final ComicReadingPageLogic logic;

  /// Pages already attempted since the anchor last moved. Cached pages count
  /// too, so a fully cached window costs no network and no repeated work.
  final Set<int> _attempted = {};

  bool _disposed = false;
  bool _running = false;
  bool _anchorReady = false;

  ImageStream? _anchorStream;
  ImageStreamListener? _anchorListener;
  Timer? _anchorTimeout;

  int get _anchor {
    if (logic.urls.isEmpty) return 1;
    return logic.prefetchAnchor.clamp(1, logic.urls.length).toInt();
  }

  void start() {
    if (_disposed) return;
    _attempted.clear();
    _anchorReady = false;
    _watchAnchor();
    _pump();
  }

  /// The page in front of the user changed.
  void onAnchorChanged() {
    if (_disposed) return;
    _attempted.clear();
    _watchAnchor();
    _pump();
  }

  void dispose() {
    _disposed = true;
    _cancelWatch();
    _attempted.clear();
  }

  /// Waits until the visible page is decoded.
  ///
  /// Preloading next to a page that is still downloading just halves the
  /// bandwidth of the page the user is waiting for. When it fails (dead
  /// server, bad payload) preloading continues instead of stalling forever.
  void _watchAnchor() {
    _cancelWatch();
    _anchorReady = false;
    if (_disposed || logic.urls.isEmpty) return;
    final page = _anchor;
    if (logic.data.downloaded && logic.data.checkEpDownloaded(logic.order)) {
      _anchorReady = true;
      return;
    }

    final stream =
        logic.imageProviderFor(page).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;

    void done() {
      _cancelWatch();
      if (_disposed) return;
      _anchorReady = true;
      _pump();
    }

    listener = ImageStreamListener(
      (info, synchronousCall) => done(),
      onError: (error, stack) => done(),
    );
    _anchorStream = stream;
    _anchorListener = listener;

    // A page that never arrives (dead server, endless retries) must not stop
    // preloading forever: after a generous delay, start filling the window so
    // the user can keep flipping instead of staring at one stuck page.
    _anchorTimeout = Timer(const Duration(seconds: 15), () {
      if (_disposed || _anchorReady) return;
      _anchorReady = true;
      _pump();
    });

    // May call back synchronously (already cached), which cancels the timer.
    stream.addListener(listener);
  }

  void _cancelWatch() {
    _anchorTimeout?.cancel();
    _anchorTimeout = null;
    final stream = _anchorStream;
    final listener = _anchorListener;
    _anchorStream = null;
    _anchorListener = null;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
  }

  Future<void> _pump() async {
    if (_disposed || _running) return;
    _running = true;
    try {
      while (!_disposed && _anchorReady) {
        final page = _nextPage();
        if (page == null) break;
        _attempted.add(page);
        await _prefetch(page);
      }
    } finally {
      _running = false;
    }
  }

  int? _nextPage() {
    if (logic.urls.isEmpty) return null;
    final anchor = _anchor;
    final requestedEnd = anchor + logic.preloadPageCount;
    final end =
        requestedEnd < logic.urls.length ? requestedEnd : logic.urls.length;
    for (var page = anchor + 1; page <= end; page++) {
      if (_attempted.contains(page)) continue;
      return page;
    }
    return null;
  }

  Future<void> _prefetch(int page) async {
    if (_disposed || page < 1 || page > logic.urls.length) return;
    final stream =
        logic.imageProviderFor(page).resolve(ImageConfiguration.empty);
    final done = Completer<void>();
    ImageStreamListener? listener;

    void finish() {
      final current = listener;
      listener = null;
      if (current != null) {
        stream.removeListener(current);
      }
      if (!done.isCompleted) done.complete();
    }

    final streamListener = ImageStreamListener(
      (info, synchronousCall) => finish(),
      onError: (error, stack) => finish(),
    );
    listener = streamListener;
    stream.addListener(streamListener);

    // When the page becomes unwanted the provider aborts silently (there is
    // no error listener callback), so stop waiting on our own. 250 ms matches
    // the provider's own abort check.
    final watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_disposed ||
          page > logic.urls.length ||
          logic.loadPriorityForPage(page) < 0) {
        finish();
      }
    });

    try {
      await done.future;
    } finally {
      watchdog.cancel();
      final current = listener;
      listener = null;
      if (current != null) {
        stream.removeListener(current);
      }
    }
  }
}
