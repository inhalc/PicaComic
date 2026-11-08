import 'dart:async' show Future, StreamController;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../image_manager.dart';
import 'base_image_provider.dart';

/// Function which is called after loading the image failed.
typedef ErrorListener = void Function();

class StreamImageProvider
    extends BaseImageProvider<StreamImageProvider> {

  /// Image provider with [Stream<DownloadProgress>].
  const StreamImageProvider(this.streamBuilder, this.key);

  final Stream<DownloadProgress> Function() streamBuilder;

  @override
  final String key;

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async{
    chunkEvents.add(const ImageChunkEvent(
        cumulativeBytesLoaded: 0,
        expectedTotalBytes: 100)
    );
    DownloadProgress? finishProgress;

    await for (var progress in streamBuilder()) {
      if (progress.currentBytes == progress.expectedBytes) {
        finishProgress = progress;
      }
      chunkEvents.add(ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.expectedBytes)
      );
    }

    if (finishProgress == null) {
      throw StateError('image stream ended without completion event');
    }
    if (finishProgress.data != null) {
      return finishProgress.data!;
    }

    var file = finishProgress.getFile();
    return await file.readAsBytes();
  }

  /// [key] is built by `ReadingData.buildImageKey`, which mirrors the cache
  /// key used by [ImageManager] for the same page (url, `galleryLink+page`,
  /// hitomi hash, custom-source id...). It is therefore also the on-disk cache
  /// key: a cached page can be decoded without taking a download slot.
  @override
  String? get diskCacheKey => key;

  @override
  Future<StreamImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }
}
