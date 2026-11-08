import 'dart:async';

/// A single acquired download slot.
///
/// [release] is idempotent: the lease timer and the owner may both try to
/// release the same slot without corrupting the counter.
class LoadSlot {
  LoadSlot._(this._onRelease);

  final void Function(LoadSlot slot) _onRelease;

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
    this.onSoftLimit,
  });

  /// How many loads may run at once.
  final int maxConcurrent;

  /// Longest time a caller waits for a free slot before ignoring the cap.
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

  /// Number of slots currently held (including leaked ones not yet reclaimed
  /// by their lease).
  int get running => _running;

  final List<_LoadWaiter> _waiters = [];

  Timer? _ticker;

  /// Acquire a slot. Never waits longer than [waitTime].
  ///
  /// [priority] is evaluated repeatedly while waiting: the highest priority
  /// waiter is served first, and a negative value aborts the wait with
  /// [LoadSlotSkipped] without ever calling the network.
  Future<LoadSlot> acquire({int Function()? priority}) {
    final current = priority?.call() ?? defaultPriority;
    if (current < 0) {
      return Future.error(const LoadSlotSkipped());
    }
    if (_waiters.isEmpty && _running < maxConcurrent) {
      return Future.value(_grant());
    }
    final waiter = _LoadWaiter(
      priority,
      DateTime.now().add(waitTime),
    );
    _waiters.add(waiter);
    _startTicker();
    _pump();
    return waiter.completer.future;
  }

  LoadSlot _grant() {
    _running++;
    final slot = LoadSlot._(_release);
    if (lease > Duration.zero) {
      slot._leaseTimer = Timer(lease, slot.release);
    }
    return slot;
  }

  void _release(LoadSlot slot) {
    if (_running > 0) {
      _running--;
    }
    _pump();
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
      final waiter = _waiters.removeAt(0);
      waiter.completer.complete(_grant());
    }

    // Bounded wait: a stalled download must not block the pool forever.
    final now = DateTime.now();
    for (final waiter in List<_LoadWaiter>.of(_waiters)) {
      if (waiter.completer.isCompleted) {
        _waiters.remove(waiter);
        continue;
      }
      if (now.isAfter(waiter.deadline)) {
        _waiters.remove(waiter);
        onSoftLimit?.call(_running + 1);
        waiter.completer.complete(_grant());
      }
    }

    if (_waiters.isEmpty) {
      _stopTicker();
    }
  }
}

class _LoadWaiter {
  _LoadWaiter(this.priority, this.deadline);

  final int Function()? priority;
  final DateTime deadline;
  final Completer<LoadSlot> completer = Completer<LoadSlot>();

  int get currentPriority =>
      priority?.call() ?? LoadSlotLimiter.defaultPriority;
}
