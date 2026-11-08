import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';

/// A backup produced by an older build, before the onboarding wizard had
/// been completed. Its `firstUse[3]` is "0" and it only has 90 settings.
Map<String, dynamic> oldExport() {
  final settings = List<String>.filled(90, "0");
  settings[46] = "1794115574";
  return <String, dynamic>{
    "settings": settings,
    "firstUse": <String>["1", "1", "1", "0", "1"],
    "blockingKeywords": <String>[],
    "favoriteTags": <String>[],
  };
}

void main() {
  test('importing data never resets the onboarding flag', () {
    final appdata = Appdata();
    appdata.firstUse[3] = "1";
    appdata.welcomeCompleted = true;

    final ok = appdata.readDataFromJson(oldExport());

    expect(ok, isTrue);
    expect(appdata.firstUse[3], "1");
    expect(appdata.welcomeCompleted, isTrue);
  });

  test('onboarding flag is not part of the exported data', () {
    final appdata = Appdata();
    appdata.welcomeCompleted = true;

    expect(appdata.toJson().containsKey(welcomeCompletedKey), isFalse);
  });

  test('a shorter export keeps settings added by newer builds', () {
    final appdata = Appdata();
    appdata.settings[91] = "1";

    final ok = appdata.readDataFromJson(oldExport());

    expect(ok, isTrue);
    expect(appdata.settings.length, greaterThan(91));
    expect(appdata.settings[91], "1");
  });
}
