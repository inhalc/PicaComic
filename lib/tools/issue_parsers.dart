/// #230 / #277 / #39 / #280 相关解析逻辑的纯函数集合。
///
/// 这些函数不依赖 Flutter / 网络 / DOM，便于单独单元测试。

/// 从 nhentai 分页链接中解析「最后一页」页码。
///
/// 链接形如 `/search/?q=<关键词>&page=3`。关键词里可能含有数字，
/// 旧实现用 `.nums` 把整条链接里的所有数字拼起来，会得到一个超过
/// 64 位整数上限的超长数字，`int.parse` 因此抛出
/// `FormatException: Positive input exceeded limit of integer` (#230)。
/// 这里只读取 `page` 查询参数，并对异常长度/解析失败做兜底。
int parseLastPage(String? href) {
  if (href == null || href.isEmpty) {
    return 1;
  }
  final match = RegExp(r'[?&]page=(\d+)').firstMatch(href);
  if (match == null) {
    return 1;
  }
  final value = match.group(1)!;
  if (value.length > 9) {
    return 1;
  }
  return int.tryParse(value) ?? 1;
}

/// 为搜索词追加/替换自动语言筛选后缀 (#277)。
///
/// [enableFilter] 表示该漫画源是否启用语言筛选；[langSetting] 取
/// 1/2/3 对应 chinese/english/japanese，0 或其它值视为不启用。
/// 启用时先清掉已有的 `language:` 后缀，保证重复调用不会不断叠加；
/// 未启用时**原样返回**，不能把用户手动输入的 `language:japanese`
/// 之类的筛选条件悄悄删掉。
String applyAutoLanguage(String keyword, bool enableFilter, int langSetting) {
  const languages = <int, String>{
    1: 'chinese',
    2: 'english',
    3: 'japanese',
  };
  final language = languages[langSetting];
  if (!enableFilter || language == null) {
    return keyword;
  }
  final cleaned = keyword.replaceAll(RegExp(r'\s*language:\w+'), '').trim();
  return '$cleaned language:$language';
}

/// 把从 `div.fp` 提取到的收藏夹名称整理为恰好 10 项 (#39)。
///
/// 旧实现写的是 `if (names.length != 10) names = names.sublist(0, 10)`：
/// 解析到少于 10 个收藏夹时 `sublist` 直接抛 RangeError，又被调用处的
/// catch 静默吞掉，导致「比较并写回 folderNames」整段不执行，用户改过的
/// 收藏夹名永远刷不出来。这里只做补齐/截断，不改名称文本（名称里已经
/// 拼好了 `(数量)`）。下游 `ehentai.dart` 依赖 `folderNames` 恒为 10 项。
List<String> parseFavoriteNames(List<String> rawNames) {
  final result = <String>[];
  for (var i = 0; i < 10; i++) {
    if (i >= rawNames.length) {
      result.add('Favorite $i');
      continue;
    }
    final text = rawNames[i].trim();
    result.add(text.isEmpty ? 'Favorite $i' : text);
  }
  return result;
}

/// #280 解析结果：nozomi 查询所需的 area / tag / language。
class TermAndLanguage {
  final String? area;
  final String tag;
  final String language;

  const TermAndLanguage(this.area, this.tag, this.language);
}

/// 解析 Hitomi 的 `namespace:tag` 搜索项 (#280)。
///
/// 标签内部可能含冒号，因此用 `sublist(1).join(':')` 取标签部分，
/// 而不是 `split(':')[1]`；`female` / `male` 命名空间下 tag 必须是
/// 完整的原始 term（旧实现误写成 `term[0]`，只取了首字符）。
TermAndLanguage resolveTermAndLanguage(String term, String language) {
  final parts = term.split(':');
  final ns = parts.first;
  final rest = parts.sublist(1).join(':');
  String? area = ns;
  var tag = rest;

  if (ns == 'female' || ns == 'male') {
    area = 'tag';
    tag = term;
  }
  return TermAndLanguage(area, tag, language);
}
