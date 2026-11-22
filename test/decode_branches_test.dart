@Tags(['web'])
library;

import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

Schema s(String json) => Schema.parse(json);

/// [v] with every [Branch] turned into `{'branch': name, 'value': value}`, so that the deep
/// equality of `equals` reaches the values inside, which `Branch.==` compares with `==`.
Object? shape(Object? v) => switch (v) {
  Branch(:final name, :final value) => {'branch': name, 'value': shape(value)},
  final Uint8List b => b,
  final List<Object?> l => [for (final e in l) shape(e)],
  final Map<String, Object?> m => {
    for (final e in m.entries) e.key: shape(e.value),
  },
  _ => v,
};

Map<String, Object?> b(String name, Object? value) => {
  'branch': name,
  'value': value,
};

const pair = '''
[
  {"type": "record", "name": "A", "namespace": "ns", "fields": [{"name": "x", "type": "int"}]},
  {"type": "record", "name": "B", "namespace": "ns", "fields": [{"name": "x", "type": "int"}]}
]''';

void main() {
  group('decodeBranches', () {
    test('is off by default: unions decode plain', () {
      final codec = AvroCodec(writer: s('["int", "string"]'));
      expect(codec.decodeBranches, isFalse);
      expect(codec.decode(codec.encode('hi')), 'hi');
    });

    test('decodes a union of two or more non-null branches into a Branch', () {
      final codec = AvroCodec(
        writer: s('["int", "string", "null"]'),
        decodeBranches: true,
      );
      expect(codec.decode(codec.encode(7)), const Branch('int', 7));
      expect(codec.decode(codec.encode('hi')), const Branch('string', 'hi'));
    });

    test('keeps null and the value of ["null", X] plain, in either order', () {
      for (final union in ['["null", "int"]', '["int", "null"]']) {
        final codec = AvroCodec(writer: s(union), decodeBranches: true);
        expect(codec.decode(codec.encode(7)), 7, reason: union);
        expect(codec.decode(codec.encode(null)), isNull, reason: union);
      }
      final wide = AvroCodec(
        writer: s('["null", "int", "string"]'),
        decodeBranches: true,
      );
      expect(wide.decode(wide.encode(null)), isNull);
    });

    test('keeps a union of one branch plain', () {
      final codec = AvroCodec(writer: s('["int"]'), decodeBranches: true);
      expect(codec.decode(codec.encode(7)), 7);
    });

    test(
      'names a named branch by its full name and tells two records apart',
      () {
        final codec = AvroCodec(writer: s(pair), decodeBranches: true);
        final bytes = codec.encode(
          const Branch('ns.B', <String, Object?>{'x': 1}),
        );
        expect(shape(codec.decode(bytes)), b('ns.B', {'x': 1}));
        expect(codec.encode(codec.decode(bytes)), bytes);
      },
    );

    test('decodes unions nested in arrays, maps and records', () {
      final schema = s('''
{"type": "record", "name": "R", "fields": [
  {"name": "list", "type": {"type": "array", "items": ["int", "string"]}},
  {"name": "map", "type": {"type": "map", "values": ["long", "boolean", "null"]}},
  {"name": "inner", "type": ["null", "R"]},
  {"name": "deep", "type": ["string", {"type": "array", "items": ["int", "double"]}]}
]}''');
      final codec = AvroCodec(writer: schema, decodeBranches: true);
      final value = <String, Object?>{
        'list': [1, 'a'],
        'map': {'t': true, 'n': null, 'l': 5},
        'inner': {
          'list': <Object?>[],
          'map': <String, Object?>{},
          'inner': null,
          'deep': 'leaf',
        },
        'deep': [1, 2.5],
      };
      final bytes = codec.encode(value);
      final decoded = codec.decode(bytes);
      expect(shape(decoded), {
        'list': [b('int', 1), b('string', 'a')],
        'map': {'t': b('boolean', true), 'n': null, 'l': b('long', 5)},
        'inner': {
          'list': <Object?>[],
          'map': <String, Object?>{},
          'inner': null,
          'deep': b('string', 'leaf'),
        },
        'deep': b('array', [b('int', 1), b('double', 2.5)]),
      });
      expect(codec.encode(decoded), bytes);
    });

    test(
      're-encodes branches of logical types, fixed, enums, bytes and maps',
      () {
        final schema = s('''
[
  {"type": "int", "logicalType": "date"},
  {"type": "long", "logicalType": "timestamp-millis"},
  {"type": "fixed", "name": "F", "size": 2},
  {"type": "enum", "name": "E", "symbols": ["X"]},
  "bytes",
  {"type": "map", "values": "int"}
]''');
        final codec = AvroCodec(writer: schema, decodeBranches: true);
        final values = <Branch>[
          Branch('int', AvroDate(2026, 11, 21)),
          Branch('long', DateTime.utc(2026, 11, 21, 12)),
          Branch('F', Uint8List.fromList([1, 2])),
          const Branch('E', 'X'),
          Branch('bytes', Uint8List.fromList([3])),
          const Branch('map', <String, Object?>{'k': 1}),
        ];
        for (final v in values) {
          final bytes = codec.encode(v);
          final decoded = codec.decode(bytes);
          expect(decoded, isA<Branch>().having((d) => d.name, 'name', v.name));
          expect(shape(decoded), shape(v));
          expect(codec.encode(decoded), bytes, reason: v.name);
        }
      },
    );

    test('applies to decodeSingleObject', () {
      final codec = AvroCodec(writer: s(pair), decodeBranches: true);
      final bytes = codec.encodeSingleObject(
        const Branch('ns.A', <String, Object?>{'x': 3}),
      );
      expect(shape(codec.decodeSingleObject(bytes)), b('ns.A', {'x': 3}));
    });

    test('applies to decodeJson, with the full name for a simple one', () {
      final codec = AvroCodec(writer: s(pair), decodeBranches: true);
      expect(shape(codec.decodeJson('{"B": {"x": 4}}')), b('ns.B', {'x': 4}));
      expect(
        shape(codec.decodeJson('{"ns.A": {"x": 5}}')),
        b('ns.A', {'x': 5}),
      );
      final optional = AvroCodec(
        writer: s('["null", "string"]'),
        decodeBranches: true,
      );
      expect(optional.decodeJson('{"string": "s"}'), 's');
    });

    test('applies to the records of a container file', () {
      final schema = s('["int", "string"]');
      final writer = AvroFileWriter(AvroCodec(writer: schema))
        ..add(1)
        ..add('two');
      final reader = AvroFileReader(writer.close());
      expect(reader.records().toList(), [1, 'two']);
      expect(
        reader
            .records(AvroCodec(writer: schema, decodeBranches: true))
            .toList(),
        [const Branch('int', 1), const Branch('string', 'two')],
      );
    });
  });

  group('decodeBranches under resolution', () {
    Object? readAs(String writer, String reader, Object? value) {
      final w = s(writer);
      final bytes = AvroCodec(writer: w).encode(value);
      return AvroCodec(
        writer: w,
        reader: s(reader),
        decodeBranches: true,
      ).decode(bytes);
    }

    test('an equal but separate reader gives what the writer alone gives', () {
      const schema = '''
{"type": "record", "name": "R", "fields": [
  {"name": "u", "type": ["int", "string"]},
  {"name": "a", "type": {"type": "array", "items": ["null", "long", "R"]}}
]}''';
      final value = <String, Object?>{
        'u': 'x',
        'a': [
          null,
          9,
          {'u': 1, 'a': <Object?>[]},
        ],
      };
      final w = s(schema);
      final bytes = AvroCodec(writer: w).encode(value);
      final direct = AvroCodec(writer: w, decodeBranches: true).decode(bytes);
      expect(shape(readAs(schema, schema, value)), shape(direct));
      expect(shape(direct), {
        'u': b('string', 'x'),
        'a': [
          null,
          b('long', 9),
          b('R', {'u': b('int', 1), 'a': <Object?>[]}),
        ],
      });
    });

    test('names the reader branch: a plain writer read as a reader union', () {
      expect(readAs('"int"', '["string", "long"]', 3), const Branch('long', 3));
      expect(readAs('"int"', '["null", "long"]', 3), 3);
    });

    test('names the reader branch: a writer union read as a reader union', () {
      const writer = '["int", "string"]';
      const reader = '["string", "null", "double"]';
      expect(readAs(writer, reader, 2), const Branch('double', 2.0));
      expect(readAs(writer, reader, 'z'), const Branch('string', 'z'));
    });

    test('names the reader branch of a record found by alias', () {
      const writer = '''
["int", {"type": "record", "name": "Old", "namespace": "w", "fields": [{"name": "x", "type": "int"}]}]''';
      const reader = '''
["int", {"type": "record", "name": "New", "namespace": "r", "aliases": ["w.Old"],
  "fields": [{"name": "x", "type": "int"}]}]''';
      expect(
        shape(readAs(writer, reader, const Branch('w.Old', {'x': 1}))),
        b('r.New', {'x': 1}),
      );
    });

    test('keeps a writer union read as a plain reader plain', () {
      expect(readAs('["int", "string"]', '"string"', 'only'), 'only');
    });

    test(
      'decodes a reader default of a union as a Branch, nested ones too',
      () {
        const writer = '{"type": "record", "name": "R", "fields": []}';
        const reader = '''
{"type": "record", "name": "R", "fields": [
  {"name": "u", "type": ["string", "int"], "default": "d"},
  {"name": "n", "type": ["null", "int"], "default": null},
  {"name": "l", "type": {"type": "array", "items": ["int", "string"]}, "default": [1]},
  {"name": "r", "type": {"type": "record", "name": "S", "fields": [
     {"name": "v", "type": ["long", "string"], "default": 8}]},
   "default": {}}
]}''';
        final codec = AvroCodec(
          writer: s(writer),
          reader: s(reader),
          decodeBranches: true,
        );
        final decoded = codec.decode(Uint8List(0));
        expect(shape(decoded), {
          'u': b('string', 'd'),
          'n': null,
          'l': [b('int', 1)],
          'r': {'v': b('long', 8)},
        });
        expect(
          shape(
            AvroCodec(
              writer: s(writer),
              reader: s(reader),
            ).decode(Uint8List(0)),
          ),
          {
            'u': 'd',
            'n': null,
            'l': [1],
            'r': {'v': 8},
          },
        );
        // The default is a copy: changing one decoded value does not change the next.
        ((decoded! as Map<String, Object?>)['l']! as List<Object?>).clear();
        expect(
          shape(codec.decode(Uint8List(0))),
          containsPair('l', [b('int', 1)]),
        );
      },
    );

    test('decoded values encode back with the reader schema', () {
      const writer = '''
{"type": "record", "name": "R", "fields": [{"name": "u", "type": ["int", "string"]}]}''';
      const reader = '''
{"type": "record", "name": "R", "fields": [
  {"name": "u", "type": ["string", "long"]},
  {"name": "w", "type": ["float", "boolean"], "default": true}
]}''';
      final decoded = readAs(writer, reader, {'u': 4});
      expect(shape(decoded), {'u': b('long', 4), 'w': b('boolean', true)});
      final back = AvroCodec(writer: s(reader), decodeBranches: true);
      expect(shape(back.decode(back.encode(decoded))), shape(decoded));
    });
  });
}
