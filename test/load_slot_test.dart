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
}
