/// 纯 UI 状态判定与推进逻辑。
///
/// 本文件刻意不依赖 Flutter，便于用纯 Dart 单元测试直接覆盖
/// (#75 / #252 / #169 / #53)。

/// #75：桌面端按 ESC 是否应触发一次返回。
///
/// [rootCanPop] 为根 Navigator 能否 pop；[mainCanPop] 为主界面子 Navigator
/// 能否 pop。两者都为 false 时返回 false（什么都不做）；否则若仍无条件 pop，
/// 会把子 Navigator 栈弹空导致黑屏且无法恢复。
bool shouldPopOnEscape({
  required bool rootCanPop,
  required bool mainCanPop,
}) {
  return rootCanPop || mainCanPop;
}

/// #252：收藏页从 implicitData 字符串解析出的三态。
class FavoritesPageState {
  final bool selectingFolder;

  /// null 表示未选择任何收藏夹；true 为网络收藏夹；false 为本地收藏夹。
  final bool? isNetwork;

  /// 当前收藏夹名，null 表示未选择。
  final String? current;

  const FavoritesPageState({
    required this.selectingFolder,
    required this.isNetwork,
    required this.current,
  });

  /// 危险组合：已进入某个收藏夹却不知道它是网络还是本地，
  /// buildContent 里的 `isNetwork!` 会在此组合下抛空值异常 (#252)。
  bool get hasDangerousCombination => current != null && isNetwork == null;
}

/// #252：解析 implicitData[0]，格式大致为 `select;network;folder...`。
///
/// - 字段缺失时安全兜底，不越界；
/// - 分号允许出现在收藏夹名中（保留 join 语义）；
/// - 绝不返回 [FavoritesPageState.hasDangerousCombination] 为 true 的结果：
///   当 current 有值但 isNetwork 字段缺失时，兜底按本地收藏夹处理。
FavoritesPageState parseFavoritesPageState(String implicitData) {
  final parts = implicitData.split(';');
  String field(int i) => i < parts.length ? parts[i] : '';

  final selectingFolder = field(0) == '1';
  bool? isNetwork;
  final networkField = field(1);
  if (networkField == '') {
    isNetwork = null;
  } else {
    isNetwork = networkField == '1';
  }

  final rawCurrent =
      parts.length > 3 ? parts.sublist(2).join(';') : field(2);
  String? current = rawCurrent.isEmpty ? null : rawCurrent;

  // 关键：消解 current != null && isNetwork == null 的危险组合。
  if (current != null && isNetwork == null) {
    isNetwork = false;
  }

  return FavoritesPageState(
    selectingFolder: selectingFolder,
    isNetwork: isNetwork,
    current: current,
  );
}

/// #169：一次分页加载结果的分类。
enum PageLoadOutcome { successNonEmpty, emptyPage, error }

/// #169：分页推进的纯状态，不依赖 Flutter。
///
/// 生产代码 ComicsPageLogic 保留原有字段名，把一次加载结果交给本类推进后，
/// 再把 [current] / [maxPage] / [emptyPageCount] / [message] 同步回去。
class PaginationState {
  int current;
  int? maxPage;
  int emptyPageCount;
  String? message;

  /// 是否停止自动加载（错误或空页收敛后置为 true）。
  bool stopped;

  PaginationState({
    this.current = 1,
    this.maxPage,
    this.emptyPageCount = 0,
    this.message,
    this.stopped = false,
  });

  /// 是否还应发起下一页请求：current >= maxPage、出错或已停止时都不再请求。
  bool get canRequestNext {
    final max = maxPage; // 局部变量才能被类型提升
    return !stopped && message == null && (max == null || current < max);
  }

  /// 根据一次加载结果推进状态。
  ///
  /// - 只有成功且非空才推进 [current]；
  /// - 连续空页达到 [emptyPageThreshold] 时**无条件**把 [maxPage] 收敛到
  ///   [current] 并停止，不受 maxPage 是否已非 null 影响（修复 #169 根因）；
  /// - 错误时设置 [message]、停止自动加载且不推进 [current]。
  void applyResult({
    required PageLoadOutcome outcome,
    int? serverMaxPage,
    String? errorMessage,
    int emptyPageThreshold = 2,
  }) {
    if (outcome == PageLoadOutcome.error) {
      message = errorMessage;
      stopped = true;
      return;
    }
    // 服务端返回 int 型总页数时更新 maxPage。
    if (serverMaxPage != null) {
      maxPage = serverMaxPage;
    }
    if (outcome == PageLoadOutcome.successNonEmpty) {
      emptyPageCount = 0;
      current++;
    } else {
      // 成功但为空页：不推进 current。
      emptyPageCount++;
      if (emptyPageCount >= emptyPageThreshold) {
        maxPage = current;
        stopped = true;
      }
    }
  }
}

/// #53：对漫画图片路径排序，过滤非图片/隐藏文件，并对非数字名稳定兜底。
///
/// - 过滤：info.json、cover.*、隐藏文件（以 '.' 开头，如 .DS_Store）、
///   非图片扩展名（如 Thumbs.db）；
/// - 数字名（1.jpg / 10.png ...）用 int.tryParse 按数字升序；
/// - 非数字名按文件名字符串升序，排在数字名之后；相同则保持原顺序（稳定）；
/// - 返回原始完整路径，保持跨章节路径语义（调用方逐章节调用本函数）。
List<String> reorderImagePaths(List<String> paths) {
  const imageExtensions = {
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp',
    'avif', 'avifs', 'heic', 'heif', 'jxl', 'tif', 'tiff',
  };
  // Only clearly non-image sidecar files are dropped. Unknown extensions with
  // a numeric name are kept: downloaded pages are named "1.xxx", "2.xxx", ...
  // and must not disappear just because the source used an unusual format.
  const nonImageExtensions = {
    'json', 'db', 'txt', 'xml', 'ini', 'log', 'tmp', 'yml', 'yaml', 'md',
    'part', 'cfg', 'dat',
  };

  bool isImage(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return true; // 无扩展名, 按原行为保留
    final ext = name.substring(dot + 1).toLowerCase();
    if (imageExtensions.contains(ext)) return true;
    if (nonImageExtensions.contains(ext)) return false;
    return int.tryParse(name.substring(0, dot)) != null;
  }

  String baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final i = normalized.lastIndexOf('/');
    return i < 0 ? normalized : normalized.substring(i + 1);
  }

  int? numericKey(String name) => int.tryParse(name.split('.').first);

  // 保留 原 index -> path，便于稳定兜底。
  final kept = <int, String>{};
  for (var i = 0; i < paths.length; i++) {
    final name = baseName(paths[i]);
    if (name.isEmpty) continue;
    if (name.startsWith('.')) continue;
    final lower = name.toLowerCase();
    if (lower == 'info.json') continue;
    if (lower.startsWith('cover.')) continue;
    if (!isImage(name)) continue;
    kept[i] = paths[i];
  }

  final indices = kept.keys.toList();
  int? numOf(int idx) => numericKey(baseName(kept[idx]!));
  indices.sort((a, b) {
    final na = numOf(a);
    final nb = numOf(b);
    if (na != null && nb != null) {
      final c = na.compareTo(nb);
      return c != 0 ? c : a.compareTo(b);
    }
    if (na != null) return -1; // 数字名排在非数字名前
    if (nb != null) return 1;
    final c = baseName(kept[a]!).compareTo(baseName(kept[b]!));
    return c != 0 ? c : a.compareTo(b);
  });
  return indices.map((i) => kept[i]!).toList();
}
