import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_main_network.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/tools/hitomi_sort.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shimmer_animation/shimmer_animation.dart';

import '../../foundation/app.dart';
import '../../network/res.dart';
import '../search_result_page.dart';

class SearchPageComicList extends StatefulWidget {
  const SearchPageComicList(
      {super.key,
      required this.keyword,
      required this.head,
      this.sort = HitomiSortOrder.newestFirst});

  final String keyword;

  final Widget head;

  /// Applied to the ids returned by the hitomi index (#281).
  final HitomiSortOrder sort;

  @override
  State<SearchPageComicList> createState() => _SearchPageComicListState();
}

class _SearchPageComicListState
    extends LoadingState<SearchPageComicList, List<int>> {
  @override
  Widget buildContent(BuildContext context, List<int> data) {
    final ids = sortHitomiIds(data, widget.sort);
    return SmoothCustomScrollView(
      slivers: [
        widget.head,
        SliverGrid(
          delegate: SliverChildBuilderDelegate(
            // Keyed by id: a tile keeps its loaded comic in state, so without
            // this the grid would keep showing the covers it loaded for the
            // previous positions after the order changes (#281).
            (context, index) => HitomiComicTileDynamicLoading(
              ids[index],
              key: ValueKey(ids[index]),
            ),
            childCount: ids.length,
          ),
          gridDelegate: SliverGridDelegateWithComics(),
        ),
      ],
    );
  }

  @override
  Future<Res<List<int>>> loadData() {
    return HiNetwork().search(widget.keyword);
  }
}

class HitomiSearchPage extends StatefulWidget {
  const HitomiSearchPage(this.keyword, {Key? key}) : super(key: key);
  final String keyword;

  @override
  State<HitomiSearchPage> createState() => _HitomiSearchPageState();
}

class _HitomiSearchPageState extends State<HitomiSearchPage> {
  late String keyword;
  var controller = TextEditingController();
  var sort = HitomiSortOrder.newestFirst;

  @override
  void initState() {
    keyword = widget.keyword;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    controller.text = keyword;
    return SearchPageComicList(
      keyword: keyword,
      sort: sort,
      key: Key(keyword),
      head: SliverPersistentHeader(
        floating: true,
        delegate: _SliverAppBarDelegate(
          minHeight: 60,
          maxHeight: 0,
          child: FloatingSearchBar(
            trailing: IconButton(
              icon: const Icon(Icons.more_horiz),
              onPressed: showMoreActions,
            ),
            onSearch: (s) {
              App.back(context);
              if (s == "") return;
              setState(() {
                keyword = s;
              });
            },
            controller: controller,
          ),
        ),
      ),
    ).paddingTop(context.padding.top);
  }

  /// The same menu every other source's search page has (#281).
  ///
  /// hitomi used to own a stripped-down search page, so switching the source of
  /// a query or reordering the results was impossible without typing it again.
  void showMoreActions() {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 48,
        56,
        0,
        0,
      ),
      items: [
        PopupMenuItem(value: 0, child: Text("切换源".tl)),
        PopupMenuItem(value: 1, child: Text("排序".tl)),
      ],
    ).then((value) {
      if (value == 0) {
        changeSource();
      } else if (value == 1) {
        showSortOptions();
      }
    });
  }

  void changeSource() {
    var sources =
        ComicSource.sources.where((e) => e.searchPageData != null).toList();
    var picked = 'hitomi';
    showDialog(
      useSafeArea: false,
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "切换源".tl,
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var source in sources)
                    RadioListTile<String>(
                      title: Text(source.name),
                      value: source.key,
                      groupValue: picked,
                      onChanged: (value) {
                        setState(() {
                          picked = value!;
                        });
                      },
                    )
                ],
              ),
            ),
            actions: [
              Button.filled(
                child: Text("确认".tl),
                onPressed: () {
                  context.pop();
                  if (picked == 'hitomi') return;
                  // The generic page applies the language filter of the new
                  // source itself, so the raw keyword is passed through.
                  App.off(
                    this.context,
                    () => SearchResultPage(keyword: keyword, sourceKey: picked),
                  );
                },
              )
            ],
          );
        });
      },
    );
  }

  void showSortOptions() {
    showDialog(
      useSafeArea: false,
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setDialogState) {
          return ContentDialog(
            title: "排序".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var order in HitomiSortOrder.values)
                  RadioListTile<HitomiSortOrder>(
                    title: Text(order.label.tl),
                    value: order,
                    groupValue: sort,
                    onChanged: (value) {
                      setDialogState(() {
                        sort = value!;
                      });
                      setState(() {});
                    },
                  )
              ],
            ),
            actions: [
              Button.filled(
                child: Text("确认".tl),
                onPressed: () => context.pop(),
              )
            ],
          );
        });
      },
    );
  }
}

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverAppBarDelegate(
      {required this.child, required this.maxHeight, required this.minHeight});

  final double minHeight;
  final double maxHeight;
  final Widget child;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox.expand(
      child: child,
    );
  }

  @override
  double get maxExtent => minHeight;

  @override
  double get minExtent => max(maxHeight, minHeight);

  @override
  bool shouldRebuild(SliverPersistentHeaderDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxExtent ||
        minHeight != oldDelegate.minExtent;
  }
}

class HitomiComicTileDynamicLoading extends StatefulWidget {
  const HitomiComicTileDynamicLoading(this.id,
      {Key? key, this.addonMenuOptions})
      : super(key: key);
  final int id;

  final List<ComicTileMenuOption>? addonMenuOptions;

  @override
  State<HitomiComicTileDynamicLoading> createState() =>
      _HitomiComicTileDynamicLoadingState();
}

class _HitomiComicTileDynamicLoadingState
    extends State<HitomiComicTileDynamicLoading> {
  HitomiComicBrief? comic;
  bool onScreen = true;

  /// Loaded tiles, keyed by gallery id.
  ///
  /// Was a list that had to be scanned (and regex-parsed) for every tile of
  /// every build, and grew without bound for as long as the app ran. A map
  /// makes the lookup free and lets the oldest entries be dropped.
  static final Map<int, HitomiComicBrief> cache = {};
  static const _cacheLimit = 400;

  @override
  void dispose() {
    onScreen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    comic = cache[widget.id];
    if (comic == null) {
      HiNetwork().getComicInfoBrief(widget.id.toString()).then((c) {
        if (c.error) {
          showToast(message: c.errorMessage!);
          return;
        }
        if (cache.length >= _cacheLimit) {
          cache.remove(cache.keys.first);
        }
        cache[widget.id] = c.data;
        if (onScreen) {
          setState(() {
            comic = c.data;
          });
        }
      });

      return buildLoadingWidget();
    } else {
      return buildComicTile(context, comic!, 'hitomi');
    }
  }

  Widget buildPlaceHolder() {
    return const ComicTilePlaceholder();
  }

  Widget buildLoadingWidget() {
    return Shimmer(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: buildPlaceHolder(),
    );
  }
}
