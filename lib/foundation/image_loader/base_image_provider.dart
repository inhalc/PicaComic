import 'dart:async' show Completer, Future, StreamController,
    StreamSubscription, scheduleMicrotask;
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/tools/image_integrity.dart';

/// Internal signal used when an image stream is cancelled before decoding
/// finishes (a page scrolled away, or the reader was closed). This is normal
/// and must not bubble up as an "Image loading is stopped" error that makes
/// the app look broken right after launch (#303).
class ImageLoadingStopped implements Exception {
  const ImageLoadingStopped();

  @override
  String toString() => 'Image loading was cancelled';
}

/// Controls how animated images are decoded.
///
/// Flutter's [MultiFrameImageStreamCompleter] decodes a full-resolution frame
/// for every GIF tick. Many GIFs declare 10-20 ms frames, so on a 120 Hz phone
/// a single image can trigger ~100 decodes per second, each of which repaints
/// the zoomable reader page. That is what makes the whole app stutter after a
/// GIF appears. The reader uses an adaptive completer instead: it honours the
/// GIF's own frame delays, only slows down frames that are genuinely expensive
/// to decode, stops decoding when nobody is watching, and releases every codec
/// when the reader is closed.
class ImageDecodeConfig {
  /// When false, animated images are rendered as their first frame only.
  static bool playAnimation = true;

  /// Safety floor for frames that declare no delay. This only prevents a
  /// 0/10 ms GIF from monopolising the UI isolate; longer delays declared by
  /// the file are honoured as-is. A fixed 80 ms floor here used to cap every
  /// GIF at ~12 fps, which looked visibly choppy.
  static const int minFrameIntervalMs = 16;

  /// Upper bound for the *adaptive* floor when decoding is very expensive.
  static const int maxAdaptiveFrameIntervalMs = 80;

  /// Longest delay we are willing to honour from the file itself.
  static const int maxFrameIntervalMs = 1000;

  static final Set<ThrottledImageStreamCompleter> _active = {};

  /// Hard cap on animated decoders kept alive at once. Every entry owns a
  /// native codec and a polling timer; a long comic would otherwise pile up
  /// hundreds of them and starve the UI isolate.
  static const int maxActiveAnimations = 12;

  /// Compute the minimum interval for the next frame.
  ///
  /// Small GIFs play at their authored speed. Large or slow-to-decode frames
  /// get a higher floor so decoding never takes more than roughly half of the
  /// UI isolate's time - the original "whole app freezes after a GIF" issue.
  static int frameFloorMs(int framePixels, int lastDecodeMs) {
    final sizeFloor = framePixels >= 6000000
        ? 40
        : framePixels >= 2000000
            ? 25
            : minFrameIntervalMs;
    final decodeFloor =
        (lastDecodeMs * 2).clamp(0, maxAdaptiveFrameIntervalMs).toInt();
    return sizeFloor > decodeFloor ? sizeFloor : decodeFloor;
  }

  static void register(ThrottledImageStreamCompleter completer) {
    _active.add(completer);
    if (_active.length <= maxActiveAnimations) return;
    // Only evict a decoder that is both offscreen and known to be an
    // animation. Most comic pages are still images: they register here before
    // their codec is decoded and unregister themselves right after emitting
    // the first frame. Evicting those would blank precached pages, and
    // evicting the oldest entry could stop the GIF currently on screen.
    ThrottledImageStreamCompleter? victim;
    for (final candidate in _active) {
      if (candidate.isEvictable) {
        victim = candidate;
        break;
      }
    }
    // Hard safety valve for pathological cases where everything is visible.
    victim ??= _active.length > maxActiveAnimations * 3
        ? _active.first
        : null;
    if (victim != null) {
      victim.stop();
      _active.remove(victim);
    }
  }

  /// Stop every animation and release its native codec. Called when leaving
  /// the reader so no background frame decoding survives the route pop.
  static void stopAllAnimations() {
    for (final completer in List<ThrottledImageStreamCompleter>.of(_active)) {
      completer.stop();
    }
    _active.clear();
  }

  static int get activeAnimations => _active.length;
}

/// An [ImageStreamCompleter] that plays animated images with a bounded cost.
///
/// Compared with [MultiFrameImageStreamCompleter]:
/// * the GIF's own frame delays are honoured; only frames that are expensive
///   to decode are slowed down (see [ImageDecodeConfig.frameFloorMs]);
/// * playback follows an absolute timeline, so timer jitter and decode time
///   do not accumulate into a slow, uneven animation;
/// * no frame is decoded while there are no listeners (e.g. precached pages);
/// * [stop] / [onDisposed] always dispose the native codec, so leaving the
///   reader cannot leave a background decoder running.
class ThrottledImageStreamCompleter extends ImageStreamCompleter {
  ThrottledImageStreamCompleter(
    Future<ui.Codec> codecFuture, {
    Stream<ImageChunkEvent>? chunkEvents,
    this.informationCollector,
    double scale = 1.0,
    String? debugLabel,
  })  : _scale = scale,
        _debugLabel = debugLabel {
    if (chunkEvents != null) {
      _chunkSubscription = chunkEvents.listen(
        reportImageChunkEvent,
        onError: (Object error, StackTrace stack) {
          reportError(exception: error, stack: stack, silent: true);
        },
      );
    }
    ImageDecodeConfig.register(this);
    _run(codecFuture);
  }

  final InformationCollector? informationCollector;
  final double _scale;
  final String? _debugLabel;

  StreamSubscription<ImageChunkEvent>? _chunkSubscription;
  ui.Codec? _codec;
  bool _stopped = false;
  bool _started = false;

  /// Public view of the protected [hasListeners] flag, used by
  /// [ImageDecodeConfig.register] to avoid evicting a visible animation.
  bool get isBeingWatched => hasListeners;

  /// Only a confirmed, offscreen animation may be evicted to make room for
  /// another decoder. Still images unregister themselves immediately.
  bool get isEvictable => _started && !hasListeners;

  Future<void> _run(Future<ui.Codec> codecFuture) async {
    ui.Codec? codec;
    try {
      codec = await codecFuture;
      if (_stopped) {
        codec.dispose();
        return;
      }
      _codec = codec;

      // Always emit a first frame right away. Waiting for a listener (or for
      // animation to be enabled) before decoding anything would leave
      // precached pages and "static first frame" mode completely blank.
      final first = await codec.getNextFrame();
      if (_stopped) {
        first.image.dispose();
        return;
      }
      final framePixels = first.image.width * first.image.height;
      var nextDelayMs = first.duration.inMilliseconds;
      _emit(first);
      var emitted = 1;

      if (codec.frameCount <= 1 || !ImageDecodeConfig.playAnimation) {
        // Almost every comic page is a still image. Unregister and release
        // the codec right away instead of keeping a live polling loop until
        // the reader is closed. The emitted first frame stays on screen.
        stop();
        return;
      }
      // Confirmed animation: from now on this decoder is a candidate for
      // eviction once it goes offscreen.
      _started = true;

      final repetitionCount = codec.repetitionCount;
      var lastDecodeMs = 0;
      var offscreenElapsedMs = 0;
      // Schedule against a monotonic timeline. Sleeping a fixed interval
      // *after* each decode adds the decode time on top of the frame delay,
      // which is exactly what made the old fixed-throttle playback drift and
      // look uneven. Decode time now comes out of the wait, not on top of it.
      final clock = Stopwatch()..start();
      var nextFrameAt = 0;
      while (!_stopped) {
        final floorMs =
            ImageDecodeConfig.frameFloorMs(framePixels, lastDecodeMs);
        final interval = _clampFrameDelay(nextDelayMs, floorMs);
        nextFrameAt += interval;
        final waitMs = nextFrameAt - clock.elapsedMilliseconds;
        if (waitMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: waitMs));
        } else if (-waitMs > interval) {
          // Fell far behind (long offscreen pause or a system stall): resync
          // instead of firing a burst of catch-up frames.
          nextFrameAt = clock.elapsedMilliseconds;
        }
        if (_stopped) break;
        if (!hasListeners) {
          // Poll quickly so scrolling back resumes without a visible gap,
          // but release a codec that has been unused for a few seconds.
          offscreenElapsedMs += 32;
          if (offscreenElapsedMs > 2000) {
            stop();
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 32));
          nextFrameAt = clock.elapsedMilliseconds;
          continue;
        }
        offscreenElapsedMs = 0;
        final decodeStart = clock.elapsedMilliseconds;
        final frame = await codec.getNextFrame();
        lastDecodeMs = clock.elapsedMilliseconds - decodeStart;
        if (_stopped) {
          frame.image.dispose();
          break;
        }
        nextDelayMs = frame.duration.inMilliseconds;
        _emit(frame);
        emitted++;
        if (repetitionCount >= 0 &&
            emitted >= (repetitionCount + 1) * codec.frameCount) {
          break;
        }
      }
    } catch (e, s) {
      if (e is ImageLoadingStopped) {
        // The page is gone; there is nobody left to show an error to.
        return;
      }
      if (!_stopped) {
        reportError(
          context: ErrorDescription('decoding an animated image frame'),
          exception: e,
          stack: s,
          informationCollector: informationCollector,
          silent: true,
        );
      }
    } finally {
      _releaseCodec();
      _chunkSubscription?.cancel();
      _chunkSubscription = null;
    }
  }

  static int _clampFrameDelay(int milliseconds, int floorMs) {
    if (milliseconds < floorMs) {
      return floorMs;
    }
    if (milliseconds > ImageDecodeConfig.maxFrameIntervalMs) {
      return ImageDecodeConfig.maxFrameIntervalMs;
    }
    return milliseconds;
  }

  void _emit(FrameInfo frame) {
    // The frame's image handle belongs to the codec; clone before setImage
    // takes ownership (setImage disposes the previously emitted image).
    final image = frame.image.clone();
    frame.image.dispose();
    setImage(ImageInfo(image: image, scale: _scale, debugLabel: _debugLabel));
  }

  void _releaseCodec() {
    _codec?.dispose();
    _codec = null;
  }

  /// Permanently stop playback and free the native codec.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _releaseCodec();
    _chunkSubscription?.cancel();
    _chunkSubscription = null;
    ImageDecodeConfig._active.remove(this);
  }

  @override
  void onDisposed() {
    stop();
    super.onDisposed();
  }
}

/// An [ImageStreamCompleter] which decodes exactly one frame, forwards loading
/// progress, and disposes the native codec as soon as it is done.
class SingleFrameImageStreamCompleter extends ImageStreamCompleter {
  SingleFrameImageStreamCompleter(
    Future<ui.Codec> codec, {
    Stream<ImageChunkEvent>? chunkEvents,
    this.informationCollector,
    double scale = 1.0,
  }) {
    if (chunkEvents != null) {
      _chunkSubscription = chunkEvents.listen(
        reportImageChunkEvent,
        onError: (Object error, StackTrace stack) {
          reportError(exception: error, stack: stack, silent: true);
        },
      );
    }
    _decode(codec, scale);
  }

  final InformationCollector? informationCollector;

  StreamSubscription<ImageChunkEvent>? _chunkSubscription;

  void _decode(Future<ui.Codec> codecFuture, double scale) async {
    ui.Codec? codec;
    try {
      codec = await codecFuture;
      final frame = await codec.getNextFrame();
      // The frame's own handle is owned by the codec; clone before disposing.
      final image = frame.image.clone();
      frame.image.dispose();
      setImage(ImageInfo(image: image, scale: scale));
    } catch (e, s) {
      if (e is ImageLoadingStopped) {
        return;
      }
      reportError(
        exception: e,
        stack: s,
        informationCollector: informationCollector,
        silent: true,
      );
    } finally {
      codec?.dispose();
      _chunkSubscription?.cancel();
      _chunkSubscription = null;
    }
  }
}

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    final codec = _loadBufferAsync(key, chunkEvents, decode);
    InformationCollector collector = () sync* {
      yield DiagnosticsProperty<ImageProvider>(
        'Image provider: $this \n Image key: $key',
        this,
        style: DiagnosticsTreeStyle.errorProperty,
      );
    };
    if (!ImageDecodeConfig.playAnimation) {
      return SingleFrameImageStreamCompleter(
        codec,
        chunkEvents: chunkEvents.stream,
        informationCollector: collector,
      );
    }
    return ThrottledImageStreamCompleter(
      codec,
      chunkEvents: chunkEvents.stream,
      informationCollector: collector,
      debugLabel: key.toString(),
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      int retryTime = 1;

      bool stop = false;

      chunkEvents.onCancel = () {
        stop = true;
      };

      Uint8List? data;

      while (data == null && !stop) {
        try {
          if (_cache.containsKey(key.key)) {
            // Re-insert to mark the entry as recently used (LinkedHashMap).
            final cached = _cache.remove(key.key)!;
            _cache[key.key] = cached;
            data = cached;
          } else {
            // Back-pressure for very large originals: E-Hentai pages can be
            // 10-15 MB each. Without a cap, precaching 5+ of them at once
            // allocates hundreds of MB and stalls the whole app.
            await _acquireLoadSlot();
            Uint8List bytes;
            try {
              bytes = await load(chunkEvents);
            } finally {
              _releaseLoadSlot();
            }
            // Validate the exact bytes that will be decoded. Custom comic
            // sources may rewrite the downloaded bytes via an onResponse hook
            // inside the ImageManager stream; load() only consumes that stream
            // and returns the already-rewritten final buffer, so this check
            // always runs *after* onResponse and cannot reject a legitimately
            // transformed image (issue #93).
            final payloadError = imagePayloadError(bytes);
            if (payloadError != null) {
              // Drop both cache tiers so the retry loop below re-downloads
              // instead of decoding the same HTML/JSON error page forever.
              _cache.remove(key.key);
              await CacheManager().delete(key.key);
              throw Exception('Invalid image payload for $key: $payloadError '
                  '(length: ${bytes.length})');
            }
            _cache[key.key] = bytes;
            _cacheSize += bytes.length;
            // Evict *after* inserting, otherwise the cache grows past the
            // limit by one (potentially very large GIF) on every load.
            _checkCacheSize();
            data = bytes;
          }
        } catch (e) {
          if(e.toString().contains("Maximum image loading limit reached")) {
            rethrow;
          }
          if (e.toString().contains("Your IP address")) {
            rethrow;
          }
          if (e is BadRequestException) {
            rethrow;
          }
          if (e.toString().contains("handshake")) {
            if (retryTime < 5) {
              retryTime = 5;
            }
          }
          retryTime <<= 1;
          if (retryTime > (1 << 3) || stop) {
            rethrow;
          }
          await Future.delayed(Duration(seconds: retryTime));
        }
      }

      if(stop) {
        throw const ImageLoadingStopped();
      }

      if(data!.isEmpty) {
        throw Exception("Empty image data");
      }

      try {
        final buffer = await ImmutableBuffer.fromUint8List(data);
        return await decode(buffer);
      } catch (e) {
        await CacheManager().delete(this.key);
        Object error = e;
        if (data.length < 2 * 1024) {
          // data is too short, it's likely that the data is text, not image
          try {
            var text = const Utf8Codec(allowMalformed: false).decoder.convert(data);
            error = Exception("Expected image data, but got text: $text");
          } catch (e) {
            // ignore
          }
        }
        throw error;
      }
    } catch (e) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  static final _cache = LinkedHashMap<String, Uint8List>();

  static var _cacheSize = 0;

  static const int _maxConcurrentLoads = 4;
  static int _runningLoads = 0;
  static final Queue<Completer<void>> _loadWaiters =
      Queue<Completer<void>>();

  static Future<void> _acquireLoadSlot() async {
    if (_runningLoads < _maxConcurrentLoads) {
      _runningLoads++;
      return;
    }
    final waiter = Completer<void>();
    _loadWaiters.add(waiter);
    await waiter.future;
    // The slot is handed over by _releaseLoadSlot, so _runningLoads stays
    // unchanged here.
  }

  static void _releaseLoadSlot() {
    if (_loadWaiters.isNotEmpty) {
      _loadWaiters.removeFirst().complete();
    } else {
      _runningLoads--;
    }
  }

  static var _cacheSizeLimit = 50 * 1024 * 1024;

  static void _checkCacheSize(){
    while (_cacheSize > _cacheSizeLimit){
      var firstKey = _cache.keys.first;
      _cacheSize -= _cache[firstKey]!.length;
      _cache.remove(firstKey);
    }
  }

  static void clearCache(){
    _cache.clear();
    _cacheSize = 0;
  }

  static void setCacheSizeLimit(int size){
    _cacheSizeLimit = size;
    _checkCacheSize();
  }

  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents);

  String get key;

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() {
    return "$runtimeType($key)";
  }
}

typedef FileDecoderCallback = Future<ui.Codec> Function(Uint8List);
