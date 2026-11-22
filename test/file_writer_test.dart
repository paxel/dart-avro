// Needs dart:io, or test data read from files: not one of the web tests.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

Uint8List hexFile(String path) {
  final hex = File(path).readAsStringSync().trim();
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

final sync = Uint8List.fromList(List.generate(16, (i) => i));

void main() {
  test('the example file of paxel/axt spec/envelope.md, section 10.3, byte for byte', () {
    final original = hexFile('test/data/axt/memo-file.hex');
    final header = AvroFileReader(original).header;
    final envelope = AvroCodec(
      writer: Schema.parse(
        File('test/data/axt/envelope-canonical.json').readAsStringSync(),
      ),
    );
    final message = hexFile('test/data/axt/memo-message.hex');
    final record = envelope.decode(Uint8List.sublistView(message, 10));

    final writer = AvroFileWriter(
      envelope,
      metadata: {
        for (final key in ['axt.schemas', 'axt.sender', 'axt.signature'])
          key: header.metadata[key]!,
      },
      schemaJson: header.schemaJson,
      syncMarker: sync,
    )..add(record);
    final written = writer.close();

    expect(written, original);
    expect(
      crypto.sha256.convert(written).toString(),
      '37074c1f86d048a02e906441adc37f41599d1c9776fb2ae594a3f068f257a94c',
    );
  });

  group('written files read back', () {
    final codec = AvroCodec(
      writer: Schema.parse(
        '{"type": "record", "name": "R", "fields": [{"name": "n", "type": "long"}, '
        '{"name": "s", "type": "string"}]}',
      ),
    );
    final records = [
      for (var i = 0; i < 1000; i++) {'n': i, 's': 'record $i'},
    ];

    for (final compression in [
      'null',
      'deflate',
      'snappy',
      'bzip2',
      'xz',
      'zstandard',
    ]) {
      test('with $compression, in several blocks', () {
        final writer = AvroFileWriter(
          codec,
          compression: compression,
          blockSize: 1000,
        );
        records.forEach(writer.add);
        final bytes = writer.close();
        final reader = AvroFileReader(bytes);
        expect(reader.header.compression, compression);
        expect(reader.records().toList(), records);
        expect(reader.records(codec).toList(), records);
      });
    }

    test('with snappy, a record larger than 64 KiB', () {
      final bytes = AvroFileWriter(
        AvroCodec(writer: Schema.parse('"bytes"')),
        compression: 'snappy',
      )..add(Uint8List.fromList(List.generate(200000, (i) => i % 251)));
      final records = AvroFileReader(bytes.close()).records().toList();
      expect(records.single, List.generate(200000, (i) => i % 251));
    });

    test('blocks of records that take no bytes, in every compression', () {
      final nulls = AvroCodec(writer: Schema.parse('"null"'));
      for (final compression in [
        'deflate',
        'snappy',
        'bzip2',
        'xz',
        'zstandard',
      ]) {
        final writer = AvroFileWriter(nulls, compression: compression)
          ..add(null)
          ..add(null);
        expect(AvroFileReader(writer.close()).records().toList(), [
          null,
          null,
        ], reason: compression);
      }
    });

    test('flush ends a block, and an empty file has no block', () {
      final writer = AvroFileWriter(codec, syncMarker: sync)
        ..add(records[0])
        ..flush()
        ..flush()
        ..add(records[1]);
      final bytes = writer.close();
      final occurrences = [
        for (var i = 0; i + 16 <= bytes.length; i++)
          if (_same(bytes, i, sync)) i,
      ];
      expect(occurrences, hasLength(3)); // the header's and two blocks'
      final empty = AvroFileWriter(codec, syncMarker: sync).close();
      expect(AvroFileReader(empty).records(), isEmpty);
      expect(_same(empty, empty.length - 16, sync), isTrue);
    });
  });

  test(
    'metadata comes in the caller order, then avro.codec and avro.schema',
    () {
      final codec = AvroCodec(writer: Schema.parse('"int"'));
      final bytes = AvroFileWriter(
        codec,
        metadata: {
          'z': Uint8List.fromList([1]),
          'a': Uint8List.fromList([2]),
        },
      ).close();
      final header = AvroFileReader(bytes).header;
      expect(header.metadata.keys, ['z', 'a', 'avro.codec', 'avro.schema']);
      expect(utf8.decode(header.metadata['avro.codec']!), 'null');
      expect(header.schemaJson, '"int"');
    },
  );

  test('a random sync marker by default', () {
    final codec = AvroCodec(writer: Schema.parse('"int"'));
    expect(
      AvroFileWriter(codec).syncMarker,
      isNot(AvroFileWriter(codec).syncMarker),
    );
  });

  group('rejected', () {
    final codec = AvroCodec(writer: Schema.parse('"int"'));

    test('a reserved metadata key', () {
      expect(
        () => AvroFileWriter(codec, metadata: {'avro.codec': Uint8List(0)}),
        throwsArgumentError,
      );
    });

    test('another compression', () {
      expect(
        () => AvroFileWriter(codec, compression: 'lz4'),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });

    test('a schema text of another schema', () {
      expect(
        () => AvroFileWriter(codec, schemaJson: '"long"'),
        throwsArgumentError,
      );
      expect(
        AvroFileWriter(codec, schemaJson: '{"type": "int"}').close(),
        isNotEmpty,
      );
    });

    test('a sync marker of another size', () {
      expect(
        () => AvroFileWriter(codec, syncMarker: Uint8List(3)),
        throwsArgumentError,
      );
    });

    test('a record that does not fit, leaving the file unchanged', () {
      final writer = AvroFileWriter(codec)..add(1);
      expect(() => writer.add('x'), throwsA(isA<EncodeException>()));
      writer.add(2);
      expect(AvroFileReader(writer.close()).records().toList(), [1, 2]);
    });

    test('adding after close', () {
      final writer = AvroFileWriter(codec)..close();
      expect(() => writer.add(1), throwsStateError);
    });
  });
}

bool _same(Uint8List bytes, int at, Uint8List marker) {
  for (var i = 0; i < marker.length; i++) {
    if (bytes[at + i] != marker[i]) return false;
  }
  return true;
}
