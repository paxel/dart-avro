// The fuzz targets: the two entry points that take untrusted bytes, AvroCodec.decode (with
// single-object encoding) and AvroFileReader with its records. Any input must either decode
// or throw an AvroException.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:avro/avro.dart';

/// Limits that keep one input cheap; a bomb in any compression must stop at the block limit.
const fuzzLimits = AvroLimits(
  maxBlockBytes: 1024 * 1024,
  maxTotalBytes: 4 * 1024 * 1024,
  maxValueDepth: 256,
  maxZeroSizeItems: 4096,
);

/// The schemas the codec target decodes with.
List<AvroCodec> fuzzCodecs() => [
  for (final text in [
    File('test/data/apache/interop.avsc').readAsStringSync(),
    File('test/data/axt/envelope-canonical.json').readAsStringSync(),
    '{"type": "record", "name": "L", "fields": [{"name": "v", "type": "long"}, '
        '{"name": "next", "type": ["null", "L"]}]}',
    '{"type": "array", "items": {"type": "map", "values": ["null", "string", "bytes"]}}',
    '{"type": "array", "items": "null"}',
    '{"type": "record", "name": "T", "fields": ['
        '{"name": "d", "type": {"type": "int", "logicalType": "date"}}, '
        '{"name": "t", "type": {"type": "long", "logicalType": "timestamp-micros"}}, '
        '{"name": "l", "type": {"type": "long", "logicalType": "local-timestamp-nanos"}}, '
        '{"name": "x", "type": {"type": "bytes", "logicalType": "decimal", "precision": 9, "scale": 2}}, '
        '{"name": "b", "type": {"type": "bytes", "logicalType": "big-decimal"}}, '
        '{"name": "u", "type": {"type": "string", "logicalType": "uuid"}}, '
        '{"name": "f", "type": {"type": "fixed", "name": "U", "size": 16, "logicalType": "uuid"}}, '
        '{"name": "r", "type": {"type": "fixed", "name": "R", "size": 12, "logicalType": "duration"}}]}',
  ])
    AvroCodec(writer: Schema.parse(text), limits: fuzzLimits),
];

/// A failure that is not an [AvroException]: a bug.
final class FuzzFailure {
  FuzzFailure(this.target, this.input, this.error, this.stack);

  final String target;
  final Uint8List input;
  final Object error;
  final StackTrace stack;

  @override
  String toString() =>
      '$target failed on ${input.length} bytes: $error\n'
      '${[for (final b in input.take(256)) b.toRadixString(16).padLeft(2, '0')].join()}\n$stack';
}

/// Runs every target on [input]; returns the first failure, or null.
FuzzFailure? fuzzOne(Uint8List input, List<AvroCodec> codecs) {
  FuzzFailure? run(String target, void Function() f) {
    try {
      f();
    } on AvroException {
      // Rejected as it should be.
    } on Object catch (e, s) {
      return FuzzFailure(target, input, e, s);
    }
    return null;
  }

  for (final codec in codecs) {
    final failure =
        run('decode ${codec.writer.type}', () => codec.decode(input)) ??
        run('decodeSingleObject', () => codec.decodeSingleObject(input));
    if (failure != null) return failure;
  }
  return run(
        'SingleObjectHeader.parse',
        () => SingleObjectHeader.parse(input),
      ) ??
      run(
        'AvroFileReader',
        () => AvroFileReader(input, limits: fuzzLimits).records().length,
      ) ??
      run('Schema.parse', () {
        final text = String.fromCharCodes(input);
        Schema.parse(text, limits: fuzzLimits);
      });
}

/// Valid inputs to mutate.
List<Uint8List> fuzzSeeds(List<AvroCodec> codecs) {
  Uint8List hex(String path) {
    final h = File(path).readAsStringSync().trim();
    return Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16),
    ]);
  }

  final message = hex('test/data/axt/memo-message.hex');
  final list = codecs[2];
  final logical = codecs[5];
  final logicalValue = {
    'd': const AvroDate(2000, 1, 1),
    't': DateTime.utc(2000),
    'l': const AvroLocalTimestamp(2000, 1, 1, 12),
    'x': AvroDecimal(BigInt.from(12345), 2),
    'b': AvroDecimal(BigInt.from(-5), 7),
    'u': '123e4567-e89b-12d3-a456-426614174000',
    'f': '123e4567-e89b-12d3-a456-426614174000',
    'r': const AvroDuration(1, 2, 3),
  };
  final deflated = AvroFileWriter(list, compression: 'deflate')
    ..add({'v': 1, 'next': null})
    ..add({
      'v': 2,
      'next': {'v': 3, 'next': null},
    });
  final snappy = AvroFileWriter(list, compression: 'snappy')
    ..add({'v': 1, 'next': null})
    ..add({
      'v': 2,
      'next': {
        'v': 2,
        'next': {'v': 2, 'next': null},
      },
    });
  return [
    message,
    Uint8List.sublistView(message, 10),
    hex('test/data/axt/memo-file.hex'),
    File('test/data/apache/weather.avro').readAsBytesSync(),
    File('test/data/apache/weather-deflate.avro').readAsBytesSync(),
    deflated.close(),
    File('test/data/apache/weather-snappy.avro').readAsBytesSync(),
    snappy.close(),
    File('test/data/apache/weather-zstd.avro').readAsBytesSync(),
    for (final compression in ['bzip2', 'xz', 'zstandard']) ...[
      File('test/data/compressions/weather-$compression.avro')
          .readAsBytesSync(),
      (AvroFileWriter(list, compression: compression)
            ..add({'v': 1, 'next': null})
            ..add({
              'v': 2,
              'next': {'v': 3, 'next': null},
            }))
          .close(),
    ],
    logical.encode(logicalValue),
    logical.encodeSingleObject(logicalValue),
    codecs[3].encode([
      {'a': null, 'b': 'x', 'c': Uint8List(3)},
    ]),
    Uint8List.fromList(File('test/data/apache/interop.avsc').readAsBytesSync()),
  ];
}

/// One mutation of [seed].
Uint8List mutate(Uint8List seed, Random random) {
  final bytes = List<int>.of(seed);
  final rounds = 1 + random.nextInt(4);
  for (var r = 0; r < rounds; r++) {
    final at = bytes.isEmpty ? 0 : random.nextInt(bytes.length);
    switch (random.nextInt(7)) {
      case 0 when bytes.isNotEmpty:
        bytes[at] ^= 1 << random.nextInt(8);
      case 1 when bytes.isNotEmpty:
        bytes[at] = random.nextInt(256);
      case 2:
        bytes.insert(at, random.nextInt(256));
      case 3 when bytes.isNotEmpty:
        bytes.removeAt(at);
      case 4 when bytes.isNotEmpty:
        bytes.length = at;
      case 5:
        // A large varint, as a declared length or count.
        final big = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f];
        bytes.insertAll(at, big.sublist(random.nextInt(big.length)));
      default:
        final from = bytes.isEmpty ? 0 : random.nextInt(bytes.length);
        final length = bytes.isEmpty
            ? 0
            : random.nextInt(min(16, bytes.length - from) + 1);
        bytes.insertAll(at, bytes.sublist(from, from + length));
    }
  }
  return Uint8List.fromList(bytes);
}
