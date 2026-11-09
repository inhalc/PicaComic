import 'dart:async';

/// A single acquired download slot.
///
/// [release] is idempotent: the lease timer and the owner may both try to
/// release the same slot without corrupting the counter.
class LoadSlot {
  LoadSlot._(this._onRelease, this.speculative);

  final void Function(LoadSlot slot) _onRelease;

  /// Whether this slot was handed to a speculative load, so releasing it
  /// frees the speculation lane as well.
  final bool speculative;

  Timer? _leaseTimer;

  bool _released = false;

  bool get released => _released;

  void release() {
    if (_released) return;
    _released = true;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _onRelease(this);
  }
}

/// Thrown when a load gave up while waiting for a slot because its page is no
/// longer wanted (the reader moved away). Not an error: the caller maps it to
/// [ImageLoadingStopped] so nothing is shown to the user.
class LoadSlotSkipped implements Exception {
  const LoadSlotSkipped();

  @override
  String toString() => 'The image is no longer needed';
}

/// Bounds how many images are downloaded at the same time.
///
/// Two properties matter for a comic reader:
///
/// * the cap keeps 5+ concurrent 10-15 MB originals from exhausting memory;
/// * the cap must never freeze the whole image pipeline. A single stalled
///   socket used to hold its slot forever (Dio has no read timeout by
///   default), so after four bad connections every image in the app stopped
///   loading — including images already present on disk — until the process
///   was restarted. Therefore:
///
///   1. waiting is bounded by [waitTime]: past that deadline the best waiter
///      proceeds anyway (soft cap) instead of blocking all images;
///   2. every slot has a [lease] and is released automatically, so a load
///      that never completes cannot shrink the pool permanently.
///
/// Slots are handed out by priority, not arrival order. Flipping through a
/// long gallery queues one request per page that became visible; without
/// priorities the page the user actually stopped on had to wait for every
/// page that was merely swiped past. A waiter whose [priority] turns negative
/// is dropped instead of being downloaded at all.
class LoadSlotLimiter {
  LoadSlotLimiter({
    this.maxConcurrent = 4,
    this.waitTime = const Duration(seconds: 8),
    this.lease = const Duration(seconds: 45),
    this.pollInterval = const Duration(milliseconds: 25),
    this.speculativeBelow = 80,
    this.maxSpeculative = 1,
    this.holdSpeculationWhileUrgent = true,
    this.onSoftLimit,
  });

  /// How many loads may run at once.
  final int maxConcurrent;

  /// Loads that report a priority below this are speculative: the reader is
  /// only guessing that the user will look at them next.
  ///
  /// Loads without a priority callback (covers, thumbnails, avatars) are never
  /// treated as speculative, so grids keep their usual parallelism.
  final int speculativeBelow;

  /// How many speculative loads may run at the same time.
  ///
  /// Building a page in a continuous reader resolves every child that the
  /// list keeps around, so seven pages used to enter the pool in one frame and
  /// split the link seven ways. The page on screen then finished *last*,
  /// because the smaller neighbours were done first. Giving speculation a
  /// single lane leaves the rest of the pool to the pages the reader reports
  /// as current or adjacent.
  final int maxSpeculative;

  /// Keep the speculation lane closed while a page the reader asks for is
  /// still downloading.
  ///
  /// Without this, page 3 of a gallery starts together with pages 1 and 2, and
  /// being a small still image it finishes first: the user stares at "3 is
  /// here, 1 and 2 are at 20 %" and the pages arrive out of order. Holding
  /// speculation until the visible pages are done makes the window fill in
  /// reading order. The wait is bounded by the running loads themselves: a
  /// speculative request never bypasses the cap.
  final bool holdSpeculationWhileUrgent;

  /// Longest time a caller waits for a free slot before ignoring the cap.
  ///
  /// Applies to loads the reader asked for. Speculative loads never bypass the
  /// cap: they are guesses, and overshooting [maxConcurrent] is what the cap
  /// exists to prevent.
  final Duration waitTime;

  /// How long a slot may be held before it is reclaimed automatically.
  final Duration lease;

  /// Polling granularity while the pool is full. Also how quickly a dropped
  /// page leaves the queue.
  final Duration pollInterval;

  /// Called when [waitTime] elapsed and the cap had to be bypassed. Used to
  /// log a stalled network instead of silently degrading.
  final void Function(int runningLoads)? onSoftLimit;

  /// Priority assumed when no callback is given. Keeps legacy callers in the
  /// same lane as ordinary images (covers, thumbnails).
  static const int defaultPriority = 50;

  int _running = 0;

  int _speculativeRunning = 0;

  /// Number of slots currently held (including leaked ones not yet reclaimed
  /// by their lease).
  int get running => _running;

  /// Speculative loads currently holding a slot. Exposed for tests.
  int get speculativeRunning => _speculativeRunning;

  final List<_LoadWaiter> _waiters = [];

  Timer? _ticker;

  /// Acquire a slot. A load the reader asked for never waits longer than
  /// [waitTime]; a speculative one waits until the pool has room for it.
  ///
  /// [priority] is evaluated repeatedly while waiting: the highest priority
  /// waiter is served first, and a negative value aborts the wait with
  /// [LoadSlotSkipped] without ever calling the network.
  Future<LoadSlot> acquire({int Function()? priority}) {
    final current = priority?.call() ?? defaultPriority;
    if (current < 0) {
      return Future.error(const LoadSlotSkipped());
    }
    final speculative = priority != null && current < speculativeBelow;
    // The fast path must apply the same two rules as the queue, otherwise a
    // page that arrives while the pool is empty slips past the lane.
    final blocked = speculative &&
        (_speculativeRunning >= maxSpeculative ||
            (holdSpeculationWhileUrgent && _running > _speculativeRunning));
    if (_waiters.isEmpty && _running < maxConcurrent && !blocked) {
      return Future.value(_grant(speculative));
    }
    final waiter = _LoadWaiter(
      priority,
      DateTime.now().add(waitTime),
      speculativeBelow,
    );
    _waiters.add(waiter);
    _startTicker();
    _pump();
    return waiter.completer.future;
  }

  LoadSlot _grant(bool speculative) {
    _running++;
    if (speculative) {
      _speculativeRunning++;
    }
    final slot = LoadSlot._(_release, speculative);
    if (lease > Duration.zero) {
      slot._leaseTimer = Timer(lease, slot.release);
    }
    return slot;
  }

  void _release(LoadSlot slot) {
    if (_running > 0) {
      _running--;
    }
    if (slot.speculative && _speculativeRunning > 0) {
      _speculativeRunning--;
    }
    _pump();
  }

  /// A speculative waiter waits while the speculation lane is occupied, and
  /// while any page the reader explicitly asked for is still downloading. Its
  /// priority is re-read every time, so a page that becomes current leaves the
  /// lane and is served normally.
  bool _blocked(_LoadWaiter waiter) {
    if (!waiter.isSpeculative) return false;
    if (_speculativeRunning >= maxSpeculative) return true;
    return holdSpeculationWhileUrgent && _running > _speculativeRunning;
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(pollInterval, (_) => _pump());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _pump() {
    if (_waiters.isEmpty) {
      _stopTicker();
      return;
    }

    // Pages that are no longer wanted leave the queue immediately; otherwise
    // they would still start a multi-megabyte download when a slot frees.
    for (final waiter in List<_LoadWaiter>.of(_waiters)) {
      if (waiter.completer.isCompleted) {
        _waiters.remove(waiter);
        continue;
      }
      if (waiter.currentPriority < 0) {
        _waiters.remove(waiter);
        waiter.completer.completeError(const LoadSlotSkipped());
      }
    }

    while (_running < maxConcurrent && _waiters.isNotEmpty) {
      _waiters.sort((a, b) => b.currentPriority.compareTo(a.currentPriority));
      final index = _waiters.indexWhere((waiter) => !_blocked(waiter));
      if (index < 0) break;
      final waiter = _waiters.removeAt(index);
      waiter.completer.complete(_grant(waiter.isSpeculative));
    }

    // Bounded wait: a stalled download must not block the pool forever.
    final now = DateTime.now();
    for (final waiter in List<_LoadWaiter>.of(_waiters)) {
      if (waiter.completer.isCompleted) {
        _waiters.remove(waiter);
        continue;
      }
      if (now.isAfter(waiter.deadline)) {
        // Only a load the reader asked for may bypass the cap. Letting a
        // guess through would mean running more than [maxConcurrent]
        // downloads, which is exactly what the cap exists to prevent - and a
        // guess can simply keep waiting for a slot to free up.
        if (waiter.isSpeculative) continue;
        _waiters.remove(waiter);
        onSoftLimit?.call(_running + 1);
        waiter.completer.complete(_grant(false));
      }
    }

    if (_waiters.isEmpty) {
      _stopTicker();
    }
  }
}

class _LoadWaiter {
  _LoadWaiter(this.priority, this.deadline, this.speculativeBelow);

  final int Function()? priority;
  final DateTime deadline;
  final int speculativeBelow;
  final Completer<LoadSlot> completer = Completer<LoadSlot>();

  int get currentPriority =>
      priority?.call() ?? LoadSlotLimiter.defaultPriority;

  /// Recomputed on every check: a page that becomes current stops being
  /// speculative and no longer waits for the speculation lane.
  bool get isSpeculative =>
      priority != null && currentPriority < speculativeBelow;
}
