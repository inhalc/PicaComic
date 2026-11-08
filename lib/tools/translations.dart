import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/app.dart';

extension AppTranslation on String {
  String _translate() {
    var locale = App.locale;
    var key = "${locale.languageCode}_${locale.countryCode}";
    if (locale.languageCode == "en") {
      key = "en_US";
    }
    return (translations[key]?[this]) ?? this;
  }

  String get tl => _translate();

  String get tlEN => translations["en_US"]?[this] ?? this;

  String tlParams(Map<String, String> values) {
    var res = _translate();
    for (var entry in values.entries) {
      res = res.replaceFirst("@${entry.key}", entry.value);
    }
    return res;
  }

  /// Never `late`: if the asset fails to load (or another initialiser throws
  /// before this one runs), widgets calling `.tl` used to crash the whole app
  /// with LateInitializationError before any page could be drawn (#291/#302).
  /// An empty map simply falls back to the source string.
  static Map<String, Map<String, String>> translations = {};

  static Future<void> init() async{
    try {
      var data = await rootBundle.load("assets/translation.json");
      var json = jsonDecode(utf8.decode(data.buffer.asUint8List()));
      translations = {
        for (var e in json.entries) e.key: Map<String, String>.from(e.value)
      };
    } catch (_) {
      // Keep the app usable with untranslated strings.
      translations = {};
    }
  }
}

extension ListTranslation on List<String> {
  List<String> _translate() {
    return List.generate(length, (index) => this[index].tl);
  }

  List<String> get tl => _translate();
}
