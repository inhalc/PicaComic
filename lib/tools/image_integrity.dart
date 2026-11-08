/// Shared helpers for validating downloaded image payloads.
///
/// They live in a dependency-free file so the regression tests can exercise
/// them without pulling in the whole networking stack.

/// A small slack avoids false positives from a trailing newline/padding.
const int kImageLengthSlack = 16;

/// Whether a response ended before its advertised Content-Length.
///
/// A truncated JPEG/PNG still has a valid magic header, so the downloader
/// used to write it to disk and count the page as finished (issue #130).
bool isTruncatedResponse(int received, int? expected) {
  if (expected == null || expected <= 0) return false;
  return received + kImageLengthSlack < expected;
}

/// Throw when a stream finished early so callers retry instead of caching a
/// corrupt image.
void checkImageComplete(int received, int? expected, String url) {
  if (isTruncatedResponse(received, expected)) {
    throw Exception(
        'Incomplete image response: received $received of $expected bytes ($url)');
  }
}

/// Progress target for a streaming response. `+ 1` keeps the progress bar
/// from reporting 100% before the final frame is emitted; a missing
/// Content-Length must not turn into a null-arithmetic crash.
int imageProgressTarget(int? expected, int current) =>
    expected == null ? current + 1 : expected + 1;

/// Magic-byte fallback for responses the mime database cannot classify.
///
/// An empty extension used to produce an extension-less file that the reader
/// silently skipped, while the task was still counted as finished (#130).
String fallbackImageExtension(List<int> data) {
  bool has(int i, int value) => i < data.length && data[i] == value;
  if (has(0, 0xFF) && has(1, 0xD8) && has(2, 0xFF)) return '.jpg';
  if (has(0, 0x89) && has(1, 0x50) && has(2, 0x4E) && has(3, 0x47)) {
    return '.png';
  }
  if (has(0, 0x47) && has(1, 0x49) && has(2, 0x46) && has(3, 0x38)) {
    return '.gif';
  }
  if (has(0, 0x52) &&
      has(1, 0x49) &&
      has(2, 0x46) &&
      has(3, 0x46) &&
      has(8, 0x57) &&
      has(9, 0x45) &&
      has(10, 0x42) &&
      has(11, 0x50)) {
    return '.webp';
  }
  return '';
}
