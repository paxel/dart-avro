import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

AvroCodec codecOf(String json) => AvroCodec(writer: Schema.parse(json));

Uint8List b(List<int> bytes) => Uint8List.fromList(bytes);

void roundTrip(String schema, Object? value, List<int> bytes) {
  final codec = codecOf(schema);
  expect(codec.encode(value), bytes, reason: 'encode $value');
  expect(codec.decode(b(bytes)), value, reason: 'decode $bytes');
}

void main() {
  group('Schema.parse', () {
    test('parses every primitive in both forms', () {
      for (final name in [
        'null',
        'boolean',
        'int',
        'long',
        'float',
        'double',
        'bytes',
        'string',
      ]) {
        final short = Schema.parse('"$name"');
        final long = Schema.parse('{"type": "$name"}');
        expect(short, isA<PrimitiveSchema>());
        expect(short.type, name);
        expect(long.type, name);
      }
    });

    test('keeps props and the original text', () {
      const text =
          '{"type": "string", "x.colour": "red", "logicalType": "uuid"}';
      final s = Schema.parse(text);
      expect(s.props, {'x.colour': 'red'});
      expect(s.logicalType, 'uuid');
      expect(s.jsonText, text);
    });

    test('rejects what is not a schema', () {
      for (final text in ['"integer"', '{}', '42', 'not json', '{"type": 1}']) {
        expect(
          () => Schema.parse(text),
          throwsA(isA<SchemaParseException>()),
          reason: text,
        );
      }
    });
  });

  group('binary encoding of the specification', () {
    test('null is zero bytes', () => roundTrip('"null"', null, []));

    test('boolean is one byte', () {
      roundTrip('"boolean"', false, [0]);
      roundTrip('"boolean"', true, [1]);
    });

    test('int and long are zig-zag varints', () {
      const cases = {
        0: [0x00],
        -1: [0x01],
        1: [0x02],
        -2: [0x03],
        2: [0x04],
        -64: [0x7f],
        64: [0x80, 0x01],
      };
      cases.forEach((v, bytes) {
        roundTrip('"int"', v, bytes);
        roundTrip('"long"', v, bytes);
      });
      roundTrip('"int"', 0x7fffffff, [0xfe, 0xff, 0xff, 0xff, 0x0f]);
      roundTrip('"int"', -0x80000000, [0xff, 0xff, 0xff, 0xff, 0x0f]);
      roundTrip('"long"', 0x7fffffffffffffff, [...List.filled(9, 0xfe), 0x01]);
      roundTrip('"long"', -0x8000000000000000, [...List.filled(9, 0xff), 0x01]);
    });

    test('float and double are little-endian IEEE 754', () {
      roundTrip('"float"', 1.5, [0x00, 0x00, 0xc0, 0x3f]);
      roundTrip('"double"', 1.5, [0, 0, 0, 0, 0, 0, 0xf8, 0x3f]);
      expect(codecOf('"double"').encode(2), [0, 0, 0, 0, 0, 0, 0, 0x40]);
    });

    test('bytes and string carry their length', () {
      roundTrip('"bytes"', b([1, 2, 3]), [0x06, 1, 2, 3]);
      roundTrip('"string"', 'foo', [0x06, 0x66, 0x6f, 0x6f]);
      roundTrip('"string"', 'ä', [0x04, 0xc3, 0xa4]);
      roundTrip('"string"', '😀', [0x08, 0xf0, 0x9f, 0x98, 0x80]);
    });
  });

  group('decode rejects', () {
    void rejects(String schema, List<int> bytes) => expect(
      () => codecOf(schema).decode(b(bytes)),
      throwsA(isA<DecodeException>()),
      reason: '$schema $bytes',
    );

    test('bytes left over', () => rejects('"int"', [0x02, 0x00]));
    test('truncated input', () {
      rejects('"int"', [0x80]);
      rejects('"double"', [0, 0, 0]);
      rejects('"string"', [0x06, 0x66]);
    });
    test(
      'an int beyond 32 bits',
      () => rejects('"int"', [0x80, 0x80, 0x80, 0x80, 0x10]),
    );
    test('a long beyond 64 bits', () {
      rejects('"long"', [...List.filled(9, 0xff), 0x02]);
      rejects('"long"', [...List.filled(10, 0xff), 0x01]);
    });
    test('a boolean other than 0 or 1', () => rejects('"boolean"', [2]));
    test('a negative length', () => rejects('"bytes"', [0x01]));
    test('a length beyond the input, before allocating', () {
      rejects('"bytes"', [0xfe, 0xff, 0xff, 0xff, 0x0f]);
    });
    test('malformed UTF-8', () {
      rejects('"string"', [0x02, 0xff]);
      rejects('"string"', [0x04, 0xc3, 0x28]);
      // An encoded surrogate code point, U+D800.
      rejects('"string"', [0x06, 0xed, 0xa0, 0x80]);
    });

    test('with the offset of the failure', () {
      try {
        codecOf('"string"').decode(b([0x06, 0x66]));
        fail('no exception');
      } on DecodeException catch (e) {
        expect(e.offset, 0);
      }
    });
  });

  group('encode rejects', () {
    void rejects(String schema, Object? value) => expect(
      () => codecOf(schema).encode(value),
      throwsA(isA<EncodeException>()),
      reason: '$schema $value',
    );

    test('a value of the wrong type', () {
      rejects('"null"', 0);
      rejects('"boolean"', 1);
      rejects('"int"', 1.5);
      rejects('"long"', '1');
      rejects('"float"', null);
      rejects('"bytes"', 'x');
      rejects('"string"', 1);
    });
    test('an int beyond 32 bits', () => rejects('"int"', 0x80000000));
    test('an unpaired surrogate', () {
      rejects('"string"', '\ud800');
      rejects('"string"', 'a\udc00');
    });
  });

  test('every failure is an AvroException', () {
    expect(() => codecOf('"int"').decode(b([])), throwsA(isA<AvroException>()));
  });

  test('AvroLimits.none has no limits', () {
    expect(AvroLimits.none.maxBlockBytes, isNull);
    expect(const AvroLimits().maxBlockBytes, 64 * 1024 * 1024);
    expect(
      AvroCodec(writer: Schema.parse('"int"'), limits: AvroLimits.none).limits,
      AvroLimits.none,
    );
  });
}
