import 'dart:ui' show Codec;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  test('natural ordering keeps long galleries in page order (#262 / #300)',
      () {
    final names = <String>[
      '10.jpg',
      '2.jpg',
      '1.jpg',
      '100.jpg',
      '20.jpg',
      '3.jpg',
    ];
    names.sort(compareNaturalFileName);
    expect(names, <String>[
      '1.jpg',
      '2.jpg',
      '3.jpg',
      '10.jpg',
      '20.jpg',
      '100.jpg',
    ]);
    expect(compareNaturalFileName('0002.jpg', '0010.jpg'), lessThan(0));
  });

  test('translation fallback never crashes before init (#291 / #302)', () {
    AppTranslation.translations = {};
    expect(AppTranslation.translations, isEmpty);
    expect('Hello'.tlEN, 'Hello');
  });

  test('a cancelled image load does not surface an error (#303)', () async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    final completer = ThrottledImageStreamCompleter(
        Future<Codec>.error(const ImageLoadingStopped()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    completer.stop();

    expect(errors, isEmpty,
        reason: 'cancelling a load is normal and must not be reported');
  });
}
