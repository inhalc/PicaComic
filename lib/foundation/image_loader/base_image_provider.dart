import 'dart:async' show Future, StreamController, StreamSubscription,
    scheduleMicrotask;
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';

/// Controls how animated images are decoded.
///
/// Flutter's [MultiFrameImageStreamCompleter] keeps the native codec alive,
/// decodes every frame of a GIF at full resolution and emits a new frame on
/// each scheduler tick. In a comic reader every frame causes a rebuild/repaint
/// of the whole zoomable page, and the codec is never explicitly disposed.
/// The reader turns this off so GIFs are rendered as a static first frame.
class ImageDecodeConfig {
  static bool playAnimation = true;
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
    return MultiFrameImageStreamCompleter(
      codec: codec,
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: collector,
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
            final bytes = await load(chunkEvents);
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
        throw Exception("Image loading is stopped");
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
