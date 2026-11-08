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
///   1. waiting is bounded by [waitTime]: past that deadline the caller
///      proceeds anyway (soft cap) instead of blocking all images;
///   2. every slot has a [lease] and is released automatically, so a load
///      that never completes cannot shrink the pool permanently.
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

  /// Polling granularity while the pool is full.
  final Duration pollInterval;

  /// Called when [waitTime] elapsed and the cap had to be bypassed. Used to
  /// log a stalled network instead of silently degrading.
  final void Function(int runningLoads)? onSoftLimit;

  int _running = 0;

  /// Number of slots currently held (including leaked ones not yet reclaimed
  /// by their lease).
  int get running => _running;

  /// Acquire a slot. Never throws and never waits longer than [waitTime].
  Future<LoadSlot> acquire() async {
    final deadline = DateTime.now().add(waitTime);
    while (_running >= maxConcurrent) {
      if (!DateTime.now().isBefore(deadline)) {
        onSoftLimit?.call(_running);
        break;
      }
      final remaining = deadline.difference(DateTime.now());
      await Future<void>.delayed(
          remaining < pollInterval ? remaining : pollInterval);
    }
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
  }
}
