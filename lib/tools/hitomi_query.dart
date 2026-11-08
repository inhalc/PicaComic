/// Query building for hitomi's local index search (#242).
///
/// hitomi does not understand the quoted phrase syntax other sources use:
/// `HitomiSearch` lowercases the keyword, splits it on whitespace and looks up
/// every term on its own, replacing `_` with a space before the lookup. So a
/// multi-word tag has to be written `big_breasts`, not `"big breasts"`, and a
/// namespaced tag has to be `female:big_breasts`.
library;

/// Tag namespaces hitomi keeps as their own index area.
///
/// `female`/`male` are special: hitomi stores them *inside* the tag name under
/// the shared `tag` area, which is handled by `HitomiSearch.getGalleryIdsForQuery`.
const _hitomiNamespaces = {
  'female',
  'male',
  'parody',
  'character',
  'artist',
  'group',
  'language',
};

/// Turns a tag suggestion into a hitomi search term.
///
/// [translationType] is the suggestion's `TranslationType.name`; only the
/// namespaces hitomi actually indexes are added as a prefix, because e.g.
/// `other:big breasts` would be looked up under `/n/other/` and return nothing.
String hitomiSuggestionTerm(String tag, String? translationType) {
  final term = tag.replaceAll(' ', '_');
  if (translationType != null && _hitomiNamespaces.contains(translationType)) {
    return '$translationType:$term';
  }
  return term;
}
