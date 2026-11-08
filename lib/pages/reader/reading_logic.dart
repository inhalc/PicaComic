part of pica_reader;

extension PageControllerExtension on PageController{
  void animatedJumpToPage(int page){
    final current = this.page?.round() ?? 0;
    if((current - page).abs() > 1){
      jumpToPage(page > current ? page - 1 : page + 1);
    }
    animateToPage(page, duration: const Duration(milliseconds: 300), curve: Curves.ease);
  }

  void jumpByDeviceType(int page) {
    if(StateController.find<ComicReadingPageLogic>().mouseScroll) {
      jumpToPage(page);
    } else {
      animatedJumpToPage(page);
    }
  }
}

class ComicReadingPageLogic extends StateController {
  ///控制页面, 用于非从上至下(连续)阅读方式
  late PageController pageController;

  ///用于从上至下(连续)阅读方式, 跳转至指定项目
  var itemScrollController = ItemScrollController();

  ///用于从上至下(连续)阅读方式, 获取当前滚动到的元素的序号
  var itemScrollListener = ItemPositionsListener.create();

  ///用于从上至下(连续)阅读方式, 控制滚动
  var scrollController = ScrollController(keepScrollOffset: true);

  ///用于从上至下(连续)阅读方式, 获取放缩大小
  PhotoViewController get photoViewController => photoViewControllers[index]
      ?? photoViewControllers[0]!;

  var photoViewControllers = <int, PhotoViewController>{};

  ListenVolumeController? listenVolume;

  ScrollManager? scrollManager;

  String? errorMessage;

  void clearPhotoViewControllers(){
    photoViewControllers.forEach((key, value) => value.dispose());
    photoViewControllers.clear();
  }

  bool noScroll = false;

  bool mouseScroll = false;

  double currentScale = 1.0;

  bool get isCtrlPressed => HardwareKeyboard.instance.isControlPressed;

  /// The page the reader is currently looking at, 1-based.
  ///
  /// Every image download asks [loadPriorityForPage] for its live priority, so
  /// this must change as soon as the visible page changes.
  int prefetchAnchor = 1;

  /// Incremented on every chapter change. Downloads from the previous chapter
  /// see a mismatching token and abort instead of competing with the new one.
  int chapterToken = 0;

  ReaderPrefetchScheduler? _prefetchScheduler;

  /// How many pages ahead the user asked for (settings[28], 0-15).
  int get preloadPageCount {
    final value = int.tryParse(appdata.settings[28]) ?? 2;
    return value.clamp(0, 15);
  }

  /// Priority of [page] (1-based) for the shared download pool.
  ///
  /// Negative means "the reader has moved away": the load is dropped even if
  /// it was already queued, and an in-flight download aborts. This is what
  /// stops a long gallery from loading the ten pages that were merely swiped
  /// past while the page in front of the user still waits.
  int loadPriorityForPage(int page) {
    if (urls.isEmpty) {
      return ImageLoadPriority.nearby;
    }
    final anchor = prefetchAnchor.clamp(1, urls.length).toInt();
    final distance = page - anchor;
    // One page behind is kept: it is the page the user just left, and an
    // accidental flip back should not start from zero. Anything further back
    // is off-screen in every reading mode.
    if (distance < -1) {
      return ImageLoadPriority.skip;
    }
    if (distance == 0) {
      return ImageLoadPriority.current;
    }
    if (distance == 1) {
      return ImageLoadPriority.adjacent;
    }
    if (distance < 0) {
      return ImageLoadPriority.nearby;
    }
    // Never drop a page that may still be built by the list: a continuous
    // reader can show several pages at once, and a page that starts loading
    // while visible must not be cancelled just because the user configured a
    // small preload window. Beyond this bound the page is either a stale
    // speculative request or far off-screen.
    const visibleAhead = 6;
    final aheadLimit =
        preloadPageCount > visibleAhead ? preloadPageCount : visibleAhead;
    if (distance <= aheadLimit) {
      return distance <= 2
          ? ImageLoadPriority.nearby
          : ImageLoadPriority.prefetch;
    }
    return ImageLoadPriority.skip;
  }

  /// Moves the download focus to [page].
  void updatePrefetchAnchor(int page) {
    if (urls.isEmpty) {
      prefetchAnchor = 1;
      return;
    }
    final next = page.clamp(1, urls.length).toInt();
    if (next == prefetchAnchor && _prefetchScheduler != null) {
      return;
    }
    prefetchAnchor = next;
    _prefetchScheduler?.onAnchorChanged();
  }

  /// Starts (or restarts) preloading once the page list is available.
  ///
  /// The scheduler loads the current page first and only then walks forward,
  /// so on a slow connection the visible page always has the whole link.
  void startPrefetch() {
    if (urls.isEmpty) return;
    prefetchAnchor = index.clamp(1, urls.length).toInt();
    (_prefetchScheduler ??= ReaderPrefetchScheduler(this)).start();
  }

  void stopPrefetch() {
    _prefetchScheduler?.dispose();
    _prefetchScheduler = null;
  }

  /// Invalidates downloads and preloading of the chapter being left.
  void _beginChapterTransition() {
    chapterToken++;
    stopPrefetch();
  }

  /// Provider for [page] (1-based) with its live download priority attached.
  ImageProvider imageProviderFor(int page) {
    final token = chapterToken;
    return data.createImageProvider(
      order,
      page - 1,
      urls[page - 1],
      priorityOf: () {
        if (token != chapterToken) return ImageLoadPriority.skip;
        return loadPriorityForPage(page);
      },
    );
  }

  bool haveUsedInitialPage = false;

  /// 双页模式下是否在第一页时显示单页
  bool get singlePageForFirstScreen => appdata.implicitData[1] == '1';

  var focusNode = FocusNode();

  static int _getIndex(int initPage) {
    if (appdata.settings[9] == "5" || appdata.settings[9] == "6") {
      return initPage % 2 == 1 ? initPage : initPage - 1;
    } else {
      return initPage;
    }
  }

  static int _getPage(int initPage) {
    if (appdata.settings[9] == "5" || appdata.settings[9] == "6") {
      return (initPage + 2) ~/ 2;
    } else {
      return initPage;
    }
  }

  ComicReadingPageLogic(this.order, this.data, int initialPage, this.updateHistory){
    if(initialPage <= 0){
      initialPage = 1;
    }
    pageController =
        PageController(initialPage: _getPage(initialPage));
    _index = _getIndex(initialPage);
    order <= 0 ? order = 1 : order;
    itemScrollListener.itemPositions.addListener(() {
      var newIndex = itemScrollListener.itemPositions.value.first.index + 1;
      if(newIndex != index) {
        index = newIndex;
        update(["ToolBar"]);
      }
    });
  }


  final void Function() updateHistory;

  ReadingData data;

  bool isLoading = true;

  ///旋转方向: null-跟随系统, false-竖向, true-横向
  bool? rotation;

  ///是否应该显示悬浮按钮, 为-1表示显示上一章, 为0表示不显示, 为1表示显示下一章
  int showFloatingButtonValue = 0;

  double fABValue = 0;

  void showFloatingButton(int value) {
    if (value == 0) {
      if (showFloatingButtonValue != 0) {
        showFloatingButtonValue = 0;
        fABValue = 0;
        update();
      }
    }
    if (value == 1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = 1;
      update();
    } else if (value == -1 && showFloatingButtonValue == 0 && order != 1) {
      showFloatingButtonValue = -1;
      update();
    }
  }

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  late int _index;

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  int get index => _index;

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  set index(int value) {
    _index = value;
    updatePrefetchAnchor(value);
    for (var element in _indexChangeCallbacks) {
      element(value);
    }
    updateHistory();
  }

  final _indexChangeCallbacks = <void Function(int)>[];

  void addIndexChangeCallback(void Function(int) callback){
    _indexChangeCallbacks.add(callback);
  }

  void removeIndexChangeCallback(void Function(int) callback){
    _indexChangeCallbacks.remove(callback);
  }

  ///当前的章节位置, 从1开始
  int order;

  ///工具栏是否打开
  bool tools = false;

  ///是否显示设置窗口
  bool showSettings = false;

  ///所有的图片链接
  var urls = <String>[];

  void reload() {
    _beginChapterTransition();
    index = 1;
    pageController = PageController(initialPage: 1);
    isLoading = true;
    update();
  }

  void change() {
    isLoading = !isLoading;
    update();
  }

  ReadingMethod get readingMethod =>
      ReadingMethod.values[int.parse(appdata.settings[9]) - 1];

  void jumpToNextPage() {
    if (readingMethod.index < 3) {
      pageController.jumpToPage(index + 1);
    } else if (readingMethod == ReadingMethod.topToBottomContinuously) {
      scrollController.jumpTo(scrollController.position.pixels + 600);
    } else {
      pageController.jumpToPage(pageController.page!.round() + 1);
    }
  }

  void jumpToLastPage() {
    if (readingMethod.index < 3) {
      pageController.jumpToPage(index - 1);
    } else if (readingMethod == ReadingMethod.topToBottomContinuously) {
      scrollController.jumpTo(scrollController.position.pixels - 600);
    } else {
      pageController.jumpToPage(pageController.page!.round() - 1);
    }
  }

  void jumpToPage(int i, [bool updateWidget = false]) {
    i = i.clamp(1, length);
    if (readingMethod == ReadingMethod.topToBottomContinuously) {
      itemScrollController.jumpTo(index: i - 1);
    } else if(!readingMethod.isTwoPage){
      pageController.jumpToPage(i);
    } else {
      var index = singlePageForFirstScreen ? i ~/ 2 + 1 : (i + 1) ~/ 2;
      pageController.jumpToPage(index);
    }
    if(index != i){
      index = i;
    }
    if(updateWidget){
      update(["ToolBar"]);
    }
  }

  void jumpByDeviceType(int page){
    Future.microtask(() {
      if(mouseScroll){
        pageController.jumpToPage(page);
      } else {
        pageController.animatedJumpToPage(page);
      }
    });
  }

  void jumpToNextChapter() {
    var eps = data.eps;
    showFloatingButtonValue = 0;
    if (!data.hasEp || order == eps?.length) {
      if(readingMethod != ReadingMethod.topToBottomContinuously){
        if (readingMethod.index < 3) {
          jumpByDeviceType(urls.length);
        } else if (readingMethod == ReadingMethod.twoPage) {
          jumpByDeviceType((urls.length % 2 + urls.length) ~/ 2);
        }
      } else {
        jumpToPage(urls.length);
        index = urls.length;
        update(["ToolBar"]);
      }
      return;
    }
    order += 1;
    urls = [];
    _beginChapterTransition();
    isLoading = true;
    tools = false;
    index = 1;
    pageController = PageController(initialPage: 1);
    clearPhotoViewControllers();
    update();
  }

  void jumpToChapter(int index){
    order = index;
    urls = [];
    _beginChapterTransition();
    isLoading = true;
    tools = false;
    this.index = 1;
    pageController = PageController(initialPage: 1);
    clearPhotoViewControllers();
    update();
  }

  void jumpToLastChapter() {
    showFloatingButtonValue = 0;
    if(order == 1 || !data.hasEp){
      if(readingMethod != ReadingMethod.topToBottomContinuously){
        jumpByDeviceType(1);
      } else {
        jumpToPage(1);
        index = 1;
        update(["ToolBar"]);
      }
      return;
    }

    order -= 1;
    urls = [];
    _beginChapterTransition();
    isLoading = true;
    tools = false;
    pageController = PageController(initialPage: 1);
    index = 1;
    clearPhotoViewControllers();
    update();
  }

  ///当前章节的长度
  int get length => urls.length;

  /// 是否处于自动翻页状态
  bool runningAutoPageTurning = false;

  /// 自动翻页
  void autoPageTurning() async {
    if (index == urls.length - 1) {
      runningAutoPageTurning = false;
      update();
      return;
    }
    int sec = int.parse(appdata.settings[33]);
    for (int i = 0; i < sec * 10; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!runningAutoPageTurning) {
        return;
      }
    }
    jumpToNextPage();
    autoPageTurning();
  }

  void refresh_() {
    pageController = PageController(initialPage: 1);
    itemScrollController = ItemScrollController();
    itemScrollListener = ItemPositionsListener.create();
    scrollController = ScrollController(keepScrollOffset: true);
    clearPhotoViewControllers();
    noScroll = false;
    currentScale = 1.0;
    showFloatingButtonValue = 0;
    index = 1;
    urls.clear();
    _beginChapterTransition();
    isLoading = true;
    tools = false;
    showSettings = false;
    update();
  }

  bool isFullScreen = false;

  void fullscreen(){
    const channel = MethodChannel("pica_comic/full_screen");
    channel.invokeMethod("set", !isFullScreen);
    isFullScreen = !isFullScreen;
    focusNode.requestFocus();

    if(isFullScreen){
      StateController.find<WindowFrameController>().hideWindowFrame();
    } else {
      StateController.find<WindowFrameController>().showWindowFrame();
    }
  }

  void handleKeyboard(KeyEvent event) {
    if(event is KeyDownEvent || event is KeyRepeatEvent){
      bool reverse = appdata.settings[9] == "2" || appdata.settings[9] == "6";
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.arrowRight:
          reverse ? jumpToLastPage(): jumpToNextPage();
        case LogicalKeyboardKey.arrowUp:
        case LogicalKeyboardKey.arrowLeft:
          reverse ? jumpToNextPage(): jumpToLastPage();
        case LogicalKeyboardKey.f12:
          fullscreen();
      }
    }
  }

  late final void Function() openEpsView;
}
