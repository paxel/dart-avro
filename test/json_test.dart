@Tags(['web'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

AvroCodec codecOf(String schema, {String? reader, AvroLimits? limits}) =>
    AvroCodec(
      writer: Schema.parse(schema),
      reader: reader == null ? null : Schema.parse(reader),
      limits: limits ?? const AvroLimits(),
    );

/// [value] encodes to [json] and [json] decodes to [value].
void roundTrip(String schema, Object? value, String json) {
  final codec = codecOf(schema);
  expect(codec.encodeJson(value), json, reason: schema);
  expect(codec.decodeJson(json), value, reason: schema);
}

Matcher decodeError(String message, {String? path}) => throwsA(
  isA<DecodeException>()
      .having((e) => e.message, 'message', contains(message))
      .having((e) => e.offset, 'offset', 0)
      .having((e) => e.path, 'path', path ?? anything),
);

void main() {
  group('every type', () {
    test('primitives, as field defaults are written', () {
      roundTrip('"null"', null, 'null');
      roundTrip('"boolean"', true, 'true');
      roundTrip('"int"', -5, '-5');
      roundTrip('"long"', 0x7fffffffffffffff, '9223372036854775807');
      roundTrip('"long"', -0x8000000000000000, '-9223372036854775808');
      roundTrip('"double"', 1.1, '1.1');
      roundTrip('"double"', 2.0, '2.0');
      roundTrip('"string"', 'foo "bar"', r'"foo \"bar\""');
    });

    test('a logical type of a fixed: duration as its 12 bytes', () {
      roundTrip(
        '{"type": "fixed", "name": "D", "size": 12, "logicalType": "duration"}',
        const AvroDuration(1, 2, 3),
        '"\\u0001\\u0000\\u0000\\u0000\\u0002\\u0000\\u0000\\u0000\\u0003\\u0000\\u0000\\u0000"',
      );
    });

    test('bytes and fixed as strings of the code points 0 to 255', () {
      roundTrip(
        '"bytes"',
        Uint8List.fromList([0, 0x41, 0xff]),
        '"\\u0000A\u00ff"',
      );
      roundTrip(
        '{"type": "fixed", "name": "F", "size": 2}',
        Uint8List.fromList([0xff, 1]),
        '"\u00ff\\u0001"',
      );
      // The spec's examples, with \u escapes.
      expect(codecOf('"bytes"').decodeJson(r'"\u00FF"'), [0xff]);
    });

    test('a float as the fewest digits that are the same float', () {
      final codec = codecOf('"float"');
      // Read from binary, the float 0.1 is the double 0.10000000149011612.
      final decoded = codec.decode(codec.encode(0.1));
      expect(decoded, isNot(0.1));
      expect(codec.encodeJson(decoded), '0.1');
      expect(codec.encodeJson(3.4028234663852886e38), '3.4028235e+38');
      expect(codec.decodeJson('0.1'), decoded);
      expect(codec.decodeJson('1'), 1.0);
    });

    test('NaN and the infinities as strings, both ways', () {
      for (final schema in ['"float"', '"double"']) {
        final codec = codecOf(schema);
        expect(codec.encodeJson(double.nan), '"NaN"');
        expect(codec.encodeJson(double.infinity), '"Infinity"');
        expect(codec.encodeJson(double.negativeInfinity), '"-Infinity"');
        expect((codec.decodeJson('"NaN"')! as double).isNaN, isTrue);
        expect(codec.decodeJson('"Infinity"'), double.infinity);
        expect(codec.decodeJson('"-Infinity"'), double.negativeInfinity);
        expect(
          () => codec.decodeJson('"nan"'),
          decodeError('expected a number'),
        );
      }
    });

    test('records, enums, arrays and maps', () {
      roundTrip(
        '{"type": "record", "name": "R", "fields": [{"name": "a", "type": "int"}, '
            '{"name": "e", "type": {"type": "enum", "name": "E", "symbols": ["X", "Y"]}}, '
            '{"name": "l", "type": {"type": "array", "items": "long"}}, '
            '{"name": "m", "type": {"type": "map", "values": "string"}}]}',
        {
          'a': 1,
          'e': 'Y',
          'l': [1, 2],
          'm': {'k': 'v'},
        },
        '{"a":1,"e":"Y","l":[1,2],"m":{"k":"v"}}',
      );
    });

    test("the spec's linked list of longs", () {
      const schema =
          '{"type": "record", "name": "LongList", "aliases": ["LinkedLongs"], "fields": ['
          '{"name": "value", "type": "long"}, {"name": "next", "type": ["null", "LongList"]}]}';
      roundTrip(schema, {
        'value': 1,
        'next': {'value': 2, 'next': null},
      }, '{"value":1,"next":{"LongList":{"value":2,"next":null}}}');
    });

    test('logical types as their underlying type', () {
      roundTrip(
        '{"type": "long", "logicalType": "timestamp-millis"}',
        DateTime.utc(2000, 1, 1, 10),
        '946720800000',
      );
      roundTrip(
        '{"type": "int", "logicalType": "date"}',
        const AvroDate(1970, 1, 2),
        '1',
      );
      roundTrip(
        '{"type": "string", "logicalType": "uuid"}',
        '123e4567-e89b-12d3-a456-426614174000',
        '"123e4567-e89b-12d3-a456-426614174000"',
      );
      // 12345 is 0x3039.
      roundTrip(
        '{"type": "bytes", "logicalType": "decimal", "precision": 9, "scale": 2}',
        AvroDecimal(BigInt.from(12345), 2),
        '"09"',
      );
    });
  });

  group('unions', () {
    const schema =
        '["null", "string", "int", {"type": "record", "name": "Foo", "namespace": "a", '
        '"fields": [{"name": "x", "type": "int"}]}, {"type": "map", "values": "int"}]';

    test('null, or an object of the type name or full name', () {
      roundTrip(schema, null, 'null');
      roundTrip(schema, 'a', '{"string":"a"}');
      final codec = codecOf(schema);
      expect(codec.encodeJson(const Branch('int', 5)), '{"int":5}');
      expect(codec.decodeJson('{"int":5}'), 5);
      expect(
        codec.encodeJson(const Branch('a.Foo', {'x': 1})),
        '{"a.Foo":{"x":1}}',
      );
      expect(codec.decodeJson('{"a.Foo":{"x":1}}'), {'x': 1});
      expect(
        codec.encodeJson(const Branch('map', {'x': 1})),
        '{"map":{"x":1}}',
      );
      expect(codec.decodeJson('{"map":{"x":1}}'), {'x': 1});
    });

    test("the spec's example, hand-written: [\"null\", \"string\", \"Foo\"]", () {
      const spec =
          '["null", "string", {"type": "record", "name": "Foo", "fields": [{"name": "x", "type": "int"}]}]';
      roundTrip(spec, null, 'null');
      roundTrip(spec, 'a', '{"string":"a"}');
      roundTrip(spec, {'x': 1}, '{"Foo":{"x":1}}');
    });

    test('{"null": null} decodes as the null branch, as Java reads it', () {
      expect(codecOf(schema).decodeJson('{"null":null}'), isNull);
    });

    test('decoding also takes an unambiguous simple name', () {
      expect(codecOf(schema).decodeJson('{"Foo":{"x":1}}'), {'x': 1});
    });

    test('an exact name wins over a simple name', () {
      const both =
          '[{"type": "record", "name": "Foo", "fields": [{"name": "x", "type": "int"}]}, '
          '{"type": "record", "name": "Foo", "namespace": "a", "fields": [{"name": "y", "type": "int"}]}]';
      expect(codecOf(both).decodeJson('{"Foo":{"x":1}}'), {'x': 1});
      expect(codecOf(both).decodeJson('{"a.Foo":{"y":1}}'), {'y': 1});
    });

    test('an ambiguous simple name is rejected', () {
      const two =
          '[{"type": "fixed", "name": "Foo", "namespace": "a", "size": 1}, '
          '{"type": "fixed", "name": "Foo", "namespace": "b", "size": 1}]';
      expect(
        () => codecOf(two).decodeJson('{"Foo":"x"}'),
        decodeError('names more than one branch', path: r'$'),
      );
      expect(codecOf(two).decodeJson('{"b.Foo":"x"}'), [0x78]);
    });

    test('a logical branch is named by its underlying type', () {
      const logical =
          '["null", {"type": "long", "logicalType": "timestamp-millis"}]';
      roundTrip(logical, DateTime.utc(1970, 1, 1, 0, 0, 1), '{"long":1000}');
    });

    test('rejected', () {
      final codec = codecOf(schema);
      expect(
        () => codec.decodeJson('"a"'),
        decodeError('a union value is null or an object'),
      );
      expect(
        () => codec.decodeJson('{}'),
        decodeError('a union value is null or an object'),
      );
      expect(
        () => codec.decodeJson('{"string":"a","int":1}'),
        decodeError('a union value is null or an object'),
      );
      expect(
        () => codec.decodeJson('{"long":1}'),
        decodeError('the union has no branch "long"'),
      );
      expect(
        () => codecOf('["int", "string"]').decodeJson('null'),
        decodeError('no null branch'),
      );
    });
  });

  group('indent', () {
    test('compact by default, indented with indent', () {
      final codec = codecOf(
        '{"type": "record", "name": "R", "fields": [{"name": "a", "type": {"type": "array", "items": "int"}}]}',
      );
      final value = {
        'a': [1, 2],
      };
      expect(codec.encodeJson(value), '{"a":[1,2]}');
      expect(
        codec.encodeJson(value, indent: '  '),
        '{\n  "a": [\n    1,\n    2\n  ]\n}',
      );
      expect(codec.decodeJson(codec.encodeJson(value, indent: '\t')), value);
    });
  });

  group('resolution', () {
    test('decodeJson reads the writer schema as the reader schema', () {
      final codec = codecOf(
        '{"type": "record", "name": "R", "fields": [{"name": "a", "type": "int"}, {"name": "gone", "type": "string"}]}',
        reader:
            '{"type": "record", "name": "R", "fields": [{"name": "a", "type": "long"}, '
            '{"name": "added", "type": "string", "default": "new"}]}',
      );
      expect(codec.decodeJson('{"a":1,"gone":"x"}'), {'a': 1, 'added': 'new'});
    });

    test('a writer branch the reader lacks fails as it does in decode', () {
      final codec = codecOf('["int", "string"]', reader: '"int"');
      expect(codec.decodeJson('{"int":1}'), 1);
      expect(
        () => codec.decodeJson('{"string":"x"}'),
        throwsA(isA<ResolutionException>()),
      );
    });

    test('an error of a logical type has offset 0 and the path', () {
      final codec = codecOf(
        '{"type": "record", "name": "R", "fields": [{"name": "u", "type": {"type": "string", "logicalType": "uuid"}}]}',
      );
      expect(
        () => codec.decodeJson('{"u":"not a uuid"}'),
        decodeError('', path: r'$.u'),
      );
    });
  });

  group('TypedCodec', () {
    final memo = AvroType<(String, int)>(
      schemaJson:
          '{"type": "record", "name": "Memo", "namespace": "com.example", '
          '"fields": [{"name": "text", "type": "string"}, {"name": "n", "type": ["null", "int"]}]}',
      toAvro: (m) => {'text': m.$1, 'n': m.$2},
      fromAvro: (v) {
        final m = v! as Map<String, Object?>;
        return (m['text']! as String, m['n']! as int);
      },
    );

    test(
      'a JSON round trip with the type, and with resolution from a writer',
      () {
        final codec = TypedCodec(memo);
        final json = codec.encodeJson(('Vet', 3));
        expect(json, '{"text":"Vet","n":{"int":3}}');
        expect(codec.decodeJson(json), ('Vet', 3));
        final older = TypedCodec(
          memo,
          writer: Schema.parse(
            '{"type": "record", "name": "Memo", "namespace": "com.example", '
            '"fields": [{"name": "text", "type": "string"}, {"name": "n", "type": "int"}]}',
          ),
        );
        expect(older.decodeJson('{"text":"Vet","n":3}'), ('Vet', 3));
        expect(older.encodeJson(('Vet', 3)), json);
      },
    );
  });

  group('rejected', () {
    const record =
        '{"type": "record", "name": "R", "fields": [{"name": "a", "type": "int"}, '
        '{"name": "b", "type": {"type": "array", "items": "bytes"}}]}';

    test('JSON that is not JSON', () {
      expect(() => codecOf('"int"').decodeJson('{'), decodeError('not JSON'));
    });

    test('unknown and missing fields, without defaults', () {
      final codec = codecOf(record);
      expect(
        () => codec.decodeJson('{"a":1,"b":[],"c":2}'),
        decodeError('"c" is not a field of R', path: r'$'),
      );
      expect(
        () => codec.decodeJson('{"a":1}'),
        decodeError('the field "b" is missing'),
      );
    });

    test('wrong JSON types, with the path', () {
      final codec = codecOf(record);
      expect(
        () => codec.decodeJson('{"a":"1","b":[]}'),
        decodeError('expected an integer for int, got a string', path: r'$.a'),
      );
      expect(
        () => codec.decodeJson('{"a":1,"b":["x", 2]}'),
        decodeError('expected a string for bytes', path: r'$.b[1]'),
      );
      expect(
        () => codecOf('"boolean"').decodeJson('1'),
        decodeError('expected true or false'),
      );
      expect(
        () => codecOf('"int"').decodeJson('1.0'),
        decodeError('expected an integer'),
      );
      expect(
        () => codecOf('"long"').decodeJson('1e2'),
        decodeError('expected an integer'),
      );
      expect(
        () => codecOf('"null"').decodeJson('0'),
        decodeError('expected null'),
      );
      expect(
        () => codecOf('{"type": "map", "values": "int"}').decodeJson('[]'),
        decodeError('expected an object'),
      );
    });

    test('the wrong JSON type for every other kind of schema', () {
      for (final (schema, json, expected) in [
        ('"string"', '1', 'expected a string for string'),
        (
          '{"type": "fixed", "name": "F", "size": 1}',
          '1',
          'expected a string for F',
        ),
        (
          '{"type": "enum", "name": "E", "symbols": ["X"]}',
          'true',
          'expected a string for E',
        ),
        (
          '{"type": "array", "items": "int"}',
          '{}',
          'expected an array for array',
        ),
        (record, '[]', 'expected an object for R'),
        ('"double"', 'null', 'expected a number'),
      ]) {
        expect(
          () => codecOf(schema).decodeJson(json),
          decodeError(expected, path: r'$'),
        );
      }
    });

    test('integers beyond their range', () {
      expect(
        () => codecOf('"int"').decodeJson('2147483648'),
        decodeError('does not fit 32 bits'),
      );
      expect(codecOf('"int"').decodeJson('-2147483648'), -0x80000000);
      expect(
        () => codecOf('"long"').decodeJson('9223372036854775808'),
        decodeError('expected an integer'),
      );
    });

    test('bytes beyond 255, a fixed of another size, an unknown symbol', () {
      expect(
        () => codecOf('"bytes"').decodeJson('"\u0100"'),
        decodeError('code points 0 to 255'),
      );
      expect(
        () =>
            codecOf('{"type": "fixed", "name": "F", "size": 2}')
                .decodeJson('"a"'),
        decodeError('a fixed of 2 bytes, got 1'),
      );
      expect(
        () =>
            codecOf('{"type": "enum", "name": "E", "symbols": ["X"]}')
                .decodeJson('"Z"'),
        decodeError('"Z" is not a symbol of E'),
      );
    });

    test('a string with an unpaired surrogate', () {
      expect(
        () => codecOf('"string"').decodeJson(r'"\ud800"'),
        decodeError('not well-formed'),
      );
      expect(
        () =>
            codecOf('{"type": "map", "values": "int"}')
                .decodeJson(r'{"\udc00":1}'),
        decodeError('not well-formed'),
      );
    });

    test('a value that does not fit on encoding throws EncodeException', () {
      expect(
        () => codecOf(record).encodeJson({'a': 'x', 'b': <Object?>[]}),
        throwsA(isA<EncodeException>().having((e) => e.path, 'path', r'$.a')),
      );
    });
  });

  group('limits', () {
    const list =
        '{"type": "record", "name": "L", "fields": [{"name": "next", "type": ["null", "L"]}]}';

    String nested(int records) {
      var json = '{"next":null}';
      for (var i = 1; i < records; i++) {
        json = '{"next":{"L":$json}}';
      }
      return json;
    }

    test(
      'maxValueDepth applies as it does to binary, at the same boundary',
      () {
        const limits = AvroLimits(maxValueDepth: 20);
        final codec = codecOf(list, limits: limits);
        // Each record below the root is two levels deeper: the union, then the record.
        final fits = nested(10);
        final value = codecOf(list).decodeJson(fits);
        expect(codec.decode(codecOf(list).encode(value)), value);
        expect(codec.decodeJson(fits), value);
        final deeper = codecOf(list).decodeJson(nested(11));
        final bytes = codecOf(list).encode(deeper);
        expect(
          () => codec.decode(bytes),
          throwsA(
            isA<LimitExceededException>().having(
              (e) => e.limit,
              'limit',
              'maxValueDepth',
            ),
          ),
        );
        expect(
          () => codec.decodeJson(nested(11)),
          throwsA(
            isA<LimitExceededException>().having(
              (e) => e.limit,
              'limit',
              'maxValueDepth',
            ),
          ),
        );
      },
    );

    test('the depth check is exact for nested containers', () {
      const tree =
          '{"type": "record", "name": "T", "fields": [{"name": "kids", "type": {"type": "array", "items": "T"}}]}';
      const json = '{"kids":[{"kids":[]}]}';
      final value = codecOf(tree).decodeJson(json);
      final bytes = codecOf(tree).encode(value);
      final fits = codecOf(tree, limits: const AvroLimits(maxValueDepth: 3));
      expect(fits.decodeJson(json), value);
      expect(fits.decode(bytes), value);
      final tight = codecOf(tree, limits: const AvroLimits(maxValueDepth: 2));
      for (final decode in [
        () => tight.decodeJson(json),
        () => tight.decode(bytes),
      ]) {
        expect(
          decode,
          throwsA(
            isA<LimitExceededException>().having(
              (e) => e.limit,
              'limit',
              'maxValueDepth',
            ),
          ),
        );
      }
    });

    test('deep JSON is rejected before it is parsed', () {
      expect(
        () => codecOf('"int"').decodeJson('[' * 100000),
        throwsA(
          isA<LimitExceededException>().having(
            (e) => e.limit,
            'limit',
            'maxValueDepth',
          ),
        ),
      );
    });

    test('encodeJson does not apply the decoding limits', () {
      final codec = codecOf(
        '{"type": "array", "items": "null"}',
        limits: const AvroLimits(maxZeroSizeItems: 2),
      );
      expect(codec.encodeJson([null, null, null]), '[null,null,null]');
    });
  });

  test('the output is JSON that jsonDecode reads', () {
    final codec = codecOf(
      '{"type": "map", "values": ["null", "double", "bytes"]}',
    );
    final json = codec.encodeJson({
      'n': null,
      'd': const Branch('double', double.nan),
      'b': Uint8List.fromList([0, 10, 34, 92, 255]),
    });
    expect(jsonDecode(json), {
      'n': null,
      'd': {'double': 'NaN'},
      'b': {'bytes': '\u0000\n"\\\u00ff'},
    });
  });
}
