/// Ordering choices for hitomi search results (#281).
///
/// hitomi has no server-side sort parameter for the index files this client
/// reads, so ordering is applied to the returned ids. Gallery ids grow over
/// time, which makes them a reliable upload-time key.
enum HitomiSortOrder {
  /// Newest gallery first — the order hitomi itself shows.
  newestFirst,

  /// Oldest gallery first, for reading a tag from its beginning.
  oldestFirst,
}

extension HitomiSortOrderLabel on HitomiSortOrder {
  /// Translation key of the menu entry.
  ///
  /// Not called `name`: every enum already has `name`, and an extension member
  /// never wins over the instance getter.
  String get label => switch (this) {
        HitomiSortOrder.newestFirst => '最新在前',
        HitomiSortOrder.oldestFirst => '最旧在前',
      };
}

/// Sorts the ids returned by a hitomi index according to [order].
///
/// The index files are already written newest first, so that case is detected
/// and passed through untouched: sorting ten thousand ids on every rebuild for
/// an order that is already correct would be pure waste.
List<int> sortHitomiIds(List<int> ids, HitomiSortOrder order) {
  if (ids.length < 2) {
    return ids;
  }
  final ascending = _isAscending(ids);
  final alreadyOrdered = switch (order) {
    HitomiSortOrder.newestFirst => _isDescending(ids),
    HitomiSortOrder.oldestFirst => ascending,
  };
  if (alreadyOrdered) {
    return ids;
  }
  final sorted = List<int>.of(ids)
    ..sort(order == HitomiSortOrder.newestFirst
        ? (a, b) => b.compareTo(a)
        : (a, b) => a.compareTo(b));
  return sorted;
}

bool _isAscending(List<int> ids) {
  for (var i = 1; i < ids.length; i++) {
    if (ids[i] < ids[i - 1]) return false;
  }
  return true;
}

bool _isDescending(List<int> ids) {
  for (var i = 1; i < ids.length; i++) {
    if (ids[i] > ids[i - 1]) return false;
  }
  return true;
}
