// The Dart side of the interop job (ADR 5): writes and reads the cases of cases.json with
// this package.
//
//   dart run tool/interop/interop.dart write DIR   writes dart-<case>-<compression>.avro
//                                                  and dart-<case>-<n>.bin
//   dart run tool/interop/interop.dart read DIR    reads the py-* files and compares them
//
// Run from the repository root.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:avro/avro.dart';

Schema loadSchema(Object? spec) => switch (spec) {
  final String s when s.startsWith('@') => Schema.parse(
    File(s.substring(1)).readAsStringSync(),
  ),
  _ => Schema.parse(jsonEncode(spec)),
};

String branchNameOf(Schema s) => s is NamedSchema ? s.fullName : s.type;

Uint8List fromHex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String toHex(Uint8List bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

AvroDecimal parseDecimal(String text, int scale) {
  final negative = text.startsWith('-');
  final digits = (negative ? text.substring(1) : text).split('.');
  final fraction = digits.length > 1 ? digits[1] : '';
  final unscaled = BigInt.parse('${digits[0]}${fraction.padRight(scale, '0')}');
  return AvroDecimal(negative ? -unscaled : unscaled, scale);
}

int scaleOf(Schema s) =>
    ((s.json! as Map<String, Object?>)['scale'] ?? 0) as int;

/// This package's value of the interop JSON value [v] of [s].
Object? fromJson(Schema s, Object? v) {
  switch (s.logicalType) {
    case 'date' when s.type == 'int':
      return AvroDate.fromEpochDays(v! as int);
    case 'time-millis' when s.type == 'int':
      return Duration(milliseconds: v! as int);
    case 'time-micros' when s.type == 'long':
      return Duration(microseconds: v! as int);
    case 'timestamp-millis' when s.type == 'long':
      return DateTime.fromMillisecondsSinceEpoch(v! as int, isUtc: true);
    case 'timestamp-micros' when s.type == 'long':
      return DateTime.fromMicrosecondsSinceEpoch(v! as int, isUtc: true);
    case 'decimal':
      return parseDecimal(v! as String, scaleOf(s));
  }
  return switch (s) {
    PrimitiveSchema(type: 'bytes') || FixedSchema() => fromHex(v! as String),
    PrimitiveSchema(type: 'float' || 'double') => (v! as num).toDouble(),
    ArraySchema(:final items) => [
      for (final x in v! as List<Object?>) fromJson(items, x),
    ],
    MapSchema(:final values) => {
      for (final e in (v! as Map<String, Object?>).entries)
        e.key: fromJson(values, e.value),
    },
    RecordSchema(:final fields) => {
      for (final f in fields)
        f.name: fromJson(f.schema, (v! as Map<String, Object?>)[f.name]),
    },
    UnionSchema(:final branches) => switch (v) {
      null => null,
      final Map<String, Object?> tagged => () {
        final MapEntry(:key, :value) = tagged.entries.single;
        final branch = branches.firstWhere((b) => branchNameOf(b) == key);
        return Branch(key, fromJson(branch, value));
      }(),
      _ => throw FormatException(
        'a union value must be null or {branch: value}: $v',
      ),
    },
    _ => v,
  };
}

/// Whether the decoded value [v] belongs to the union branch [s].
bool fits(Schema s, Object? v) => switch (s) {
  PrimitiveSchema(type: 'null') => v == null,
  PrimitiveSchema(type: 'boolean') => v is bool,
  PrimitiveSchema(type: 'int' || 'long') =>
    v is int || v is AvroDate || v is Duration || v is DateTime,
  PrimitiveSchema(type: 'float' || 'double') => v is double,
  PrimitiveSchema(type: 'bytes') ||
  FixedSchema() => v is Uint8List || v is AvroDecimal,
  PrimitiveSchema(type: 'string') => v is String,
  EnumSchema(:final symbols) => v is String && symbols.contains(v),
  ArraySchema() => v is List<Object?>,
  RecordSchema(:final fields) =>
    v is Map<String, Object?> &&
        v.length == fields.length &&
        fields.every((f) => v.containsKey(f.name)),
  MapSchema() => v is Map<String, Object?>,
  _ => false,
};

/// The interop JSON value of the decoded value [v] of [s].
Object? toJson(Schema s, Object? v) {
  if (s is UnionSchema) {
    if (v == null) return null;
    final b = s.branches.firstWhere((b) => b.type != 'null' && fits(b, v));
    return {branchNameOf(b): toJson(b, v)};
  }
  switch (v) {
    case final AvroDate d:
      return d.epochDays;
    case final Duration d:
      return s.logicalType == 'time-millis'
          ? d.inMilliseconds
          : d.inMicroseconds;
    case final DateTime t:
      return s.logicalType == 'timestamp-millis'
          ? t.millisecondsSinceEpoch
          : t.microsecondsSinceEpoch;
    case final AvroDecimal d:
      return d.toString();
  }
  return switch (s) {
    PrimitiveSchema(type: 'bytes') || FixedSchema() => toHex(v! as Uint8List),
    ArraySchema(:final items) => [
      for (final x in v! as List<Object?>) toJson(items, x),
    ],
    MapSchema(:final values) => {
      for (final e in (v! as Map<String, Object?>).entries)
        e.key: toJson(values, e.value),
    },
    RecordSchema(:final fields) => {
      for (final f in fields)
        f.name: toJson(f.schema, (v! as Map<String, Object?>)[f.name]),
    },
    _ => v,
  };
}

List<Map<String, Object?>> cases() =>
    ((jsonDecode(File('tool/interop/cases.json').readAsStringSync())
                as Map<String, Object?>)['cases']!
            as List<Object?>)
        .cast<Map<String, Object?>>();

void write(Directory out) {
  out.createSync(recursive: true);
  for (final c in cases()) {
    final codec = AvroCodec(writer: loadSchema(c['writer']));
    final values = [
      for (final v in c['values']! as List<Object?>) fromJson(codec.writer, v),
    ];
    for (final compression in ['null', 'deflate']) {
      final writer = AvroFileWriter(codec, compression: compression);
      values.forEach(writer.add);
      File('${out.path}/dart-${c['name']}-$compression.avro')
          .writeAsBytesSync(writer.close());
    }
    for (var i = 0; i < values.length; i++) {
      File('${out.path}/dart-${c['name']}-$i.bin')
          .writeAsBytesSync(codec.encode(values[i]));
    }
  }
}

int read(Directory dir) {
  var failures = 0;
  const equality = DeepJson();
  for (final c in cases()) {
    final writer = loadSchema(c['writer']);
    final reader = c.containsKey('reader') ? loadSchema(c['reader']) : writer;
    final codec = AvroCodec(writer: writer, reader: reader);
    final expected = (c['expected'] ?? c['values'])! as List<Object?>;
    final got = <String, List<Object?>>{};
    for (final compression in ['null', 'deflate']) {
      final file = AvroFileReader(
        File('${dir.path}/py-${c['name']}-$compression.avro').readAsBytesSync(),
      );
      if (file.header.compression != compression) {
        throw StateError(
          'expected $compression, the file says ${file.header.compression}',
        );
      }
      got[compression] = [
        for (final v in file.records(codec)) toJson(reader, v),
      ];
    }
    got['binary'] = [
      for (var i = 0; i < expected.length; i++)
        toJson(
          reader,
          codec.decode(
            File('${dir.path}/py-${c['name']}-$i.bin').readAsBytesSync(),
          ),
        ),
    ];
    for (final MapEntry(:key, :value) in got.entries) {
      if (equality.equals(value, expected)) {
        stdout.writeln('ok   ${c['name']} ($key)');
      } else {
        failures++;
        stdout.writeln(
          'FAIL ${c['name']} ($key): ${jsonEncode(value)} != ${jsonEncode(expected)}',
        );
      }
    }
  }
  return failures;
}

/// Equality of JSON values, with integral doubles equal to their integers.
final class DeepJson {
  const DeepJson();

  bool equals(Object? a, Object? b) => switch ((a, b)) {
    (final num x, final num y) => x == y,
    (final List<Object?> x, final List<Object?> y) =>
      x.length == y.length &&
          [for (var i = 0; i < x.length; i++) i]
              .every((i) => equals(x[i], y[i])),
    (final Map<String, Object?> x, final Map<String, Object?> y) =>
      x.length == y.length &&
          x.keys.every((k) => y.containsKey(k) && equals(x[k], y[k])),
    _ => a == b,
  };
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: interop.dart write|read DIR');
    exit(2);
  }
  final dir = Directory(args[1]);
  switch (args[0]) {
    case 'write':
      write(dir);
    case 'read':
      exit(read(dir) == 0 ? 0 : 1);
    default:
      stderr.writeln('unknown command ${args[0]}');
      exit(2);
  }
}
