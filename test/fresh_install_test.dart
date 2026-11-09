import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pica_fresh_install');
    // `late final` on the app side: assign once for the whole file.
    App.dataPath = tempDir.path;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    for (final entity in tempDir.listSync()) {
      entity.deleteSync(recursive: true);
    }
  });

  tearDownAll(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('a brand new install has to show the welcome wizard', () async {
    final appdata = Appdata();

    final completed = await appdata.readData();

    expect(completed, isFalse,
        reason: 'nothing on disk, the user has never opened the app');
    expect(appdata.welcomeCompleted, isFalse);
    expect(appdata.firstUse[3], '0');
  });

  test('a fresh install that was killed once still shows the wizard', () async {
    // First launch: the wizard writes settings the moment the user picks a
    // theme or a reading option, then the process is killed before the last
    // page. The second launch must still show the wizard: a settings file is
    // not proof of a completed setup.
    final first = Appdata();
    await first.readData();
    first.settings[27] = "3";
    await first.updateSettings(false);

    final second = Appdata();
    final completed = await second.readData();

    expect(completed, isFalse);
  });

  test('finishing the wizard persists the flag right away', () async {
    final appdata = Appdata();
    await appdata.readData();

    appdata.firstUse[3] = "1";
    appdata.welcomeCompleted = true;
    await appdata.writeData(false);

    final next = Appdata();
    expect(await next.readData(), isTrue);
  });

  test('an install from before the flag existed is migrated', () async {
    SharedPreferences.setMockInitialValues({
      'firstUse': <String>["1", "1", "1", "1", "1"],
    });
    File("${App.dataPath}/settings").writeAsStringSync('["1"]');

    final appdata = Appdata();
    final completed = await appdata.readData();

    expect(completed, isTrue,
        reason: 'firstUse[3] == "1" means the user finished setup before');
  });
}
