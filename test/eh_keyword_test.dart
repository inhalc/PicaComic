import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/eh_keyword.dart';

void main() {
  group('e-hentai OR keyword normalization', () {
    test('a plain keyword is only whitespace-normalized', () {
      expect(normalizeEhOrKeyword('  big   breasts '), 'big breasts');
      expect(normalizeEhOrKeyword('artist:foo'), 'artist:foo');
    });

    test('a quoted namespace OR group becomes a prefix match', () {
      expect(
        normalizeEhOrKeyword('female:"big breasts | small breasts"'),
        'female:"big breasts\$"',
      );
    });

    test('a title containing " | " does not crash the search', () {
      // "Similar galleries" searches by title. A title such as
      // "Chel | The Road to El Dorado" has an OR separator but no namespace;
      // the old code indexed split(':')[1] and threw a RangeError, leaving
      // the results page spinning forever.
      expect(
        normalizeEhOrKeyword('Chel | The Road to El Dorado'),
        'Chel | The Road to El Dorado',
      );
      expect(
        normalizeEhOrKeyword('"Chel | The Road to El Dorado"'),
        '"Chel | The Road to El Dorado"',
      );
    });

    test('unquoted and multi-colon tokens are left alone', () {
      expect(
        normalizeEhOrKeyword('female:big | small'),
        'female:big | small',
      );
      expect(
        normalizeEhOrKeyword('a:b:"c | d"'),
        'a:b:"c | d"',
      );
    });

    test('several tokens keep their order', () {
      expect(
        normalizeEhOrKeyword(
            'misc:foo female:"tag a | tag b" plain "Chel | Road"'),
        'misc:foo female:"tag a\$" plain "Chel | Road"',
      );
    });
  });
}
