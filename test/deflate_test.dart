import 'dart:math';
import 'dart:typed_data';

import 'package:avro/src/deflate_archive.dart' as archive;
import 'package:avro/src/deflate_io.dart' as io;
import 'package:test/test.dart';

typedef _Deflate = Uint8List Function(Uint8List data);
typedef _Inflate = Uint8List Function(Uint8List data, void Function(int) check);

const _implementations = <(String, _Deflate, _Inflate)>[
  ('dart:io', io.deflateRaw, io.inflateRaw),
  ('archive', archive.deflateRaw, archive.inflateRaw),
];

void _none(int length) {}

/// A check that throws once the output passes [max], as the container's limits do.
void Function(int) _limit(int max) => (length) {
  if (length > max) throw _Stop(length);
};

final class _Stop implements Exception {
  _Stop(this.length);

  final int length;
}

Uint8List _random(int length, int seed) {
  final random = Random(seed);
  return Uint8List.fromList([
    for (var i = 0; i < length; i++) random.nextInt(256),
  ]);
}

void main() {
  final inputs = <String, Uint8List>{
    'empty': Uint8List(0),
    'one byte': Uint8List.fromList([42]),
    'compressible': Uint8List.fromList([
      for (var i = 0; i < 100000; i++) i % 7,
    ]),
    'random': _random(100000, 1),
  };

  for (final (name, deflate, inflate) in _implementations) {
    group(name, () {
      for (final (other, otherDeflate, _) in _implementations) {
        for (final MapEntry(key: input, value: data) in inputs.entries) {
          test('inflates $input deflated by $other', () {
            expect(inflate(otherDeflate(data), _none), data);
          });
        }
      }

      test('stops when the check throws, with what the check throws', () {
        final bomb = deflate(Uint8List(16 * 1024 * 1024));
        expect(bomb.length, lessThan(64 * 1024));
        var seen = 0;
        const max = 1024 * 1024;
        Object? thrown;
        try {
          inflate(bomb, (length) {
            seen = length;
            _limit(max)(length);
          });
        } on Object catch (e) {
          thrown = e;
        }
        expect(thrown, isA<_Stop>().having((e) => e.length, 'length', seen));
        // Stopped within one write of the limit (dart:io writes 64 KiB at a time), not after
        // inflating it all.
        expect(seen, lessThanOrEqualTo(max + 64 * 1024));
      });

      test('passes output of exactly the limit and stops one byte over it', () {
        final data = inputs['compressible']!;
        final compressed = deflate(data);
        expect(inflate(compressed, _limit(data.length)), data);
        expect(
          () => inflate(compressed, _limit(data.length - 1)),
          throwsA(isA<_Stop>()),
        );
      });

      test('ignores bytes after the final block', () {
        final data = inputs['compressible']!;
        expect(
          inflate(Uint8List.fromList([...deflate(data), 1, 2, 3]), _none),
          data,
        );
      });

      for (final (bad, bytes) in [
        ('0xff 0xff 0xff', [0xff, 0xff, 0xff]),
        ('block type 3', [0x07]),
      ]) {
        test('throws FormatException for $bad', () {
          expect(
            () => inflate(Uint8List.fromList(bytes), _none),
            throwsFormatException,
          );
        });
      }

      test('throws only FormatException for damaged data', () {
        final valid = deflate(inputs['compressible']!);
        final random = Random(2);
        for (var i = 0; i < 300; i++) {
          final Uint8List damaged;
          if (i.isEven) {
            damaged = Uint8List.fromList(valid);
            damaged[random.nextInt(damaged.length)] ^= 1 << random.nextInt(8);
          } else {
            damaged = _random(1 + random.nextInt(200), i);
          }
          try {
            inflate(damaged, _none);
          } on FormatException {
            // Expected for most, but some damage still inflates.
          }
        }
      });
    });
  }

  // dart:io's raw inflate cannot tell a stream that ends early from a complete one; archive
  // can, as it sees no final block. A cut block fails later on dart:io, when its records do
  // not decode.
  group('a stream that ends before its final block', () {
    final data = inputs['compressible']!;
    final full = io.deflateRaw(data);
    final cuts = {
      'empty': Uint8List(0),
      'half': Uint8List.sublistView(full, 0, full.length ~/ 2),
      'without its last byte': Uint8List.sublistView(full, 0, full.length - 1),
    };
    for (final MapEntry(key: cut, value: bytes) in cuts.entries) {
      test('$cut inflates short on dart:io', () {
        final out = io.inflateRaw(bytes, _none);
        expect(out.length, lessThanOrEqualTo(data.length));
        expect(out, data.sublist(0, out.length));
      });

      test('$cut throws FormatException on archive', () {
        expect(() => archive.inflateRaw(bytes, _none), throwsFormatException);
      });
    }
  });
}
