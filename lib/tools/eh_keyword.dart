import 'dart:collection';

/// Splits a search string on spaces, keeping quoted strings together.
///
/// A tag such as `female:"big breasts | small breasts"` must stay in one
/// token; otherwise the OR group below would be torn apart.
List<String> splitEhKeyword(String keyword) {
  var res = <String>[];
  var buffer = StringBuffer();
  var qs = Queue<String>();
  for (int i = 0; i < keyword.length; i++) {
    var char = keyword[i];
    if (char == '"' || char == "'") {
      if (qs.isEmpty) {
        qs.add(char);
      } else {
        if (qs.first == char) {
          qs.removeFirst();
        } else {
          qs.add(char);
        }
      }
    }
    if (char == ' ') {
      if (qs.isEmpty) {
        res.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty) {
    res.add(buffer.toString());
  }
  return res;
}

/// Rewrites OR groups in an e-hentai search keyword.
///
/// e-hentai has no OR operator. The app lets a user write
/// `female:"a | b"` and converts it into a prefix match on the first
/// alternative. Only a token with exactly one namespace separator and a
/// quoted value is rewritten; everything else is kept verbatim.
///
/// The upstream implementation read `split(':')[1]` before checking that a
/// separator existed. A gallery title containing " | " (used by the "similar
/// galleries" action) therefore crashed with
/// `RangeError (length): Invalid value: Only valid value is 0: 1`, leaving the
/// search results page spinning forever.
String normalizeEhOrKeyword(String keyword) {
  keyword = keyword.replaceAll(RegExp(r"\s+"), " ").trim();
  if (!keyword.contains(" | ")) {
    return keyword;
  }
  final result = <String>[];
  for (final token in splitEhKeyword(keyword)) {
    if (!token.contains(' | ')) {
      result.add(token);
      continue;
    }
    final parts = token.split(':');
    final value = parts.length == 2 ? parts[1] : '';
    final quoted = value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")));
    if (!quoted) {
      // No namespace, no quotes, or multiple colons: leave it alone instead
      // of indexing past the end of the list or stripping real characters.
      result.add(token);
      continue;
    }
    final first = value.substring(1, value.length - 1).split(' | ').first;
    result.add('${parts[0]}:"$first\$"');
  }
  return result.join(' ');
}
