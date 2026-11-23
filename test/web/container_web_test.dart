@Tags(['web'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

import 'files.dart';

const _weatherFiles = [
  ('apache/weather.avro', 'null'),
  ('apache/weather-deflate.avro', 'deflate'),
  ('apache/weather-snappy.avro', 'snappy'),
  ('apache/weather-zstd.avro', 'zstandard'),
  ('compressions/weather-bzip2.avro', 'bzip2'),
  ('compressions/weather-xz.avro', 'xz'),
  ('compressions/weather-zstandard.avro', 'zstandard'),
];

const _compressions = ['null', 'deflate', 'snappy', 'bzip2', 'xz', 'zstandard'];

/// [bytes] as a stream of pieces of [size] bytes.
Stream<List<int>> _chunked(Uint8List bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield Uint8List.sublistView(
      bytes,
      i,
      i + size < bytes.length ? i + size : bytes.length,
    );
  }
}

/// A container file of the one block [block], compressed as [compression].
Uint8List _oneBlock(String compression, Uint8List block) {
  final long = AvroCodec(writer: Schema.parse('"long"'));
  final meta = AvroCodec(
    writer: Schema.parse('{"type": "map", "values": "bytes"}'),
  );
  final sync = List.generate(16, (i) => i);
  return Uint8List.fromList([
    ...'Obj'.codeUnits,
    1,
    ...meta.encode({
      'avro.schema': Uint8List.fromList('"null"'.codeUnits),
      'avro.codec': Uint8List.fromList(compression.codeUnits),
    }),
    ...sync,
    ...long.encode(1),
    ...long.encode(block.length),
    ...block,
    ...sync,
  ]);
}

void main() {
  final weather = weatherRecords();

  group("Apache Avro's weather files", () {
    for (final (name, compression) in _weatherFiles) {
      test('$name reads to weather.json', () {
        final reader = AvroFileReader(webBytes(name));
        expect(reader.header.compression, compression);
        expect(reader.records().toList(), weather);
      });

      test('$name streams to weather.json in chunks of 7 bytes', () async {
        final reader = await AvroFileStreamReader.open(
          _chunked(webBytes(name), 7),
        );
        expect(reader.header.compression, compression);
        expect(await reader.records().toList(), weather);
      });
    }

    test('syncInMeta.avro, whose metadata holds its sync marker, reads', () {
      final bytes = webBytes('apache/syncInMeta.avro');
      expect(AvroFileReader(bytes).records().length, greaterThan(0));
    });
  });

  test('the example file of paxel/axt spec/envelope.md, section 10.3', () {
    final reader = AvroFileReader(webHex('axt/memo-file.hex'));
    expect(reader.header.compression, 'null');
    expect(Schema.parse(reader.header.schemaJson).crc64, 0xa89eceb9716f3016);
    final own = AvroCodec(
      writer: Schema.parse(webText('axt/envelope-canonical.json')),
    );
    final records = reader.records(own).toList();
    expect(records, hasLength(1));
    expect(
      own.encode(records.single),
      webHex('axt/memo-message.hex').sublist(10),
    );
  });

  group('every compression', () {
    final codec = AvroCodec(
      writer: Schema.parse(
        '{"type": "record", "name": "R", "fields": ['
        '{"name": "n", "type": "long"}, {"name": "s", "type": "string"}]}',
      ),
    );
    final records = [
      for (var i = 0; i < 300; i++)
        {'n': i * 0x100000001 - 0x7fffffffffffffff, 's': 'record $i'},
    ];

    for (final compression in _compressions) {
      test('$compression: written and read in memory', () {
        final writer = AvroFileWriter(
          codec,
          compression: compression,
          blockSize: 1024,
        );
        records.forEach(writer.add);
        final reader = AvroFileReader(writer.close());
        expect(reader.records().toList(), records);
      });

      test('$compression: written and read as streams', () async {
        final sink = StreamController<List<int>>();
        final bytes = sink.stream.fold(<int>[], (all, c) => all..addAll(c));
        final writer = AvroFileStreamWriter(
          codec,
          sink,
          compression: compression,
          blockSize: 1024,
        );
        records.forEach(writer.add);
        await writer.close();
        final reader = await AvroFileStreamReader.open(
          _chunked(Uint8List.fromList(await bytes), 100),
        );
        expect(await reader.records().toList(), records);
      });
    }
  });

  group('limits', () {
    for (final (compression, name) in [
      ('bzip2', 'bomb-bzip2'),
      ('xz', 'bomb-xz'),
      ('xz', 'bomb-xz-x86'),
      ('xz', 'bomb-xz-sizes'),
      ('zstandard', 'bomb-zstandard'),
    ]) {
      test('$name.bin stops at the limit', () {
        final bytes = _oneBlock(
          compression,
          webBytes('compressions/$name.bin'),
        );
        for (final (limits, limit) in [
          (const AvroLimits(maxBlockBytes: 1024 * 1024), 'maxBlockBytes'),
          (
            const AvroLimits(maxBlockBytes: null, maxTotalBytes: 1024 * 1024),
            'maxTotalBytes',
          ),
        ]) {
          expect(
            () => AvroFileReader(bytes, limits: limits).records().toList(),
            throwsA(
              isA<LimitExceededException>().having(
                (e) => e.limit,
                'limit',
                limit,
              ),
            ),
          );
        }
      });
    }

    test('a deflate bomb stops at the block limit', () {
      final writer = AvroFileWriter(
        AvroCodec(
          writer: Schema.parse(
            '{"type": "fixed", "name": "F", "size": 16777216}',
          ),
        ),
        compression: 'deflate',
      );
      writer.add(Uint8List(16 * 1024 * 1024));
      expect(
        () => AvroFileReader(
          writer.close(),
          limits: const AvroLimits(maxBlockBytes: 1024 * 1024),
        ).records().toList(),
        throwsA(
          isA<LimitExceededException>().having(
            (e) => e.limit,
            'limit',
            'maxBlockBytes',
          ),
        ),
      );
    });
  });
}
