// The benchmark suite of the codec (avro-1036, ADR 11).
//
//   dart compile exe tool/bench/bench.dart -o bench
//   ./bench [--json results.json]
//
// Run from the repository root, compiled: the numbers are for the Dart AOT build. Every case
// warms up for 100 ms and is then timed for at least 2 s by benchmark_harness, one operation
// per measured call. tool/bench/java/ and tool/bench/fastavro_bench.py run the same cases on
// the same schemas and values; docs/benchmarks.md has the results and the rules the values are
// built by.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:benchmark_harness/benchmark_harness.dart';

import '../../test/data/axt/axt_types.g.dart';

/// The container file compressions measured.
const compressions = ['null', 'deflate', 'snappy', 'zstandard'];

/// The number of records in a container file.
const fileRecords = 1000;

void main(List<String> args) {
  final jsonAt = args.indexOf('--json');
  final jsonFile = jsonAt >= 0 && jsonAt + 1 < args.length
      ? args[jsonAt + 1]
      : null;
  if (jsonAt >= 0 && jsonFile == null) {
    stderr.writeln('usage: bench [--json <file>]');
    exitCode = 64;
    return;
  }

  final results = <Map<String, Object?>>[];
  stdout.writeln(
    '${'case'.padRight(26)} ${'ops/s'.padLeft(12)} ${'µs/op'.padLeft(12)} '
    '${'bytes'.padLeft(9)}',
  );
  for (final c in cases()) {
    final micros = _Bench(c.name, c.op).measure();
    final row = {
      'case': c.name,
      'opsPerSecond': 1e6 / micros,
      'microsPerOp': micros,
      'bytes': c.bytes,
    };
    results.add(row);
    stdout.writeln(
      '${c.name.padRight(26)} ${(1e6 / micros).toStringAsFixed(0).padLeft(12)} '
      '${micros.toStringAsFixed(3).padLeft(12)} ${'${c.bytes}'.padLeft(9)}',
    );
  }
  if (jsonFile != null) {
    File(jsonFile).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'implementation': 'dart',
        'dart': Platform.version,
        'results': results,
        'checksum': _sink,
      }),
    );
  }
}

/// One measured operation, with the size of the encoding it writes or reads.
final class Case {
  Case(this.name, this.bytes, this.op);

  final String name;
  final int bytes;
  final void Function() op;
}

/// Where results go so that no operation can be optimised away.
int _sink = 0;

final class _Bench extends BenchmarkBase {
  _Bench(super.name, this.op);

  final void Function() op;

  @override
  void run() => op();

  // One operation per measured call, so that the score is µs per operation.
  @override
  void exercise() => run();
}

Schema schemaFile(String path) => Schema.parse(File(path).readAsStringSync());

/// Every case, in the order of the report.
List<Case> cases() {
  final interop = schemaFile('test/data/apache/interop.avsc');
  final envelope = schemaFile('test/data/axt/types/axt/Envelope.avsc');
  final wide = schemaFile('tool/bench/schemas/wide.avsc');
  final longs = schemaFile('tool/bench/schemas/longs.avsc');

  final envelopeValue = AvroCodec(writer: envelope)
      .decodeSingleObject(hexFile('test/data/axt/memo-message.hex'));

  final workloads = {
    'interop': (interop, 'interop-reader.avsc', interopValue()),
    'envelope': (envelope, 'envelope-reader.avsc', envelopeValue),
    'wide': (wide, 'wide-reader.avsc', wideValue(0)),
    'longs': (longs, 'longs-reader.avsc', longsValue()),
  };

  final list = <Case>[];
  for (final MapEntry(key: name, value: (schema, readerFile, value))
      in workloads.entries) {
    final codec = AvroCodec(writer: schema);
    final resolving = AvroCodec(
      writer: schema,
      reader: schemaFile('tool/bench/schemas/$readerFile'),
    );
    final bytes = codec.encode(value);
    list
      ..add(
        Case('$name/encode', bytes.length, () {
          _sink += codec.encode(value).length;
        }),
      )
      ..add(
        Case('$name/decode', bytes.length, () {
          if (codec.decode(bytes) != null) _sink++;
        }),
      )
      ..add(
        Case('$name/resolve', bytes.length, () {
          if (resolving.decode(bytes) != null) _sink++;
        }),
      );
  }

  for (final (name, schema, value) in [
    ('interop', interop, interopValue()),
    ('wide', wide, wideValue(0)),
  ]) {
    final codec = AvroCodec(writer: schema);
    final json = codec.encodeJson(value);
    final size = utf8.encode(json).length;
    list
      ..add(
        Case('json/$name/encode', size, () {
          _sink += codec.encodeJson(value).length;
        }),
      )
      ..add(
        Case('json/$name/decode', size, () {
          if (codec.decodeJson(json) != null) _sink++;
        }),
      );
  }

  final records = [for (var r = 0; r < fileRecords; r++) wideValue(r)];
  final wideCodec = AvroCodec(writer: wide);
  final sync = Uint8List.fromList(List.generate(16, (i) => i));
  for (final compression in compressions) {
    Uint8List write() {
      final writer = AvroFileWriter(
        wideCodec,
        compression: compression,
        syncMarker: sync,
      );
      records.forEach(writer.add);
      return writer.close();
    }

    final file = write();
    list
      ..add(
        Case('file/$compression/write', file.length, () {
          _sink += write().length;
        }),
      )
      ..add(
        Case('file/$compression/read', file.length, () {
          _sink += AvroFileReader(file).records().length;
        }),
      );
  }

  final typed = TypedCodec(AxtEnvelope.avroType);
  final message = typed.avro.encode(envelopeValue);
  final typedValue = typed.decode(message);
  list
    ..add(
      Case('typed/envelope/encode', message.length, () {
        _sink += typed.encode(typedValue).length;
      }),
    )
    ..add(
      Case('typed/envelope/decode', message.length, () {
        _sink += typed.decode(message).format;
      }),
    );
  return list;
}

Uint8List hexFile(String path) {
  final hex = File(path).readAsStringSync().trim();
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// The value of interop.avsc, the same on every side.
Map<String, Object?> interopValue() => {
  'intField': 12,
  'longField': 15234324,
  'stringField': 'hey',
  'boolField': false,
  'floatField': 1234.0,
  'doubleField': -1234.0,
  'bytesField': Uint8List.fromList(utf8.encode('12312adf')),
  'nullField': null,
  'arrayField': <Object?>[5.0, 0.0, 12.0],
  'mapField': <String, Object?>{
    'a': <String, Object?>{'label': 'a'},
  },
  'unionField': 12.0,
  'enumField': 'C',
  'fixedField': Uint8List.fromList(List.generate(16, (i) => i)),
  'recordField': <String, Object?>{
    'label': 'root',
    'children': <Object?>[
      <String, Object?>{'label': 'child', 'children': <Object?>[]},
    ],
  },
};

const _colors = ['RED', 'GREEN', 'BLUE', 'BLACK'];

/// Record [r] of wide.avsc: field f<i> of kind i % 10, from n = i + r.
Map<String, Object?> wideValue(int r) => {
  for (var i = 0; i < 50; i++) 'f$i': _wideField(i % 10, i + r),
};

Object? _wideField(int kind, int n) => switch (kind) {
  0 => n * 1000 - 20000,
  1 => n * 1000000007,
  2 => 'value-$n',
  3 => n * 1.5,
  4 => n.isEven,
  5 => n + 0.25,
  6 => Uint8List.fromList([for (var k = 0; k < 8; k++) (n + k) & 0xff]),
  7 => (n ~/ 10).isEven ? 'opt-$n' : null,
  8 => (n ~/ 10).isEven ? null : n * 31,
  _ => _colors[(n ~/ 10) % 4],
};

/// The 10,000 longs of longs.avsc.
List<Object?> longsValue() => [
  for (var j = 0; j < 10000; j++) (j * 2654435761) % (1 << 40) - (1 << 39),
];
