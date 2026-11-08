/// Shared helpers for validating downloaded image payloads.
///
/// They live in a dependency-free file so the regression tests can exercise
/// them without pulling in the whole networking stack.

import 'dart:convert';

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

/// Whether a byte buffer looks like an HTML/JSON/text error page rather than
/// an image. Real compressed image data almost always contains non-UTF-8
/// bytes or control characters, so it fails this check and is left alone.
///
/// This is deliberately conservative: unknown-but-binary formats (AVIF, BMP,
/// JPEG XL, custom-source payloads, ...) must NOT be rejected just because
/// [fallbackImageExtension] does not know their magic bytes. The decoder is
/// the final authority; here we only catch responses that are clearly text.
bool _looksLikeTextPayload(List<int> data) {
  final length = data.length > 256 ? 256 : data.length;
  String text;
  try {
    // Strict decoding: binary image data throws and is therefore not text.
    text = const Utf8Decoder().convert(data.sublist(0, length));
  } catch (_) {
    return false;
  }
  if (text.isEmpty) return false;
  for (final unit in text.codeUnits) {
    if (unit < 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) {
      return false;
    }
    if (unit == 0x7F) return false;
  }
  final lower = text.toLowerCase();
  return lower.contains('<') ||
      lower.contains('{') ||
      lower.contains('[') ||
      lower.contains('html') ||
      lower.contains('error') ||
      lower.contains('denied') ||
      lower.contains('forbidden') ||
      lower.contains('access');
}

/// Validate a downloaded image payload before it is decoded or cached.
///
/// JM's image CDN answers anti-scraping requests with HTTP 200 and a tiny
/// (124-byte) HTML/JSON error page. Such a response is length-consistent, so
/// [checkImageComplete] cannot catch it; the decoder then fails with the
/// opaque "Failed to decode image" message from issue #93. Reject it here.
///
/// Returns a human-readable error string, or `null` when [data] looks like a
/// decodable image. [contentType] is matched case-insensitively and tolerates
/// a `; charset=...` suffix. Deliberately does NOT require a known magic
/// signature, because that would break every image format outside
/// JPEG/PNG/GIF/WEBP (and custom comic sources that transform bytes).
String? imagePayloadError(List<int> data, {String? contentType}) {
  final type = contentType?.split(';').first.trim().toLowerCase();
  if (type == 'text/html' ||
      type == 'application/json' ||
      type == 'text/plain') {
    return 'Unsupported image Content-Type: $contentType';
  }

  // An error page (or any other non-image) is far smaller than a real photo.
  if (data.length < 64) {
    return 'Image payload is too short: ${data.length} bytes';
  }

  if (_looksLikeTextPayload(data)) {
    return 'Image response looks like a text error page '
        '(Content-Type: $contentType, length: ${data.length} bytes)';
  }
  return null;
}

/// Boolean wrapper around [imagePayloadError].
bool isValidImagePayload(List<int> data, {String? contentType}) =>
    imagePayloadError(data, contentType: contentType) == null;
