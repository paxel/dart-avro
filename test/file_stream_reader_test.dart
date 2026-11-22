// Needs dart:io, or test data read from files: not one of the web tests.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

import 'file_reader_test.dart' show deflate, file;

/// [bytes] as a stream of chunks of [size] bytes, the last one shorter.
Stream<List<int>> chunked(Uint8List bytes, int size) => Stream.fromIterable([
  for (var i = 0; i < bytes.length; i += size)
    bytes.sublist(i, min(i + size, bytes.length)),
]);

/// An error as it is compared: its type, its text with the offsets, and its limit.
String describe(Object e) =>
    '${e.runtimeType} $e${e is LimitExceededException ? ' ${e.limit}' : ''}';

/// The records [AvroFileReader] reads from [bytes], then its error, if any.
(List<Object?>, String?) inMemory(
  Uint8List bytes, {
  AvroLimits limits = const AvroLimits(),
  AvroCodec? codec,
}) {
  final records = <Object?>[];
  try {
    records.addAll(AvroFileReader(bytes, limits: limits).records(codec));
  } on AvroException catch (e) {
    return (records, describe(e));
  }
  return (records, null);
}

/// The same from [AvroFileStreamReader], with [bytes] in chunks of [chunk] bytes.
Future<(List<Object?>, String?)> streamed(
  Uint8List bytes,
  int chunk, {
  AvroLimits limits = const AvroLimits(),
  AvroCodec? codec,
}) async {
  final records = <Object?>[];
  try {
    final reader = await AvroFileStreamReader.open(
      chunked(bytes, chunk),
      limits: limits,
    );
    await reader.records(codec).forEach(records.add);
  } on AvroException catch (e) {
    return (records, describe(e));
  }
  return (records, null);
}

/// Expects the same records, deeply, and the same error.
void expectSame(
  (List<Object?>, String?) actual,
  (List<Object?>, String?) expected, [
  String? reason,
]) {
  expect(actual.$1, expected.$1, reason: reason);
  expect(actual.$2, expected.$2, reason: reason);
}

final _int = AvroCodec(writer: Schema.parse('"int"'));

const _compressions = ['null', 'deflate', 'snappy', 'bzip2', 'xz', 'zstandard'];

/// A file of three blocks of a record with a string, compressed with [compression].
Uint8List threeBlocks(String compression) {
  final codec = AvroCodec(
    writer: Schema.parse(
      '{"type": "record", "name": "R", "fields": ['
      '{"name": "n", "type": "int"}, {"name": "s", "type": "string"}]}',
    ),
  );
  final writer = AvroFileWriter(
    codec,
    compression: compression,
    syncMarker: Uint8List.fromList(List.generate(16, (i) => 0xa0 + i)),
  );
  for (var i = 0; i < 3; i++) {
    writer
      ..add({'n': i, 's': 'record $i'})
      ..add({'n': -i, 's': ''})
      ..flush();
  }
  return writer.close();
}

void main() {
  group("Apache Avro's weather files read as from memory", () {
    for (final name in [
      'apache/weather.avro',
      'apache/weather-deflate.avro',
      'apache/weather-snappy.avro',
      'apache/weather-zstd.avro',
      'compressions/weather-bzip2.avro',
      'compressions/weather-xz.avro',
      'compressions/weather-zstandard.avro',
      'apache/syncInMeta.avro',
    ]) {
      final bytes = File('test/data/$name').readAsBytesSync();
      for (final chunk in [1, 7, 4096, bytes.length]) {
        test('$name in chunks of $chunk bytes', () async {
          final expected = AvroFileReader(bytes);
          final reader = await AvroFileStreamReader.open(chunked(bytes, chunk));
          expect(reader.header.schemaJson, expected.header.schemaJson);
          expect(reader.header.compression, expected.header.compression);
          expect(reader.header.syncMarker, expected.header.syncMarker);
          expect(reader.header.metadata, expected.header.metadata);
          final records = await reader.records().toList();
          expect(records, isNotEmpty);
          expect(records, expected.records().toList());
        });
      }
    }
  });

  group('every compression', () {
    for (final compression in _compressions) {
      test('$compression: three blocks in chunks of 1 and 3 bytes', () async {
        final bytes = threeBlocks(compression);
        final expected = inMemory(bytes);
        expect(expected.$1, hasLength(6));
        expect(expected.$2, isNull);
        for (final chunk in [1, 3, bytes.length]) {
          expectSame(await streamed(bytes, chunk), expected);
        }
      });
    }
  });

  test('the blocks that arrived with the header are read', () async {
    final bytes = threeBlocks('null');
    final reader = await AvroFileStreamReader.open(Stream.value(bytes));
    expect(await reader.records().length, 6);
  });

  group('a damaged file fails as from memory', () {
    for (final compression in _compressions) {
      final bytes = threeBlocks(compression);
      test('$compression: cut off at every byte', () async {
        for (var length = 0; length < bytes.length; length++) {
          final cut = Uint8List.sublistView(bytes, 0, length);
          final expected = inMemory(cut);
          for (final chunk in [1, 3, bytes.length]) {
            expectSame(
              await streamed(cut, chunk),
              expected,
              'cut at $length, chunks of $chunk',
            );
          }
        }
      });
      test('$compression: with every byte changed', () async {
        for (var at = 0; at < bytes.length; at++) {
          final changed = Uint8List.fromList(bytes)..[at] ^= 0x55;
          final expected = inMemory(changed);
          for (final chunk in [1, 5]) {
            expectSame(
              await streamed(changed, chunk),
              expected,
              'changed at $at, chunks of $chunk',
            );
          }
        }
      });
    }

    test('errors far into a file give its offsets', () async {
      final codec = AvroCodec(writer: Schema.parse('"string"'));
      final writer = AvroFileWriter(codec, blockSize: 1000);
      for (var i = 0; i < 40; i++) {
        writer.add('$i ${'x' * 300}');
      }
      final bytes = writer.close();
      expect(bytes.length, greaterThan(3 * 4096));
      final last = bytes.length - 17;
      for (final at in [
        last, // the last sync marker
        last - 100, // a string of the last block
        last - 9000, // a block in the middle
      ]) {
        // An invalid UTF-8 byte in a string, a wrong sync marker byte.
        final changed = Uint8List.fromList(bytes)..[at] ^= 0xff;
        final cut = Uint8List.sublistView(bytes, 0, at);
        for (final damaged in [changed, cut]) {
          final expected = inMemory(damaged);
          expect(expected.$2, isNotNull);
          for (final chunk in [1, 333, 5000]) {
            expectSame(
              await streamed(damaged, chunk),
              expected,
              'damaged at $at, chunks of $chunk',
            );
          }
        }
      }
    });

    test('a record error carries the file offset of its block', () async {
      final bytes = file(
        schema: '"int"',
        blocks: [
          (2, [2, 4]),
          (1, [0xff]), // a truncated varint
        ],
      );
      final (records, error) = await streamed(bytes, 1);
      expect(records, [1, 2]);
      expect(error, contains('of the block at byte ${bytes.length - 16 - 3}'));
      expectSame((records, error), inMemory(bytes));
    });
  });

  group('open', () {
    test('rejects a stream that is not a container file', () async {
      final cancelled = Completer<void>();
      final source = StreamController<List<int>>(onCancel: cancelled.complete);
      final reader = AvroFileStreamReader.open(source.stream);
      source.add([0x4f, 0x62]);
      source.add([0x6b]);
      await expectLater(
        reader,
        throwsA(isA<DecodeException>().having((e) => e.offset, 'offset', 0)),
      );
      // Rejected at the third byte, without waiting for the stream to end.
      await cancelled.future;
    });

    test('rejects an unsupported compression', () async {
      final bytes = file(schema: '"int"', compression: 'lzo', blocks: []);
      await expectLater(
        AvroFileStreamReader.open(chunked(bytes, 2)),
        throwsA(
          isA<UnsupportedCompressionException>().having(
            (e) => e.compression,
            'compression',
            'lzo',
          ),
        ),
      );
    });

    test('passes an error of the stream on', () async {
      Stream<List<int>> failing() async* {
        yield [0x4f];
        throw const FileSystemException('gone');
      }

      await expectLater(
        AvroFileStreamReader.open(failing()),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('records', () {
    test('can be read only once', () async {
      final reader = await AvroFileStreamReader.open(
        Stream.value(threeBlocks('null')),
      );
      reader.records();
      expect(reader.records, throwsStateError);
    });

    test('a file without blocks has no records', () async {
      final bytes = file(schema: '"int"', blocks: []);
      final reader = await AvroFileStreamReader.open(chunked(bytes, 1));
      expect(await reader.records().toList(), isEmpty);
    });

    test('rejects a codec of another schema before the first record', () async {
      final bytes = file(
        schema: '"int"',
        blocks: [
          (1, [2]),
        ],
      );
      final reader = await AvroFileStreamReader.open(chunked(bytes, 3));
      final long = AvroCodec(writer: Schema.parse('"long"'));
      final (records, error) = await streamed(bytes, 3, codec: long);
      expect(records, isEmpty);
      expect(error, startsWith('DecodeException'));
      expectSame((records, error), inMemory(bytes, codec: long));
      expect(await reader.records(_int).toList(), [1]);
    });

    test(
      'decodes as a reader schema with a codec of the file schema',
      () async {
        final bytes = file(
          schema: '"int"',
          blocks: [
            (2, [2, 4]),
          ],
        );
        final reader = await AvroFileStreamReader.open(chunked(bytes, 1));
        final codec = AvroCodec(
          writer: Schema.parse('"int"'),
          reader: Schema.parse('"double"'),
        );
        expect(await reader.records(codec).toList(), [1.0, 2.0]);
      },
    );

    test(
      'pauses the stream between blocks it has not been asked for',
      () async {
        final bytes = threeBlocks('null');
        var pulled = 0;
        Stream<List<int>> counting() async* {
          for (var i = 0; i < bytes.length; i++) {
            pulled = i + 1;
            yield [bytes[i]];
          }
        }

        final reader = await AvroFileStreamReader.open(counting());
        final records = StreamIterator(reader.records());
        expect(await records.moveNext(), isTrue);
        // Only the first block, not the rest of the file.
        expect(pulled, lessThan(bytes.length - 20));
        await records.cancel();
      },
    );
  });

  group('cancel', () {
    test('cancels the source, and records cannot be read after', () async {
      final cancelled = Completer<void>();
      final source = StreamController<List<int>>(onCancel: cancelled.complete);
      source.add(threeBlocks('null'));
      final reader = await AvroFileStreamReader.open(source.stream);
      await reader.cancel();
      await cancelled.future;
      expect(reader.records, throwsStateError);
      await reader.cancel();
    });

    test('ends a running stream of records without an error', () async {
      final bytes = threeBlocks('null');
      // The whole file, but the stream does not end.
      final source = StreamController<List<int>>()..add(bytes);
      final reader = await AvroFileStreamReader.open(source.stream);
      final records = <Object?>[];
      final done = Completer<void>();
      reader.records().listen(
        (r) {
          records.add(r);
          if (records.length == 2) reader.cancel();
        },
        onError: done.completeError,
        onDone: done.complete,
      );
      await done.future;
      expect(records, hasLength(2));
    });

    test('ends a stream of records that waits for input', () async {
      final bytes = threeBlocks('null');
      // All but the end of the last block, and the stream does not end.
      final source = StreamController<List<int>>()
        ..add(Uint8List.sublistView(bytes, 0, bytes.length - 5));
      final reader = await AvroFileStreamReader.open(source.stream);
      final records = reader.records().toList();
      await Future<void>.delayed(Duration.zero);
      await reader.cancel();
      expect(await records, hasLength(4));
    });
  });

  group('limits', () {
    test('a header longer than maxBlockBytes is rejected', () async {
      final writer = AvroFileWriter(_int, metadata: {'x': Uint8List(2000)});
      final bytes = writer.close();
      const limits = AvroLimits(maxBlockBytes: 1000);
      for (final chunk in [1, 100, bytes.length]) {
        await expectLater(
          AvroFileStreamReader.open(chunked(bytes, chunk), limits: limits),
          throwsA(
            isA<LimitExceededException>().having(
              (e) => e.limit,
              'limit',
              'maxBlockBytes',
            ),
          ),
        );
      }
      final reader = await AvroFileStreamReader.open(
        chunked(bytes, 100),
        limits: const AvroLimits(maxBlockBytes: 3000),
      );
      expect(reader.header.metadata['x'], hasLength(2000));
    });

    test('a huge metadata value fails before it is read', () async {
      Stream<List<int>> source() async* {
        yield [0x4f, 0x62, 0x6a, 1, ..._int.encode(1), ..._int.encode(1)];
        yield [0x78, ..._int.encode(100 * 1024 * 1024)];
        throw StateError('read beyond the length of the value');
      }

      await expectLater(
        AvroFileStreamReader.open(source()),
        throwsA(
          isA<LimitExceededException>().having(
            (e) => e.limit,
            'limit',
            'maxBlockBytes',
          ),
        ),
      );
    });

    test('a huge declared block fails before its data is read', () async {
      final header = file(schema: '"bytes"', blocks: []);
      final prefix = [
        ...header,
        ..._int.encode(1),
        ..._int.encode(100 * 1024 * 1024),
      ];
      Stream<List<int>> source() async* {
        yield prefix;
        throw StateError('read beyond the prefix of the block');
      }

      final reader = await AvroFileStreamReader.open(source());
      await expectLater(
        reader.records().toList(),
        throwsA(
          isA<LimitExceededException>()
              .having((e) => e.limit, 'limit', 'maxBlockBytes')
              .having((e) => e.message, 'message', contains('compressed')),
        ),
      );
    });

    test('maxBlockBytes bounds the compressed size of a block', () async {
      // A deflate block whose compressed size, not its records, is over the limit.
      final data = deflate(List.generate(300, (i) => i * 7919 % 256));
      final bytes = file(
        schema: '"null"',
        compression: 'deflate',
        blocks: [(1, data)],
      );
      final limits = AvroLimits(maxBlockBytes: data.length - 1);
      final (_, error) = await streamed(bytes, 7, limits: limits);
      expect(error, contains('maxBlockBytes'));
      expect(error, contains('compressed'));
    });

    test('a deflate bomb stops at the block limit as from memory', () async {
      final bytes = file(
        schema: '"null"',
        compression: 'deflate',
        blocks: [(1, deflate(Uint8List(4 * 1024 * 1024)))],
      );
      const limits = AvroLimits(maxBlockBytes: 1024 * 1024);
      final expected = inMemory(bytes, limits: limits);
      expect(expected.$2, contains('maxBlockBytes'));
      expectSame(await streamed(bytes, 4096, limits: limits), expected);
    });

    test('the total limit applies across blocks as from memory', () async {
      final bytes = threeBlocks('deflate');
      const limits = AvroLimits(maxTotalBytes: 30);
      final expected = inMemory(bytes, limits: limits);
      expect(expected.$2, contains('maxTotalBytes'));
      expectSame(await streamed(bytes, 1, limits: limits), expected);
    });

    test('zero-size records over maxZeroSizeItems as from memory', () async {
      final bytes = file(schema: '"null"', blocks: [(5000, <int>[])]);
      const limits = AvroLimits(maxZeroSizeItems: 4096);
      final expected = inMemory(bytes, limits: limits);
      expect(expected.$2, contains('maxZeroSizeItems'));
      expectSame(await streamed(bytes, 2, limits: limits), expected);
    });
  });
}
