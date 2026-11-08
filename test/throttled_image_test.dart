import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';

// A 1x1, 3-frame, infinitely looping GIF whose frames declare a 10 ms delay.
// This is short enough to embed and fast enough to decode in a headless test.
const String _threeFrameGif =
    'R0lGODlhAQABAIAAAAAAAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQBAQAAACwAAAAAAQABAAACAUQAIfkEAQEAAAAsAAAAAAEAAQAAAgFEACH5BAEBAAAALAAAAAABAAEAAAIBRAA7';

Future<ui.Codec> _decodeGif() async {
  final bytes = base64Decode(_threeFrameGif);
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  return PaintingBinding.instance.instantiateImageCodecFromBuffer(buffer);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ImageDecodeConfig.stopAllAnimations();
    ImageDecodeConfig.playAnimation = true;
  });

  tearDown(() {
    ImageDecodeConfig.stopAllAnimations();
  });

  test('animated GIF plays smoothly instead of being capped at 12 fps',
      () async {
    final codec = await _decodeGif();
    expect(codec.frameCount, 3,
        reason: 'the fixture must really contain multiple frames');

    final timestamps = <int>[];
    final completer = ThrottledImageStreamCompleter(Future.value(codec));
    completer.addListener(ImageStreamListener((ImageInfo info, bool sync) {
      timestamps.add(DateTime.now().millisecondsSinceEpoch);
      info.dispose();
    }));

    await Future<void>.delayed(const Duration(milliseconds: 500));

    // The old fixed 80 ms floor produced ~6 frames in 500 ms and looked
    // choppy. Honouring the GIF's 10 ms delay with a 16 ms safety floor
    // should produce far more frames.
    expect(timestamps.length, greaterThanOrEqualTo(8),
        reason: 'GIF must play near its authored frame rate');
    for (var i = 1; i < timestamps.length; i++) {
      final gap = timestamps[i] - timestamps[i - 1];
      expect(gap, lessThan(60),
          reason: 'no fixed 80 ms throttle may hold frames back');
      expect(gap, greaterThanOrEqualTo(8),
          reason: 'a small floor must still prevent a 100 fps decode storm');
    }

    completer.stop();
    final emitted = timestamps.length;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(timestamps.length, emitted,
        reason: 'stop() must halt frame decoding and release the codec');
    expect(ImageDecodeConfig.activeAnimations, 0);
  });

  test('frame floor adapts to frame size and decode cost', () {
    // Small, cheap GIF: authored delay is honoured (only a 16 ms safety net).
    expect(ImageDecodeConfig.frameFloorMs(1000, 0),
        ImageDecodeConfig.minFrameIntervalMs);
    // Larger frames get a higher baseline.
    expect(ImageDecodeConfig.frameFloorMs(3000000, 0), 25);
    expect(ImageDecodeConfig.frameFloorMs(8000000, 0), 40);
    // Expensive decodes are throttled to keep the UI isolate responsive...
    expect(ImageDecodeConfig.frameFloorMs(1000, 30), 60);
    // ...but never beyond the adaptive ceiling.
    expect(ImageDecodeConfig.frameFloorMs(1000, 100),
        ImageDecodeConfig.maxAdaptiveFrameIntervalMs);
  });

  test('first frame is emitted even when animation is disabled', () async {
    ImageDecodeConfig.playAnimation = false;
    final codec = await _decodeGif();
    var frames = 0;
    final completer = ThrottledImageStreamCompleter(Future.value(codec));
    completer.addListener(ImageStreamListener((ImageInfo info, bool sync) {
      frames++;
      info.dispose();
    }));

    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(frames, 1,
        reason: 'a paused/static GIF must not stay blank');
    completer.stop();
  });
}
