import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../image_manager.dart';
import 'base_image_provider.dart';

/// Function which is called after loading the image failed.
typedef ErrorListener = void Function();

class StreamImageProvider extends BaseImageProvider<StreamImageProvider> {
  /// Image provider with [Stream<DownloadProgress>].
  const StreamImageProvider(this.streamBuilder, this.key, {super.priorityOf});

  final Stream<DownloadProgress> Function() streamBuilder;

  @override
  final String key;

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    chunkEvents.add(const ImageChunkEvent(
        cumulativeBytesLoaded: 0, expectedTotalBytes: 100));

    final completer = Completer<Uint8List>();
    DownloadProgress? finishProgress;
    StreamSubscription<DownloadProgress>? subscription;
    Timer? monitor;

    void fail(Object error, [StackTrace? stack]) {
      if (!completer.isCompleted) {
        completer.completeError(error, stack);
      }
    }

    // A comic page that was swiped away must not keep downloading in the
    // background: it steals bandwidth from the page the user is looking at,
    // which is exactly what made "flip a few pages, still loading the old
    // ones" happen. Checking here (and on every chunk) aborts the socket
    // instead of letting it finish into the cache.
    void checkStillWanted() {
      if (priorityOf == null || completer.isCompleted) return;
      if (loadPriority >= 0) return;
      monitor?.cancel();
      monitor = null;
      subscription?.cancel();
      fail(const ImageLoadingStopped());
    }

    subscription = streamBuilder().listen(
      (progress) {
        if (progress.currentBytes == progress.expectedBytes) {
          finishProgress = progress;
        }
        if (!chunkEvents.isClosed) {
          chunkEvents.add(ImageChunkEvent(
              cumulativeBytesLoaded: progress.currentBytes,
              expectedTotalBytes: progress.expectedBytes));
        }
        checkStillWanted();
      },
      onError: (Object error, StackTrace stack) => fail(error, stack),
      onDone: () {
        final finish = finishProgress;
        if (finish == null) {
          fail(StateError('image stream ended without completion event'));
          return;
        }
        if (finish.data != null) {
          if (!completer.isCompleted) {
            completer.complete(finish.data!);
          }
          return;
        }
        finish.getFile().readAsBytes().then(
          (bytes) {
            if (!completer.isCompleted) {
              completer.complete(bytes);
            }
          },
          onError: (Object error, StackTrace stack) => fail(error, stack),
        );
      },
      cancelOnError: true,
    );

    if (priorityOf != null) {
      // A stalled stream emits no chunk, so the per-chunk check above would
      // never run. Poll at a rate that is invisible next to a page download.
      monitor = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => checkStillWanted(),
      );
    }

    try {
      return await completer.future;
    } finally {
      monitor?.cancel();
      monitor = null;
      await subscription.cancel();
    }
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
