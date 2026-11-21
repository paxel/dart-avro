import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

/// A sink that keeps what is written to it, as it is written.
final class Collected {
  Collected() {
    controller.stream.listen(bytes.add);
  }

  final controller = StreamController<List<int>>(sync: true);
  final bytes = BytesBuilder();

  StreamSink<List<int>> get sink => controller.sink;
}

final _codec = AvroCodec(
  writer: Schema.parse(
    '{"type": "record", "name": "R", "fields": ['
    '{"name": "n", "type": "long"}, {"name": "s", "type": "string"}]}',
  ),
);

final _sync = Uint8List.fromList(List.generate(16, (i) => 0x30 + i));

const _compressions = ['null', 'deflate', 'snappy', 'bzip2', 'xz', 'zstandard'];

/// Runs [steps] on an in-memory and a stream writer made alike; returns both files.
Future<(Uint8List, Uint8List)> both(
  String compression,
  void Function(void Function(Object?) add, void Function() flush) steps, {
  Map<String, Uint8List> metadata = const {},
  String? schemaJson,
  int blockSize = 64 * 1024,
}) async {
  final memory = AvroFileWriter(
    _codec,
    compression: compression,
    metadata: metadata,
    syncMarker: _sync,
    schemaJson: schemaJson,
    blockSize: blockSize,
  );
  final out = Collected();
  final stream = AvroFileStreamWriter(
    _codec,
    out.sink,
    compression: compression,
    metadata: metadata,
    syncMarker: _sync,
    schemaJson: schemaJson,
    blockSize: blockSize,
  );
  steps(memory.add, memory.flush);
  steps(stream.add, stream.flush);
  await stream.close();
  return (out.bytes.takeBytes(), memory.close());
}

void main() {
  group('byte for byte what AvroFileWriter writes', () {
    for (final compression in _compressions) {
      test('$compression, with flushes and full blocks', () async {
        final (streamed, memory) = await both(
          compression,
          (add, flush) {
            for (var i = 0; i < 50; i++) {
              add({'n': i * 1000003, 's': 'record $i ' * (i % 7)});
              if (i % 9 == 0) flush();
            }
            flush();
            flush();
          },
          metadata: {
            'x.first': Uint8List.fromList([1, 2]),
            'x.second': Uint8List(0),
          },
          schemaJson:
              '{"name": "R", "type": "record", "fields": ['
              '{"type": "long", "name": "n"}, {"type": "string", "name": "s"}]}',
          blockSize: 200,
        );
        expect(streamed, memory);
        final reader = await AvroFileStreamReader.open(Stream.value(streamed));
        expect(await reader.records().length, 50);
      });

      test('$compression, without records', () async {
        final (streamed, memory) = await both(compression, (add, flush) {});
        expect(streamed, memory);
      });
    }
  });

  test('the header is written at once and each block as it ends', () async {
    final out = Collected();
    final writer = AvroFileStreamWriter(
      _codec,
      out.sink,
      syncMarker: _sync,
      blockSize: 10,
    );
    final header = AvroFileWriter(_codec, syncMarker: _sync).close();
    expect(out.bytes.toBytes(), header);
    writer.add({'n': 1, 's': ''});
    expect(out.bytes.length, header.length);
    writer.add({'n': 2, 's': 'long enough'});
    expect(out.bytes.length, greaterThan(header.length));
    final written = out.bytes.length;
    writer.add({'n': 3, 's': ''});
    expect(out.bytes.length, written);
    writer.flush();
    expect(out.bytes.length, greaterThan(written));
    await writer.close();
    final reader = AvroFileReader(out.bytes.takeBytes());
    expect(reader.records().map((r) => (r! as Map)['n']), [1, 2, 3]);
  });

  test('close completes when the sink is closed', () async {
    final out = Collected();
    final writer = AvroFileStreamWriter(_codec, out.sink);
    await writer.close();
    expect(out.controller.isClosed, isTrue);
  });

  test('a random sync marker by default', () async {
    final a = AvroFileStreamWriter(_codec, Collected().sink);
    final b = AvroFileStreamWriter(_codec, Collected().sink);
    expect(a.syncMarker, hasLength(16));
    expect(a.syncMarker, isNot(b.syncMarker));
  });

  group('rejected, with nothing written', () {
    void rejects(
      Matcher error, {
      String compression = 'null',
      Map<String, Uint8List> metadata = const {},
      Uint8List? syncMarker,
      String? schemaJson,
    }) {
      final out = Collected();
      expect(
        () => AvroFileStreamWriter(
          _codec,
          out.sink,
          compression: compression,
          metadata: metadata,
          syncMarker: syncMarker,
          schemaJson: schemaJson,
        ),
        throwsA(error),
      );
      expect(out.bytes.length, 0);
    }

    test('a reserved metadata key', () {
      rejects(
        isArgumentError,
        metadata: {'avro.x': Uint8List.fromList(utf8.encode('y'))},
      );
    });

    test('another compression', () {
      rejects(isA<UnsupportedCompressionException>(), compression: 'lzo');
    });

    test('a schema text of another schema', () {
      rejects(isArgumentError, schemaJson: '"long"');
    });

    test('a sync marker of another size', () {
      rejects(isArgumentError, syncMarker: Uint8List(15));
    });
  });

  test('a record that does not fit leaves the output unchanged', () async {
    final (streamed, memory) = await both('deflate', (add, flush) {
      add({'n': 1, 's': 'a'});
      expect(
        () => add({'n': 'two', 's': 'b'}),
        throwsA(isA<EncodeException>()),
      );
      add({'n': 3, 's': 'c'});
    });
    expect(streamed, memory);
    expect(AvroFileReader(streamed).records(), hasLength(2));
  });

  test('add, flush and close after close throw StateError', () async {
    final writer = AvroFileStreamWriter(_codec, Collected().sink);
    await writer.close();
    expect(() => writer.add({'n': 1, 's': ''}), throwsStateError);
    expect(writer.flush, throwsStateError);
    expect(writer.close, throwsStateError);
  });
}
