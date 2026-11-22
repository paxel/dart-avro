// Needs dart:io, or test data read from files: not one of the web tests.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:avro/src/snappy.dart';
import 'package:test/test.dart';

Uint8List decompress(List<int> input, {int offset = 0}) =>
    snappyDecompress(Uint8List.fromList(input), (_) {}, offset);

Matcher throwsDecode(String message, [int? offset]) => throwsA(
  isA<DecodeException>()
      .having((e) => e.message, 'message', contains(message))
      .having((e) => e.offset, 'offset', offset ?? anything),
);

void main() {
  group('round trip', () {
    final random = Random(20261121);
    final inputs = {
      'empty': Uint8List(0),
      'one byte': Uint8List.fromList([7]),
      'three bytes': Uint8List.fromList([1, 2, 3]),
      'text': Uint8List.fromList(
        utf8.encode('the quick brown fox jumps over the lazy dog, ' * 50),
      ),
      'zeros over 64 KiB': Uint8List(200 * 1024),
      'random': Uint8List.fromList(
        List.generate(100000, (_) => random.nextInt(256)),
      ),
      'random over a small alphabet': Uint8List.fromList(
        List.generate(300000, (_) => random.nextInt(4)),
      ),
      'a repeat further back than 64 KiB': Uint8List.fromList([
        ...List.generate(70000, (i) => (i * 7919) & 0xff),
        ...List.generate(70000, (i) => (i * 7919) & 0xff),
      ]),
    };
    for (final MapEntry(key: name, value: input) in inputs.entries) {
      test(name, () {
        final compressed = snappyCompress(input);
        expect(snappyDecompress(compressed, (_) {}), input);
      });
    }

    test('repeats compress', () {
      expect(snappyCompress(inputs['text']!).length, lessThan(200));
      expect(
        snappyCompress(inputs['zeros over 64 KiB']!).length,
        lessThan(12000),
      );
    });

    test('copies of every length from 4 to 200 split correctly', () {
      for (var length = 4; length <= 200; length++) {
        final input = Uint8List.fromList([
          for (var i = 0; i < 300; i++) i < 100 ? i : 255 - i % 100,
          for (var i = 0; i < length; i++) i % 100,
        ]);
        expect(snappyDecompress(snappyCompress(input), (_) {}), input);
      }
    });
  });

  group('every element', () {
    test('a literal with its length in the tag', () {
      expect(decompress([3, 2 << 2, 1, 2, 3]), [1, 2, 3]);
    });

    test('a literal with its length in 1 to 4 more bytes, little-endian', () {
      for (var bytes = 1; bytes <= 4; bytes++) {
        expect(
          decompress([
            3,
            (59 + bytes) << 2,
            2,
            ...List.filled(bytes - 1, 0),
            7,
            8,
            9,
          ]),
          [7, 8, 9],
        );
      }
      final long = List.generate(300, (i) => i & 0xff);
      expect(decompress([0xac, 0x02, 61 << 2, 0x2b, 0x01, ...long]), long);
    });

    test('a copy with a 1-byte offset, overlapping what it writes', () {
      // "ab", then 6 bytes from 2 back.
      expect(
        decompress([8, 1 << 2, 0x61, 0x62, 1 | (2 << 2), 2]),
        utf8.encode('abababab'),
      );
    });

    test('a copy with an 11-bit offset', () {
      final literal = List.generate(300, (i) => i & 0xff);
      // 4 bytes from 300 back: 300 = 0x12c, so the tag holds 1 in its top bits.
      expect(
        decompress([
          0xb0,
          0x02,
          61 << 2,
          0x2b,
          0x01,
          ...literal,
          1 | (1 << 5),
          0x2c,
        ]),
        [...literal, 0, 1, 2, 3],
      );
    });

    test('a copy with a 2-byte and with a 4-byte offset', () {
      expect(decompress([7, 2 << 2, 5, 6, 7, 2 | (3 << 2), 3, 0]), [
        5,
        6,
        7,
        5,
        6,
        7,
        5,
      ]);
      expect(decompress([7, 2 << 2, 5, 6, 7, 3 | (3 << 2), 2, 0, 0, 0]), [
        5,
        6,
        7,
        6,
        7,
        6,
        7,
      ]);
    });

    test(
      'the declared length goes to the check before the output is allocated',
      () {
        final seen = <int>[];
        expect(
          () => snappyDecompress(
            Uint8List.fromList([0xff, 0xff, 0xff, 0xff, 0x0f]),
            (length) {
              seen.add(length);
              throw const LimitExceededException(
                'too big',
                limit: 'maxBlockBytes',
              );
            },
          ),
          throwsA(isA<LimitExceededException>()),
        );
        expect(seen, [0xffffffff]);
      },
    );
  });

  group('rejected', () {
    test('a cut off or over-long uncompressed length', () {
      expect(
        () => decompress([]),
        throwsDecode('the uncompressed length is cut off'),
      );
      expect(
        () => decompress([0x80]),
        throwsDecode('the uncompressed length is cut off'),
      );
      expect(
        () => decompress([0xff, 0xff, 0xff, 0xff, 0x10]),
        throwsDecode('does not fit 32 bits'),
      );
    });

    test('a declared length the input cannot hold, before allocating', () {
      expect(
        () => decompress([0xff, 0xff, 0xff, 0xff, 0x0f, 0]),
        throwsDecode('more than its 1 bytes can hold'),
      );
    });

    test('a cut off element', () {
      expect(
        () => decompress([3, 60 << 2]),
        throwsDecode('an element is cut off', 1),
      );
      expect(
        () => decompress([3, 2 << 2, 1]),
        throwsDecode('a literal of 3 bytes is cut off'),
      );
      expect(
        () => decompress([4, 0, 1, 1]),
        throwsDecode('an element is cut off'),
      );
      expect(
        () => decompress([4, 0, 1, 2, 1]),
        throwsDecode('an element is cut off'),
      );
      expect(
        () => decompress([4, 0, 1, 3, 1, 0, 0]),
        throwsDecode('an element is cut off'),
      );
    });

    test('a copy from before the start or from 0 back', () {
      expect(
        () => decompress([5, 0, 1, 1, 2]),
        throwsDecode('reaches 2 bytes back, but 1 are written'),
      );
      expect(
        () => decompress([5, 0, 1, 1, 0]),
        throwsDecode('reaches 0 bytes back'),
      );
    });

    test('an element beyond the declared length', () {
      expect(
        () => decompress([1, 1 << 2, 1, 2]),
        throwsDecode('a literal goes beyond the declared 1 bytes'),
      );
      expect(
        () => decompress([4, 0, 1, 1, 1]),
        throwsDecode('a copy goes beyond the declared 4 bytes'),
      );
    });

    test('fewer bytes than declared', () {
      expect(
        () => decompress([4, 0, 1]),
        throwsDecode('it holds 1 bytes, but declares 4', 3),
      );
    });

    test('with offsets counted from the given start', () {
      expect(
        () => decompress([3, 60 << 2], offset: 100),
        throwsDecode('cut off', 101),
      );
    });
  });

  group('crc32', () {
    test('the check value of the IEEE polynomial', () {
      expect(crc32(ascii.encode('123456789')), 0xcbf43926);
      expect(crc32([]), 0);
    });

    test('is the CRC32 that gzip writes, as zlib computes it', () {
      final random = Random(7);
      final data = List.generate(5000, (_) => random.nextInt(256));
      final gzip = GZipCodec().encode(data);
      final trailer = ByteData.sublistView(
        Uint8List.fromList(gzip),
        gzip.length - 8,
      );
      expect(crc32(data), trailer.getUint32(0, Endian.little));
    });
  });
}
