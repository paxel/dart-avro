import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

Uint8List hexFile(String path) {
  final hex = File(path).readAsStringSync().trim();
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

final _long = AvroCodec(writer: Schema.parse('"long"'));
final _meta = AvroCodec(
  writer: Schema.parse('{"type": "map", "values": "bytes"}'),
);

/// A container file built by hand, so that the reader is tested without the writer.
Uint8List file({
  required String schema,
  String? compression,
  required List<(int, List<int>)> blocks,
  List<int>? sync,
  List<int>? blockSync,
}) {
  final marker = sync ?? List.generate(16, (i) => i);
  final out = BytesBuilder()
    ..add(utf8.encode('Obj'))
    ..addByte(1)
    ..add(
      _meta.encode({
        'avro.schema': Uint8List.fromList(utf8.encode(schema)),
        if (compression != null)
          'avro.codec': Uint8List.fromList(utf8.encode(compression)),
      }),
    )
    ..add(marker);
  for (final (count, data) in blocks) {
    out
      ..add(_long.encode(count))
      ..add(_long.encode(data.length))
      ..add(data)
      ..add(blockSync ?? marker);
  }
  return out.takeBytes();
}

Uint8List deflate(List<int> data) =>
    Uint8List.fromList(ZLibEncoder(raw: true).convert(data));

void main() {
  final weather = [
    for (final line in File('test/data/apache/weather.json').readAsLinesSync())
      if (line.isNotEmpty) jsonDecode(line),
  ];

  group("Apache Avro's weather files", () {
    for (final name in ['weather.avro', 'weather-deflate.avro']) {
      test('$name reads to weather.json', () {
        final reader = AvroFileReader(
          File('test/data/apache/$name').readAsBytesSync(),
        );
        expect(
          reader.header.compression,
          name.contains('deflate') ? 'deflate' : 'null',
        );
        expect(Schema.parse(reader.header.schemaJson), isA<RecordSchema>());
        expect(reader.records().toList(), weather);
      });
    }

    test('syncInMeta.avro, whose metadata holds its sync marker, reads', () {
      final reader = AvroFileReader(
        File('test/data/apache/syncInMeta.avro').readAsBytesSync(),
      );
      expect(reader.records().length, greaterThan(0));
    });
  });

  test('the example file of paxel/axt spec/envelope.md, section 10.3', () {
    final reader = AvroFileReader(hexFile('test/data/axt/memo-file.hex'));
    final h = reader.header;
    expect(h.metadata.keys, [
      'axt.schemas',
      'axt.sender',
      'axt.signature',
      'avro.codec',
      'avro.schema',
    ]);
    expect(h.metadata['axt.schemas'], hasLength(2014));
    expect(h.compression, 'null');
    expect(h.syncMarker, List.generate(16, (i) => i));
    expect(Schema.parse(h.schemaJson).crc64, 0xa89eceb9716f3016);

    // AXT decodes with its own copy of the envelope schema, never the file's.
    final own = AvroCodec(
      writer: Schema.parse(
        File('test/data/axt/envelope-canonical.json').readAsStringSync(),
      ),
    );
    final records = reader.records(own).toList();
    expect(records, hasLength(1));
    final message = hexFile('test/data/axt/memo-message.hex');
    expect(own.encode(records.single), message.sublist(10));
  });

  test('a file reads lazily, one block at a time', () {
    final bytes = file(
      schema: '"int"',
      blocks: [
        (2, [2, 4]),
        (1, [6]),
        (1, [0xff]), // a truncated varint
      ],
    );
    final it = AvroFileReader(bytes).records().iterator;
    expect(it.moveNext() && it.current == 1, isTrue);
    expect(it.moveNext() && it.current == 2, isTrue);
    expect(it.moveNext() && it.current == 3, isTrue);
    expect(it.moveNext, throwsA(isA<DecodeException>()));
  });

  test('an absent avro.codec means null; another compression is rejected', () {
    expect(
      AvroFileReader(file(schema: '"int"', blocks: [])).header.compression,
      'null',
    );
    expect(
      () => AvroFileReader(
        file(schema: '"int"', compression: 'snappy', blocks: []),
      ),
      throwsA(
        isA<UnsupportedCompressionException>().having(
          (e) => e.compression,
          'compression',
          'snappy',
        ),
      ),
    );
  });

  group('rejected', () {
    test('a file without the magic', () {
      expect(
        () => AvroFileReader(Uint8List.fromList([0x4f, 0x62])),
        throwsA(isA<DecodeException>()),
      );
      expect(
        () => AvroFileReader(Uint8List.fromList(utf8.encode('Obj\x02'))),
        throwsA(isA<DecodeException>()),
      );
    });

    test('a block whose sync marker differs', () {
      final bytes = file(
        schema: '"int"',
        blocks: [
          (1, [2]),
        ],
        blockSync: List.filled(16, 9),
      );
      expect(
        () => AvroFileReader(bytes).records().toList(),
        throwsA(isA<DecodeException>()),
      );
    });

    test('a block with bytes left after its records', () {
      final bytes = file(
        schema: '"int"',
        blocks: [
          (1, [2, 2]),
        ],
      );
      expect(
        () => AvroFileReader(bytes).records().toList(),
        throwsA(isA<DecodeException>()),
      );
    });

    test('a block that declares more records than it can hold', () {
      final bytes = file(
        schema: '"int"',
        blocks: [
          (1000, [2]),
        ],
      );
      expect(
        () => AvroFileReader(bytes).records().toList(),
        throwsA(isA<DecodeException>()),
      );
    });

    test('a block that is not DEFLATE', () {
      final bytes = file(
        schema: '"int"',
        compression: 'deflate',
        blocks: [
          (1, [0xff, 0xff, 0xff]),
        ],
      );
      expect(
        () => AvroFileReader(bytes).records().toList(),
        throwsA(isA<DecodeException>()),
      );
    });
  });

  group('limits', () {
    test('a deflate bomb stops at the block limit', () {
      final bomb = deflate(Uint8List(16 * 1024 * 1024));
      expect(bomb.length, lessThan(64 * 1024));
      final bytes = file(
        schema: '"null"',
        compression: 'deflate',
        blocks: [(1, bomb)],
      );
      final reader = AvroFileReader(
        bytes,
        limits: const AvroLimits(maxBlockBytes: 1024 * 1024),
      );
      expect(
        () => reader.records().toList(),
        throwsA(
          isA<LimitExceededException>().having(
            (e) => e.limit,
            'limit',
            'maxBlockBytes',
          ),
        ),
      );
    });

    test('the total limit applies across blocks', () {
      final block = deflate(Uint8List(1000));
      final bytes = file(
        schema: '{"type": "fixed", "name": "F", "size": 1000}',
        compression: 'deflate',
        blocks: [(1, block), (1, block), (1, block)],
      );
      final reader = AvroFileReader(
        bytes,
        limits: const AvroLimits(maxTotalBytes: 2500),
      );
      final it = reader.records().iterator;
      expect(it.moveNext(), isTrue);
      expect(it.moveNext(), isTrue);
      expect(
        it.moveNext,
        throwsA(
          isA<LimitExceededException>().having(
            (e) => e.limit,
            'limit',
            'maxTotalBytes',
          ),
        ),
      );
    });

    test('a block of zero-size records over maxZeroSizeItems throws LimitExceededException', () {
      final bytes = file(schema: '"null"', blocks: [(10, <int>[])]);
      expect(
        () => AvroFileReader(
          bytes,
          limits: const AvroLimits(maxZeroSizeItems: 5),
        ).records().toList(),
        throwsA(
          isA<LimitExceededException>().having(
            (e) => e.limit,
            'limit',
            'maxZeroSizeItems',
          ),
        ),
      );
    });

    test('uncompressed blocks count as well', () {
      final bytes = file(
        schema: '{"type": "fixed", "name": "F", "size": 10}',
        blocks: [(1, Uint8List(10))],
      );
      expect(
        () => AvroFileReader(
          bytes,
          limits: const AvroLimits(maxBlockBytes: 5),
        ).records().toList(),
        throwsA(isA<LimitExceededException>()),
      );
    });
  });
}
