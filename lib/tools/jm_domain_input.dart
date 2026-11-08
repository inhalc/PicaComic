/// Input handling for the JM (禁漫) domain settings (#226).
///
/// Both settings are free-text typed by the user, so everything here is about
/// turning what a person actually pastes into what the network layer expects.
library;

/// Splits [input] on commas, semicolons and newlines, trimming each entry.
List<String> _splitEntries(String input) {
  return input
      .split(RegExp(r'[,，;；\r\n]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

/// API domains as typed by the user.
///
/// The JM client builds `https://<domain>`, so a pasted `https://www.a.org/`
/// must lose its scheme and any path, otherwise every request becomes
/// `https://https://www.a.org//...`. Order is preserved and duplicates are
/// dropped, because the selected domain is stored as an index into this list.
List<String> parseJmDomainInput(String input) {
  final result = <String>[];
  for (final entry in _splitEntries(input)) {
    var domain = entry;
    final scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').firstMatch(domain);
    if (scheme != null) {
      domain = domain.substring(scheme.end);
    }
    domain = domain.split('/').first;
    if (domain.isEmpty) continue;
    if (result.contains(domain)) continue;
    result.add(domain);
  }
  return result;
}

/// Update URLs for the domain list, as typed by the user.
///
/// Unlike domains these are full URLs (the file is fetched as-is), so the
/// scheme is kept. Entries without one get `https://` added: people type
/// `example.com/newsvr.txt` far more often than they type the scheme.
List<String> parseJmUpdateUrlInput(String input) {
  final result = <String>[];
  for (final entry in _splitEntries(input)) {
    var url = entry;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
      url = 'https://$url';
    }
    if (result.contains(url)) continue;
    result.add(url);
  }
  return result;
}
