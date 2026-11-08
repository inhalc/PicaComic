import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/image_integrity.dart';

void main() {
  /// A realistic image buffer: magic bytes followed by padding so the
  /// payload clears the minimum-length guard (real images are >> 64 bytes).
  List<int> payload(List<int> magic, [int size = 128]) {
    final data = List<int>.filled(size, 0);
    for (var i = 0; i < magic.length && i < size; i++) {
      data[i] = magic[i];
    }
    return data;
  }

  const jpeg = <int>[0xFF, 0xD8, 0xFF];
  const png = <int>[0x89, 0x50, 0x4E, 0x47];
  const gif = <int>[0x47, 0x49, 0x46, 0x38]; // "GIF8"
  const webp = <int>[
    0x52, 0x49, 0x46, 0x46, // "RIFF"
    0, 0, 0, 0,
    0x57, 0x45, 0x42, 0x50, // "WEBP"
  ];

  // JM anti-scraping answer: HTTP 200 + a 124-byte HTML error page (#93).
  final htmlErrorPage = <int>[
    0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E, // "<html>"
    ...List<int>.filled(118, 0x20),
  ];

  group('imagePayloadError (#93)', () {
    test('rejects a 124-byte HTML error page', () {
      expect(htmlErrorPage.length, 124);
      expect(imagePayloadError(htmlErrorPage), isNotNull);
      expect(isValidImagePayload(htmlErrorPage), isFalse);
      expect(
        imagePayloadError(htmlErrorPage,
            contentType: 'text/html; charset=UTF-8'),
        isNotNull,
      );
    });

    test('accepts valid JPEG / PNG / GIF / WEBP magic bytes', () {
      for (final magic in <List<int>>[jpeg, png, gif, webp]) {
        final data = payload(magic);
        expect(imagePayloadError(data), isNull,
            reason: 'magic $magic should be a valid payload');
        expect(isValidImagePayload(data), isTrue);
      }
    });

    test('rejects empty and too-short data', () {
      expect(imagePayloadError(<int>[]), isNotNull);
      expect(isValidImagePayload(<int>[]), isFalse);
      expect(
        imagePayloadError(<int>[0xFF, 0xD8, 0xFF]),
        isNotNull,
        reason: 'a bare JPEG signature is too short to be a real image',
      );
    });

    test('the 64-byte minimum is an inclusive boundary', () {
      expect(isValidImagePayload(payload(jpeg, 64)), isTrue);
      expect(isValidImagePayload(payload(jpeg, 63)), isFalse);
    });

    test('rejects text content types even with valid magic', () {
      final data = payload(jpeg);
      for (final type in <String>[
        'text/html',
        'TEXT/HTML',
        'text/html; charset=utf-8',
        'application/json',
        'text/plain; charset=iso-8859-1',
      ]) {
        expect(imagePayloadError(data, contentType: type), isNotNull,
            reason: '$type must be rejected regardless of magic bytes');
      }
    });

    test('allows octet-stream / null type with valid magic', () {
      final data = payload(png);
      expect(
        imagePayloadError(data, contentType: 'application/octet-stream'),
        isNull,
      );
      expect(imagePayloadError(data, contentType: null), isNull);
      expect(
        isValidImagePayload(data, contentType: 'application/octet-stream'),
        isTrue,
      );
    });

    test('does not reject unknown binary image formats (#93 regression)', () {
      // BMP / AVIF / JPEG XL are not in fallbackImageExtension's whitelist,
      // but the decoder may still support them. Only clear text error pages
      // may be rejected, otherwise a whole comic source would break.
      final bmp = payload(const <int>[0x42, 0x4D, 0x00, 0x10]);
      final avif = payload(const <int>[
        0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70,
        0x61, 0x76, 0x69, 0x66,
      ]);
      expect(imagePayloadError(bmp), isNull);
      expect(imagePayloadError(avif), isNull);
      expect(isValidImagePayload(bmp), isTrue);
    });

    test('rejects a text error page without a Content-Type (#93)', () {
      final errorPage = <int>[
        ...'<html><body>Access denied</body></html>'.codeUnits,
        ...List<int>.filled(80, 0x20),
      ];
      expect(imagePayloadError(errorPage), isNotNull);
      expect(isValidImagePayload(errorPage), isFalse);
    });
  });

  group('isTruncatedResponse boundaries (#130)', () {
    test('missing / non-positive expected length is never truncated', () {
      expect(isTruncatedResponse(100, null), isFalse);
      expect(isTruncatedResponse(100, 0), isFalse);
      expect(isTruncatedResponse(100, -1), isFalse);
    });

    test('the kImageLengthSlack slack is inclusive', () {
      // received + slack == expected -> not truncated
      expect(isTruncatedResponse(100, 100 + kImageLengthSlack), isFalse);
      // one byte beyond the slack -> truncated
      expect(isTruncatedResponse(100, 100 + kImageLengthSlack + 1), isTrue);
      expect(isTruncatedResponse(1000, 1000), isFalse);
      expect(isTruncatedResponse(990, 1000), isFalse);
      expect(isTruncatedResponse(983, 1000), isTrue);
    });
  });
}
