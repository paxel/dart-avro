import 'dart:io';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

AvroCodec codecOf(String json, [AvroLimits limits = const AvroLimits()]) =>
    AvroCodec(writer: Schema.parse(json), limits: limits);

Uint8List b(List<int> bytes) => Uint8List.fromList(bytes);

void roundTrip(String schema, Object? value, List<int> bytes) {
  final codec = codecOf(schema);
  expect(codec.encode(value), bytes, reason: 'encode $value');
  expect(codec.decode(b(bytes)), value, reason: 'decode $bytes');
}

const linkedList = '''
{"type": "record", "name": "LongList", "aliases": ["LinkedLongs"],
 "fields": [
   {"name": "value", "type": "long"},
   {"name": "next", "type": ["null", "LongList"]}
 ]}''';

void main() {
  group('the examples of the specification', () {
    test('record', () {
      roundTrip(
        '{"type": "record", "name": "test", "fields": '
        '[{"name": "a", "type": "long"}, {"name": "b", "type": "string"}]}',
        {'a': 27, 'b': 'foo'},
        [0x36, 0x06, 0x66, 0x6f, 0x6f],
      );
    });

    test('enum', () {
      const s =
          '{"type": "enum", "name": "Foo", "symbols": ["A", "B", "C", "D"]}';
      roundTrip(s, 'A', [0]);
      roundTrip(s, 'D', [6]);
    });

    test('array', () {
      roundTrip('{"type": "array", "items": "long"}', [3, 27], [4, 6, 0x36, 0]);
      roundTrip('{"type": "array", "items": "long"}', <Object?>[], [0]);
    });

    test('map', () {
      roundTrip(
        '{"type": "map", "values": "long"}',
        {'a': 1},
        [2, 2, 0x61, 2, 0],
      );
    });

    test('union', () {
      roundTrip('["null", "string"]', null, [0]);
      roundTrip('["null", "string"]', 'a', [2, 2, 0x61]);
    });

    test('fixed', () {
      roundTrip('{"type": "fixed", "name": "f", "size": 2}', b([1, 2]), [1, 2]);
    });
  });

  group('blocks', () {
    test('an array may come in several blocks, and with sizes', () {
      final codec = codecOf('{"type": "array", "items": "int"}');
      expect(codec.decode(b([2, 2, 4, 4, 6, 0])), [1, 2, 3]);
      // A negative count is followed by the block's size in bytes.
      expect(codec.decode(b([3, 4, 2, 4, 0])), [1, 2]);
    });

    test('a map may come in several blocks, and with sizes', () {
      final codec = codecOf('{"type": "map", "values": "int"}');
      expect(codec.decode(b([1, 6, 2, 0x61, 2, 2, 2, 0x62, 4, 0])), {
        'a': 1,
        'b': 2,
      });
    });

    test('a count beyond the input is rejected before allocating', () {
      final codec = codecOf('{"type": "array", "items": "int"}');
      expect(
        () => codec.decode(b([0xfe, 0xff, 0xff, 0xff, 0x0f])),
        throwsA(isA<DecodeException>()),
      );
    });

    test('items of zero bytes are bounded by maxZeroSizeItems', () {
      final s = '{"type": "array", "items": "null"}';
      expect(codecOf(s).decode(b([6, 0])), [null, null, null]);
      expect(
        () =>
            codecOf(s, const AvroLimits(maxZeroSizeItems: 2)).decode(b([6, 0])),
        throwsA(isA<LimitExceededException>()),
      );
    });
  });

  group('named types', () {
    test('a recursive record', () {
      final value = {
        'value': 1,
        'next': {'value': 2, 'next': null},
      };
      roundTrip(linkedList, value, [2, 2, 4, 0]);
    });

    test('a value nested deeper than maxValueDepth is rejected', () {
      final codec = codecOf(linkedList, const AvroLimits(maxValueDepth: 10));
      final deep = [
        for (var i = 0; i < 20; i++) ...[2, 2],
        2,
        0,
      ];
      expect(
        () => codec.decode(b(deep)),
        throwsA(isA<LimitExceededException>()),
      );
    });

    test('names and namespaces follow the specification', () {
      final s = Schema.parse('''
{"type": "record", "name": "Example", "fields": [
  {"name": "inheritNull", "type": {"type": "enum", "name": "Simple", "symbols": ["a", "b"]}},
  {"name": "explicitNamespace", "type":
    {"type": "fixed", "name": "Simple", "namespace": "explicit", "size": 12}},
  {"name": "fullName", "type": {"type": "record", "name": "a.full.Name",
    "namespace": "ignored", "fields": [
      {"name": "inheritNamespace", "type":
        {"type": "enum", "name": "Understanding", "symbols": ["d", "e"]}},
      {"name": "again", "type": "Understanding"}
  ]}},
  {"name": "ref", "type": "explicit.Simple"}
]}''') as RecordSchema;
      final types = [for (final f in s.fields) f.schema as NamedSchema];
      expect(s.fullName, 'Example');
      expect(s.namespace, isNull);
      expect(types[0].fullName, 'Simple');
      expect(types[1].fullName, 'explicit.Simple');
      expect(types[2].fullName, 'a.full.Name');
      expect(types[2].namespace, 'a.full');
      final inner = (types[2] as RecordSchema).fields;
      expect((inner[0].schema as NamedSchema).fullName, 'a.full.Understanding');
      expect(identical(inner[1].schema, inner[0].schema), isTrue);
      expect(identical(types[3], types[1]), isTrue);
    });

    test('aliases are full names', () {
      final s = Schema.parse(
        '{"type": "fixed", "name": "a.b", "aliases": ["c", "x.y"], "size": 1}',
      ) as FixedSchema;
      expect(s.aliases, ['a.c', 'x.y']);
    });
  });

  group('the schema tree keeps', () {
    test('doc, props and field attributes', () {
      final s = Schema.parse('''
{"type": "record", "name": "Memo", "namespace": "com.example", "doc": "A memo.",
 "axt.title": "text", "fields": [
   {"name": "text", "type": "string", "doc": "The text.", "axt.unit": "min",
    "default": "", "order": "descending", "aliases": ["body"]}
 ]}''') as RecordSchema;
      expect(s.doc, 'A memo.');
      expect(s.props, {'axt.title': 'text'});
      final f = s.fields.single;
      expect(f.name, 'text');
      expect(f.doc, 'The text.');
      expect(f.props, {'axt.unit': 'min'});
      expect(f.hasDefault, isTrue);
      expect(f.defaultValue, '');
      expect(f.order, 'descending');
      expect(f.aliases, ['body']);
      expect(() => s.fields.add(f), throwsUnsupportedError);
    });

    test('defaults as Dart values', () {
      final s = Schema.parse('''
{"type": "record", "name": "D", "fields": [
  {"name": "u", "type": ["null", "int"], "default": null},
  {"name": "v", "type": ["int", "null"], "default": 3},
  {"name": "w", "type": ["null", "string"], "default": "x"},
  {"name": "b", "type": "bytes", "default": "\\u00ff\\u0001"},
  {"name": "a", "type": {"type": "array", "items": "long"}, "default": [1]},
  {"name": "e", "type": {"type": "enum", "name": "E", "symbols": ["A"], "default": "A"}}
]}''') as RecordSchema;
      expect(
        [for (final f in s.fields) f.defaultValue],
        [
          null,
          3,
          'x',
          b([0xff, 1]),
          [1],
          null,
        ],
      );
      expect((s.fields.last.schema as EnumSchema).defaultSymbol, 'A');
    });
  });

  group('invalid schemas are rejected', () {
    for (final (why, text) in [
      ('unknown type name', '"Nope"'),
      ('missing fields', '{"type": "record", "name": "R"}'),
      (
        'duplicate field',
        '{"type": "record", "name": "R", "fields": [{"name": "a", "type": "int"}, '
            '{"name": "a", "type": "int"}]}',
      ),
      (
        'duplicate name',
        '["null", {"type": "fixed", "name": "F", "size": 1}, '
            '{"type": "enum", "name": "F", "symbols": ["A"]}]',
      ),
      ('invalid name', '{"type": "fixed", "name": "1a", "size": 1}'),
      (
        'invalid namespace',
        '{"type": "fixed", "name": "a", "namespace": "x..y", "size": 1}',
      ),
      ('primitive name', '{"type": "fixed", "name": "int", "size": 1}'),
      (
        'duplicate symbol',
        '{"type": "enum", "name": "E", "symbols": ["A", "A"]}',
      ),
      ('invalid symbol', '{"type": "enum", "name": "E", "symbols": ["a-b"]}'),
      (
        'default not a symbol',
        '{"type": "enum", "name": "E", "symbols": ["A"], "default": "B"}',
      ),
      ('nested union', '["null", ["int"]]'),
      ('duplicate union branch', '["int", "int"]'),
      (
        'two arrays in a union',
        '[{"type": "array", "items": "int"}, {"type": "array", "items": "long"}]',
      ),
      (
        'bad default',
        '{"type": "record", "name": "R", "fields": [{"name": "a", "type": "int", "default": "x"}]}',
      ),
      (
        'union default that fits no branch',
        '{"type": "record", "name": "R", "fields": '
            '[{"name": "a", "type": ["null", "int"], "default": "x"}]}',
      ),
      (
        'bad order',
        '{"type": "record", "name": "R", "fields": [{"name": "a", "type": "int", "order": "up"}]}',
      ),
      ('negative size', '{"type": "fixed", "name": "F", "size": -1}'),
      ('array without items', '{"type": "array"}'),
    ]) {
      test(why, () {
        expect(() => Schema.parse(text), throwsA(isA<SchemaParseException>()));
      });
    }
  });

  group('the parser limits', () {
    test('the schema size', () {
      expect(
        () => Schema.parse(
          '"string"',
          limits: const AvroLimits(maxSchemaBytes: 4),
        ),
        throwsA(isA<LimitExceededException>()),
      );
    });

    test('the nesting depth', () {
      final deep = '${'[' * 3}"int"${']' * 3}';
      expect(
        () => Schema.parse(deep, limits: const AvroLimits(maxSchemaDepth: 2)),
        throwsA(isA<LimitExceededException>()),
      );
      final text =
          '{"type": "array", "items": {"type": "array", "items": "int"}}';
      expect(
        Schema.parse(text, limits: const AvroLimits(maxSchemaDepth: 2)),
        isA<ArraySchema>(),
      );
    });

    test('brackets inside strings do not count', () {
      expect(
        Schema.parse(
          '{"type": "int", "x": "[[[[["}',
          limits: const AvroLimits(maxSchemaDepth: 1),
        ),
        isA<PrimitiveSchema>(),
      );
    });
  });

  group('encode is strict about records', () {
    const s =
        '{"type": "record", "name": "R", "fields": [{"name": "a", "type": "int", "default": 1}]}';

    test('a missing field throws, even with a default', () {
      expect(
        () => codecOf(s).encode(<String, Object?>{}),
        throwsA(isA<EncodeException>()),
      );
    });

    test('an unknown key throws', () {
      expect(
        () => codecOf(s).encode({'a': 1, 'b': 2}),
        throwsA(isA<EncodeException>()),
      );
    });

    test('the path names the field', () {
      try {
        codecOf(s).encode({'a': 'x'});
        fail('no exception');
      } on EncodeException catch (e) {
        expect(e.path, r'$.a');
      }
    });
  });

  group('union branches', () {
    test('are inferred when exactly one fits', () {
      final codec = codecOf('["null", "string", "long", "double", "bytes"]');
      expect(codec.encode(null), [0]);
      expect(codec.encode('a'), [2, 2, 0x61]);
      expect(codec.encode(1), [4, 2]);
      expect(codec.encode(1.5), [6, 0, 0, 0, 0, 0, 0, 0xf8, 0x3f]);
      expect(codec.encode(b([9])), [8, 2, 9]);
    });

    test(
      'an ambiguous value needs a Branch, and the error names the candidates',
      () {
        final codec = codecOf('["int", "long"]');
        expect(
          () => codec.encode(1),
          throwsA(
            isA<EncodeException>().having(
              (e) => e.message,
              'message',
              contains('int, long'),
            ),
          ),
        );
        expect(codec.encode(const Branch('long', 1)), [2, 2]);
        expect(codec.encode(0x80000000), [2, 0x80, 0x80, 0x80, 0x80, 0x10]);
      },
    );

    test('two records are told apart by their fields, else by Branch', () {
      final codec = codecOf(
        '''
[{"type": "record", "name": "a.A", "fields": [{"name": "x", "type": "int"}]},
 {"type": "record", "name": "a.B", "fields": [{"name": "y", "type": "int"}]},
 {"type": "record", "name": "a.C", "fields": [{"name": "y", "type": "int"}]}]''',
      );
      expect(codec.encode({'x': 1}), [0, 2]);
      expect(() => codec.encode({'y': 1}), throwsA(isA<EncodeException>()));
      expect(codec.encode(const Branch('a.C', {'y': 1})), [4, 2]);
      expect(codec.decode(b([4, 2])), {'y': 1});
    });

    test('a Branch the union lacks throws', () {
      expect(
        () => codecOf('["null", "int"]').encode(const Branch('string', 'x')),
        throwsA(isA<EncodeException>()),
      );
    });

    test('a branch index beyond the union is rejected', () {
      expect(
        () => codecOf('["null", "int"]').decode(b([4])),
        throwsA(isA<DecodeException>()),
      );
    });
  });

  test('an enum index beyond the symbols is rejected', () {
    expect(
      () =>
          codecOf('{"type": "enum", "name": "E", "symbols": ["A"]}')
              .decode(b([2])),
      throwsA(isA<DecodeException>()),
    );
  });

  test('a fixed of the wrong size is rejected', () {
    expect(
      () => codecOf('{"type": "fixed", "name": "F", "size": 2}').encode(b([1])),
      throwsA(isA<EncodeException>()),
    );
  });

  test("Apache Avro's interop.avsc parses and round-trips", () {
    final schema = Schema.parse(
      File('test/data/apache/interop.avsc').readAsStringSync(),
    );
    final codec = AvroCodec(writer: schema);
    final value = <String, Object?>{
      'intField': 12,
      'longField': 15234324,
      'stringField': 'hey',
      'boolField': true,
      'floatField': 1234.0,
      'doubleField': -1234.0,
      'bytesField': b([0x31, 0x32]),
      'nullField': null,
      'arrayField': [5.0, 0.0, 12.0],
      'mapField': {
        'a': {'label': 'a'},
        'bee': {'label': 'cee'},
      },
      'unionField': 12.0,
      'enumField': 'C',
      'fixedField': b(List.generate(16, (i) => i)),
      'recordField': {
        'label': 'root',
        'children': [
          {'label': 'child', 'children': <Object?>[]},
        ],
      },
    };
    expect(codec.decode(codec.encode(value)), value);
  });
}
