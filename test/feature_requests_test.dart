import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/pages/download_page.dart';
import 'package:pica_comic/tools/hitomi_query.dart';
import 'package:pica_comic/tools/hitomi_sort.dart';
import 'package:pica_comic/tools/jm_domain_input.dart';

class _FakeDownloaded extends DownloadedItem {
  _FakeDownloaded(this.name, {this.subTitle = '', this.tags = const []});

  @override
  final String name;

  @override
  final String subTitle;

  @override
  final List<String> tags;

  @override
  DownloadType get type => DownloadType.ehentai;

  @override
  List<String> get eps => const [];

  @override
  List<int> get downloadedEps => const [];

  @override
  String get id => name;

  @override
  double? comicSize;

  @override
  DateTime? time;

  @override
  Map<String, dynamic> toJson() => {};
}

void main() {
  group('downloaded comic search (#108)', () {
    DownloadPageLogic logicWith(List<DownloadedItem> items) {
      final logic = DownloadPageLogic();
      logic.baseComics = items;
      return logic;
    }

    test('finds a comic by one of its tags', () {
      final logic = logicWith([
        _FakeDownloaded('some title', tags: ['female:big breasts', 'language:chinese']),
        _FakeDownloaded('other title', tags: ['male:sole male']),
      ]);
      logic.keyword = 'big breasts';
      logic.find();
      expect(logic.comics.map((e) => e.name), ['some title']);
    });

    test('still finds a comic by title and author', () {
      final logic = logicWith([
        _FakeDownloaded('Some Title', subTitle: 'some artist'),
      ]);
      logic.keyword = 'some artist';
      logic.find();
      expect(logic.comics, hasLength(1));
    });

    test('an empty keyword lists everything again', () {
      final logic = logicWith([
        _FakeDownloaded('a', tags: ['x']),
        _FakeDownloaded('b'),
      ]);
      logic.keyword = 'x';
      logic.find();
      expect(logic.comics, hasLength(1));
      logic.keyword = '';
      logic.find();
      expect(logic.comics, hasLength(2));
    });
  });

  group('hitomi result order (#281)', () {
    test('newest first sorts descending', () {
      expect(sortHitomiIds([5, 3, 9, 1], HitomiSortOrder.newestFirst),
          [9, 5, 3, 1]);
    });

    test('oldest first sorts ascending', () {
      expect(sortHitomiIds([5, 3, 9, 1], HitomiSortOrder.oldestFirst),
          [1, 3, 5, 9]);
    });

    test('an already ordered index is returned untouched', () {
      final ids = [9, 5, 3, 1];
      expect(identical(sortHitomiIds(ids, HitomiSortOrder.newestFirst), ids),
          isTrue,
          reason: 'the index is already newest first, re-sorting is waste');
      final ascending = [1, 3, 5, 9];
      expect(
          identical(sortHitomiIds(ascending, HitomiSortOrder.oldestFirst),
              ascending),
          isTrue);
    });

    test('empty and single entry lists are safe', () {
      expect(sortHitomiIds([], HitomiSortOrder.oldestFirst), isEmpty);
      expect(sortHitomiIds([7], HitomiSortOrder.oldestFirst), [7]);
    });
  });

  group('hitomi suggestion syntax (#242)', () {
    test('a multi-word tag becomes one underscore term', () {
      expect(hitomiSuggestionTerm('big breasts', 'other'), 'big_breasts');
      expect(hitomiSuggestionTerm('big breasts', null), 'big_breasts');
    });

    test('only namespaces hitomi indexes are prefixed', () {
      expect(hitomiSuggestionTerm('big breasts', 'female'), 'female:big_breasts');
      expect(hitomiSuggestionTerm('genshin impact', 'parody'),
          'parody:genshin_impact');
      expect(hitomiSuggestionTerm('chinese', 'language'), 'language:chinese');
      expect(hitomiSuggestionTerm('big breasts', 'mixed'), 'big_breasts',
          reason: 'hitomi has no /n/mixed/ area, a prefix would 404');
      expect(hitomiSuggestionTerm('someone', 'cosplayer'), 'someone');
    });
  });

  group('jm domain input (#226)', () {    test('drops the scheme and path the user pasted', () {
      expect(
        parseJmDomainInput(
            'https://www.a.org/\nhttp://www.b.org/some/path\nwww.c.org'),
        ['www.a.org', 'www.b.org', 'www.c.org'],
      );
    });

    test('accepts commas, Chinese commas and blank lines', () {
      expect(
        parseJmDomainInput('a.org, b.org，c.org\n\n  ,  '),
        ['a.org', 'b.org', 'c.org'],
      );
    });

    test('removes duplicates but keeps the first occurrence order', () {
      expect(parseJmDomainInput('b.org\na.org\nb.org'), ['b.org', 'a.org']);
    });

    test('update urls keep their scheme and gain https when missing', () {
      expect(
        parseJmUpdateUrlInput('https://a.org/x.txt\nb.org/y.txt'),
        ['https://a.org/x.txt', 'https://b.org/y.txt'],
      );
    });
  });
}
