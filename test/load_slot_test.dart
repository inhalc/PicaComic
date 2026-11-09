import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/load_slot_limiter.dart';

void main() {
  test('caps concurrent loads and hands the slot to the next caller',
      () async {
    final limiter = LoadSlotLimiter(maxConcurrent: 2);
    final first = await limiter.acquire();
    final second = await limiter.acquire();
    expect(limiter.running, 2);

    var thirdAcquired = false;
    final thirdFuture = limiter.acquire().then((slot) {
      thirdAcquired = true;
      return slot;
    });

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(thirdAcquired, isFalse,
        reason: 'the pool is full, the third load must wait');

    first.release();
    final third = await thirdFuture;
    expect(thirdAcquired, isTrue);
    expect(limiter.running, 2);

    third.release();
    second.release();
    expect(limiter.running, 0);
  });

  test('a stalled load cannot freeze the pool forever (soft cap)', () async {
    var softLimitHits = 0;
    final limiter = LoadSlotLimiter(
      maxConcurrent: 2,
      waitTime: const Duration(milliseconds: 60),
      lease: Duration.zero,
      pollInterval: const Duration(milliseconds: 10),
      onSoftLimit: (_) => softLimitHits++,
    );

    // Two requests that never finish (e.g. dead sockets after a VPN switch).
    await limiter.acquire();
    await limiter.acquire();

    final watch = Stopwatch()..start();
    await limiter.acquire();
    watch.stop();

    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(50));
    expect(softLimitHits, 1);
    // Proceeding past the cap is better than blocking every image in the app.
    expect(limiter.running, 3);
  });

  test('release is idempotent and never makes the counter negative', () async {
    final limiter = LoadSlotLimiter(maxConcurrent: 4);
    final slot = await limiter.acquire();
    expect(limiter.running, 1);
    slot.release();
    slot.release();
    expect(limiter.running, 0);
    expect(slot.released, isTrue);
  });

  test('the page in front of the user is served before queued earlier pages',
      () async {
    final limiter = LoadSlotLimiter(
      maxConcurrent: 1,
      waitTime: const Duration(seconds: 30),
    );
    final held = await limiter.acquire();

    final order = <String>[];
    final low = limiter.acquire(priority: () => 10).then((slot) {
      order.add('old page');
      return slot;
    });
    final high = limiter.acquire(priority: () => 100).then((slot) {
      order.add('current page');
      return slot;
    });

    // Both are queued while the single slot is busy.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(order, isEmpty);

    held.release();
    final highSlot = await high;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(order, ['current page'],
        reason: 'the visible page must not wait for a page that was swiped '
            'past');

    highSlot.release();
    final lowSlot = await low;
    expect(order, ['current page', 'old page']);
    lowSlot.release();
  });

  test('a page that is no longer wanted leaves the queue instead of loading',
      () async {
    final limiter = LoadSlotLimiter(
      maxConcurrent: 1,
      waitTime: const Duration(seconds: 30),
      pollInterval: const Duration(milliseconds: 10),
    );
    final held = await limiter.acquire();

    var priority = 20;
    final queued = limiter.acquire(priority: () => priority);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // The reader flipped away from this page.
    priority = -1;
    await expectLater(queued, throwsA(isA<LoadSlotSkipped>()));
    expect(limiter.running, 1,
        reason: 'the skipped page must not consume a slot');

    held.release();
    expect(limiter.running, 0);
  });

  test('acquire never starts when the page is already unwanted', () async {
    final limiter = LoadSlotLimiter();
    await expectLater(
      limiter.acquire(priority: () => -1),
      throwsA(isA<LoadSlotSkipped>()),
    );
    expect(limiter.running, 0);
  });

  test('an expired lease reclaims the slot of a hung download', () async {
    final limiter = LoadSlotLimiter(
      maxConcurrent: 1,
      waitTime: const Duration(seconds: 30),
      lease: const Duration(milliseconds: 40),
    );

    // Never released: exactly what a socket stuck in `await for` does.
    await limiter.acquire();
    expect(limiter.running, 1);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(limiter.running, 0,
        reason: 'the lease must hand the slot back on its own');

    final next = await limiter.acquire();
    expect(limiter.running, 1);
    next.release();
  });

  group('speculation lane', () {
    test('only one speculative page downloads at a time', () async {
      final limiter = LoadSlotLimiter(
        maxConcurrent: 4,
        waitTime: const Duration(seconds: 30),
        lease: Duration.zero,
        // Isolate the lane itself: the "wait for the visible pages" rule is
        // covered by the next test.
        holdSpeculationWhileUrgent: false,
      );

      // Building a continuous reader resolves the visible page, its
      // neighbour, and every page the list keeps around. Without the lane all
      // of them start at once and the page on screen is the last to finish.
      final screen = await limiter.acquire(priority: () => 100);
      final neighbour = await limiter.acquire(priority: () => 80);
      final prefetched = await limiter.acquire(priority: () => 20);
      expect(limiter.speculativeRunning, 1);

      var secondStarted = false;
      final pending = limiter.acquire(priority: () => 20).then((slot) {
        secondStarted = true;
        return slot;
      });

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(secondStarted, isFalse,
          reason: 'two slots are free, but speculation has one lane');

      prefetched.release();
      final second = await pending;
      expect(secondStarted, isTrue);

      second.release();
      neighbour.release();
      screen.release();
      expect(limiter.running, 0);
      expect(limiter.speculativeRunning, 0);
    });

    test('speculation waits until the visible pages are downloaded', () async {
      final limiter = LoadSlotLimiter(
        maxConcurrent: 4,
        waitTime: const Duration(seconds: 30),
        lease: Duration.zero,
        pollInterval: const Duration(milliseconds: 10),
      );

      // Page 1 on screen, page 2 next to it, page 3 merely guessed.
      final screen = await limiter.acquire(priority: () => 100);
      final neighbour = await limiter.acquire(priority: () => 80);

      var thirdStarted = false;
      final third = limiter.acquire(priority: () => 20).then((slot) {
        thirdStarted = true;
        return slot;
      });

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(thirdStarted, isFalse,
          reason: 'a free slot must not be spent on page 3 while page 1 '
              'is still arriving - that is what made later pages finish '
              'first');

      screen.release();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(thirdStarted, isFalse,
          reason: 'page 2 is still downloading');

      neighbour.release();
      final slot = await third;
      expect(thirdStarted, isTrue);
      slot.release();
      expect(limiter.running, 0);
    });

    test('a page that becomes current leaves the lane immediately', () async {
      final limiter = LoadSlotLimiter(
        maxConcurrent: 4,
        waitTime: const Duration(seconds: 30),
        lease: Duration.zero,
        pollInterval: const Duration(milliseconds: 10),
      );

      final screen = await limiter.acquire(priority: () => 100);
      screen.release();
      final prefetched = await limiter.acquire(priority: () => 20);

      // Queued as a guess, then the reader jumps to it.
      var priority = 20;
      var started = false;
      final queued = limiter.acquire(priority: () => priority).then((slot) {
        started = true;
        return slot;
      });

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(started, isFalse, reason: 'the single lane is occupied');

      priority = 100;
      final slot = await queued;
      expect(started, isTrue,
          reason: 'a page on screen is not speculative any more');

      slot.release();
      prefetched.release();
    });
  });
}
