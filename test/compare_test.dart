@Tags(['web'])
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

import 'data/axt/axt_types.g.dart';

AvroCodec codecOf(String json, {AvroLimits limits = const AvroLimits()}) =>
    AvroCodec(writer: Schema.parse(json), limits: limits);

Uint8List b(List<int> bytes) => Uint8List.fromList(bytes);

/// Checks that [x] compares to [y] as [expected], both ways round, as values and as bytes.
void orders(String schema, Object? x, Object? y, int expected) {
  final codec = codecOf(schema);
  final reason = '$x against $y in $schema';
  expect(codec.compare(x, y), expected, reason: reason);
  expect(codec.compare(y, x), -expected, reason: reason);
  final ex = codec.encode(x);
  final ey = codec.encode(y);
  expect(codec.compareBytes(ex, ey), expected, reason: reason);
  expect(codec.compareBytes(ey, ex), -expected, reason: reason);
}

void main() {
  group('the sort order of the specification', () {
    test('null values are equal', () {
      orders('"null"', null, null, 0);
    });

    test('false is less than true', () {
      orders('"boolean"', false, true, -1);
      orders('"boolean"', true, true, 0);
    });

    test('int and long compare by value, at their extremes too', () {
      orders('"int"', -0x80000000, 0x7fffffff, -1);
      orders('"int"', -1, 0, -1);
      orders('"int"', 7, 7, 0);
      orders('"long"', -0x8000000000000000, 0x7fffffffffffffff, -1);
      orders('"long"', 1 << 40, 1 << 41, -1);
    });

    test(
      'double compares as Java Double.compare: NaN last, -0.0 before 0.0',
      () {
        const s = '"double"';
        orders(s, double.nan, double.nan, 0);
        orders(s, double.infinity, double.nan, -1);
        orders(s, double.negativeInfinity, -1e308, -1);
        orders(s, -0.0, 0.0, -1);
        orders(s, 1.0, 1.0 + 1e-12, -1);
        orders(s, 2, 2.5, -1);
      },
    );

    test('float compares the 32-bit value it encodes to', () {
      const s = '"float"';
      orders(s, 1.0, 1.0 + 1e-12, 0);
      orders(s, double.nan, double.infinity, 1);
      orders(s, -0.0, 0.0, -1);
      orders(s, 1, 1.5, -1);
    });

    test('bytes compare as unsigned bytes, a prefix first', () {
      orders('"bytes"', b([0x7f]), b([0x80]), -1);
      orders('"bytes"', b([1, 2]), b([1, 2, 0]), -1);
      orders('"bytes"', b([]), b([0]), -1);
      orders('"bytes"', b([5, 5]), b([5, 5]), 0);
    });

    test(
      'strings compare by their UTF-8 bytes, not their UTF-16 code units',
      () {
        orders('"string"', 'a', 'ab', -1);
        orders('"string"', 'b', 'ab', 1);
        orders('"string"', 'Z', 'a', -1);
        // U+FFFF is EF BF BF, U+10000 is F0 90 80 80; in UTF-16, U+10000 starts with D800.
        orders('"string"', '￿', '\u{10000}', -1);
        orders('"string"', 'é', 'z', 1);
      },
    );

    test('fixed compares as unsigned bytes', () {
      const s = '{"type": "fixed", "name": "F", "size": 2}';
      orders(s, b([0, 0xff]), b([1, 0]), -1);
      orders(s, b([3, 4]), b([3, 4]), 0);
    });

    test('enums compare by the index of their symbol, not by name', () {
      const s = '{"type": "enum", "name": "E", "symbols": ["z", "a"]}';
      orders(s, 'z', 'a', -1);
      orders(s, 'a', 'a', 0);
    });

    test('arrays compare element by element, then by length', () {
      const s = '{"type": "array", "items": "int"}';
      orders(s, [1, 2], [1, 3], -1);
      orders(s, [1, 2], [1, 2, 0], -1);
      orders(s, [2], [1, 5], 1);
      orders(s, <Object?>[], [0], -1);
      orders(s, [4, 4], [4, 4], 0);
    });

    test('unions compare by branch index, then by value', () {
      const s = '["null", "string", "int"]';
      orders(s, null, 'a', -1);
      orders(s, 'z', 0, -1);
      orders(s, 3, 4, -1);
      orders(s, 'b', 'a', 1);
      orders(s, const Branch('int', 3), 3, 0);
    });

    test('records compare field by field in the order of each field', () {
      const s =
          '{"type": "record", "name": "R", "fields": ['
          '{"name": "a", "type": "int"}, '
          '{"name": "b", "type": "int", "order": "descending"}, '
          '{"name": "c", "type": "int", "order": "ignore"}, '
          '{"name": "d", "type": "int"}]}';
      orders(
        s,
        {'a': 1, 'b': 0, 'c': 0, 'd': 0},
        {'a': 2, 'b': 9, 'c': 0, 'd': 0},
        -1,
      );
      orders(
        s,
        {'a': 1, 'b': 1, 'c': 0, 'd': 0},
        {'a': 1, 'b': 2, 'c': 0, 'd': 0},
        1,
      );
      orders(
        s,
        {'a': 1, 'b': 1, 'c': 5, 'd': 0},
        {'a': 1, 'b': 1, 'c': 9, 'd': 0},
        0,
      );
      orders(
        s,
        {'a': 1, 'b': 1, 'c': 9, 'd': 0},
        {'a': 1, 'b': 1, 'c': 5, 'd': 1},
        -1,
      );
    });

    test('a value of a logical type compares as its underlying value', () {
      const decimal =
          '{"type": "bytes", "logicalType": "decimal", "precision": 9, "scale": 2}';
      // The two's complement of -1 is FF, of 1 is 01: as bytes, -1 sorts after 1.
      orders(
        decimal,
        AvroDecimal(BigInt.from(-1), 2),
        AvroDecimal(BigInt.one, 2),
        1,
      );
      orders(
        '{"type": "int", "logicalType": "date"}',
        const AvroDate(1969, 12, 31),
        const AvroDate(1970, 1, 1),
        -1,
      );
      orders(
        '{"type": "long", "logicalType": "timestamp-millis"}',
        DateTime.utc(2000),
        DateTime.utc(1999),
        1,
      );
      orders(
        '{"type": "string", "logicalType": "uuid"}',
        '123E4567-E89B-12D3-A456-426614174000',
        '123e4567-e89b-12d3-a456-426614174000',
        0,
      );
    });
  });

  group('maps', () {
    const inArray =
        '{"type": "array", "items": {"type": "map", "values": "int"}}';

    test('cannot be compared, as values or as bytes', () {
      final codec = codecOf(inArray);
      expect(
        () => codec.compare([<String, Object?>{}], [<String, Object?>{}]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            r'the map at $[0] cannot be compared: Avro gives maps no order',
          ),
        ),
      );
      final e = codec.encode([<String, Object?>{}]);
      expect(() => codec.compareBytes(e, e), throwsArgumentError);
    });

    test('throw where the data reaches them', () {
      final codec = codecOf('["null", {"type": "map", "values": "int"}]');
      final map = codec.encode(<String, Object?>{});
      expect(() => codec.compareBytes(map, map), throwsArgumentError);
      expect(
        () => codec.compare(<String, Object?>{}, <String, Object?>{}),
        throwsArgumentError,
      );
      expect(codec.compareBytes(codec.encode(null), map), -1);
    });

    test('are not reached where the order decides before them', () {
      orders(inArray, <Object?>[], [<String, Object?>{}], -1);
      orders('["null", {"type": "map", "values": "int"}]', null, null, 0);
    });

    test('in an ignored field are skipped, in any blocking', () {
      final codec = codecOf(
        '{"type": "record", "name": "R", "fields": ['
        '{"name": "m", "type": {"type": "map", "values": "int"}, "order": "ignore"}, '
        '{"name": "k", "type": "int"}]}',
      );
      final x = {
        'm': {'a': 1},
        'k': 1,
      };
      final y = {'m': <String, Object?>{}, 'k': 2};
      expect(codec.compare(x, y), -1);
      expect(codec.compareBytes(codec.encode(x), codec.encode(y)), -1);
      // The map {"a": 1} as one block of count -1 and size 3, then k = 1.
      final negative = b([1, 6, 2, 0x61, 2, 0, 2]);
      expect(codec.compareBytes(negative, codec.encode(x)), 0);
      expect(codec.compareBytes(negative, codec.encode(y)), -1);
    });
  });

  group('compareBytes', () {
    final ints = codecOf('{"type": "array", "items": "int"}');

    test('an array compares the same in any blocking', () {
      final one = ints.encode([1, 2, 3]);
      // [1, 2] then [3], then the end.
      final two = b([4, 2, 4, 2, 6, 0]);
      // A block of count -2 and a size of 2 bytes, then [3], then the end.
      final sized = b([3, 4, 2, 4, 2, 6, 0]);
      expect(ints.compareBytes(one, two), 0);
      expect(ints.compareBytes(two, sized), 0);
      expect(ints.compareBytes(b([2, 2, 2, 6, 0]), one), 1);
      expect(ints.compareBytes(b([2, 2, 0]), two), -1);
      expect(ints.compareBytes(two, b([2, 2, 2, 4, 2, 6, 2, 0, 0])), -1);
    });

    test('throws DecodeException on malformed input it reads', () {
      expect(
        () => ints.compareBytes(b([4, 2]), b([4, 2])),
        throwsA(isA<DecodeException>()),
      );
      final enums = codecOf('{"type": "enum", "name": "E", "symbols": ["a"]}');
      expect(
        () => enums.compareBytes(b([0]), b([2])),
        throwsA(
          isA<DecodeException>().having(
            (e) => e.message,
            'message',
            '1 is not a symbol of E',
          ),
        ),
      );
      final unions = codecOf('["null", "int"]');
      expect(
        () => unions.compareBytes(b([4]), b([0])),
        throwsA(
          isA<DecodeException>().having(
            (e) => e.message,
            'message',
            'the union has no branch 2',
          ),
        ),
      );
      final longs = codecOf('"long"');
      expect(
        () => longs.compareBytes(
          b([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0]),
          b([0]),
        ),
        throwsA(isA<DecodeException>()),
      );
      expect(
        () => codecOf('"string"').compareBytes(b([10, 0x61]), b([2, 0x61])),
        throwsA(isA<DecodeException>()),
      );
    });

    test('reads only as far as the first difference', () {
      final pair = codecOf(
        '{"type": "record", "name": "R", "fields": ['
        '{"name": "a", "type": "int"}, {"name": "s", "type": "string"}]}',
      );
      // The second field of each is cut short, but the first decides.
      expect(pair.compareBytes(b([2, 20]), b([4, 20])), -1);
      // Bytes after the datum are not read.
      expect(codecOf('"int"').compareBytes(b([2, 9, 9]), b([2])), 0);
    });

    test('stops at the limits of the codec', () {
      final deep = codecOf(
        '{"type": "record", "name": "L", "fields": [{"name": "next", "type": ["null", "L"]}]}',
        limits: const AvroLimits(maxValueDepth: 8),
      );
      final input = b([...List.filled(20, 2), 0]);
      expect(
        () => deep.compareBytes(input, input),
        throwsA(isA<LimitExceededException>()),
      );
      final nulls = codecOf(
        '{"type": "array", "items": "null"}',
        limits: const AvroLimits(maxZeroSizeItems: 100),
      );
      final many = b([0xfe, 0xff, 0xff, 0xff, 0x0f, 0]);
      expect(
        () => nulls.compareBytes(many, many),
        throwsA(isA<LimitExceededException>()),
      );
    });
  });

  group('compare', () {
    final codec = codecOf(
      '{"type": "record", "name": "R", "fields": ['
      '{"name": "a", "type": "int"}, {"name": "c", "type": "int", "order": "ignore"}]}',
    );

    test('throws EncodeException on a value that does not fit the schema', () {
      expect(
        () => codec.compare({'a': 1, 'c': 0}, {'a': 'x', 'c': 0}),
        throwsA(isA<EncodeException>().having((e) => e.path, 'path', r'$.a')),
      );
      expect(
        () => codec.compare({'a': 1, 'c': 0}, {'c': 0}),
        throwsA(isA<EncodeException>()),
      );
      expect(
        () => codec.compare({'a': 1, 'c': 0}, {'a': 1, 'c': 0, 'z': 0}),
        throwsA(isA<EncodeException>()),
      );
      expect(
        () => codecOf('"int"').compare(1, 1 << 40),
        throwsA(isA<EncodeException>()),
      );
      expect(
        () => codecOf('"string"').compare('a', '\ud800'),
        throwsA(isA<EncodeException>()),
      );
    });

    test('does not look at the values of ignored fields', () {
      expect(codec.compare({'a': 1}, {'a': 1, 'c': 'not an int'}), 0);
    });
  });

  test(
    'TypedCodec.compare compares typed values by the schema of the type',
    () {
      final codec = TypedCodec(AxtDateTime.avroType);
      AxtDateTime at(int year, int second) => AxtDateTime(
        year: year,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: second,
        millisecond: 0,
      );
      expect(codec.compare(at(2025, 59), at(2026, 0)), -1);
      expect(codec.compare(at(2026, 1), at(2026, 0)), 1);
      expect(codec.compare(at(2026, 1), at(2026, 1)), 0);
      expect(
        codec.avro.compareBytes(
          codec.encode(at(2025, 59)),
          codec.encode(at(2026, 0)),
        ),
        -1,
      );
    },
  );

  group('compare and compareBytes agree', () {
    const schemas = {
      'every type': '''
{"type": "record", "name": "P", "fields": [
  {"name": "n", "type": "null"},
  {"name": "b", "type": "boolean", "order": "descending"},
  {"name": "i", "type": "int"},
  {"name": "l", "type": "long", "order": "descending"},
  {"name": "f", "type": "float"},
  {"name": "d", "type": "double"},
  {"name": "by", "type": "bytes"},
  {"name": "s", "type": "string"},
  {"name": "x", "type": {"type": "fixed", "name": "F", "size": 2}},
  {"name": "e", "type": {"type": "enum", "name": "E", "symbols": ["z", "a", "m"]},
   "order": "descending"},
  {"name": "m", "type": {"type": "map", "values": "int"}, "order": "ignore"},
  {"name": "a", "type": {"type": "array", "items": ["null", "int", "string"]}},
  {"name": "u", "type": ["null", "string", {"type": "record", "name": "Q", "fields": [
    {"name": "k", "type": "int", "order": "ignore"},
    {"name": "v", "type": "long"}]}]},
  {"name": "dec", "type": {"type": "bytes", "logicalType": "decimal", "precision": 9,
   "scale": 2}},
  {"name": "date", "type": {"type": "int", "logicalType": "date"}},
  {"name": "id", "type": {"type": "string", "logicalType": "uuid"}},
  {"name": "next", "type": ["null", "P"]}
]}''',
      'arrays of arrays':
          '{"type": "array", "items": {"type": "array", "items": "double"}}',
      'a union of named types': '''
[{"type": "enum", "name": "E", "symbols": ["a", "b"]},
 {"type": "fixed", "name": "F", "size": 1},
 {"type": "record", "name": "R", "fields": [{"name": "s", "type": "string",
   "order": "descending"}]}]''',
    };
    for (final MapEntry(key: name, value: json) in schemas.entries) {
      test('on 3,000 pairs of $name', () {
        final codec = codecOf(json);
        final random = Random(20261122);
        for (var i = 0; i < 3000; i++) {
          final x = generate(codec.writer, random, 0);
          final y = switch (random.nextInt(4)) {
            0 => x,
            1 => generate(codec.writer, random, 0),
            _ => mutate(codec.writer, x, random, 0),
          };
          final ex = codec.encode(x);
          final ey = codec.encode(y);
          final c = codec.compare(x, y);
          final reason = '$x against $y';
          expect(codec.compareBytes(ex, ey), c, reason: reason);
          expect(codec.compare(y, x), -c, reason: reason);
          expect(codec.compareBytes(ey, ex), -c, reason: reason);
          expect(codec.compare(x, x), 0, reason: reason);
          expect(codec.compareBytes(ex, ex), 0, reason: reason);
        }
      });
    }
  });
}

const _ints = [-0x80000000, -2, -1, 0, 1, 2, 0x7fffffff];
const _longs = [-0x8000000000000000, -1, 0, 1, 1 << 40, 0x7fffffffffffffff];
const _doubles = [
  double.nan,
  double.negativeInfinity,
  -1.5,
  -0.0,
  0.0,
  1.0,
  1.0 + 1e-12,
  3.4e38,
  1e300,
  double.infinity,
];
const _strings = ['', 'a', 'ab', 'b', 'Z', 'é', '￿', '\u{10000}'];
const _hex = '0123456789abcdefABCDEF';

String _name(Schema s) => s is NamedSchema ? s.fullName : s.type;

/// A random value of [schema] from small domains, so that pairs are often equal in part.
Object? generate(Schema schema, Random r, int depth) {
  T pick<T>(List<T> from) => from[r.nextInt(from.length)];
  switch (schema.logicalType) {
    case 'decimal':
      return AvroDecimal(BigInt.from(r.nextInt(5) - 2) << r.nextInt(12), 2);
    case 'date':
      return AvroDate.fromEpochDays(pick([-1, 0, 1, 20000]));
    case 'uuid':
      String hex(int n) =>
          [for (var i = 0; i < n; i++) _hex[r.nextInt(r.nextBool() ? 2 : 22)]]
              .join();
      return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }
  switch (schema) {
    case PrimitiveSchema(type: 'null'):
      return null;
    case PrimitiveSchema(type: 'boolean'):
      return r.nextBool();
    case PrimitiveSchema(type: 'int'):
      return pick(_ints);
    case PrimitiveSchema(type: 'long'):
      return pick(_longs);
    case PrimitiveSchema(type: 'float' || 'double'):
      return pick(_doubles);
    case PrimitiveSchema(type: 'bytes'):
      return b([
        for (var i = r.nextInt(3); i > 0; i--) pick([0, 0x7f, 0x80, 0xff]),
      ]);
    case PrimitiveSchema(type: 'string'):
      return pick(_strings);
    case PrimitiveSchema():
      throw StateError(schema.type);
    case FixedSchema(:final size):
      return b([
        for (var i = 0; i < size; i++) pick([0, 0x7f, 0x80, 0xff]),
      ]);
    case EnumSchema(:final symbols):
      return pick(symbols);
    case ArraySchema(:final items):
      return [
        for (var i = r.nextInt(depth > 2 ? 1 : 4); i > 0; i--)
          generate(items, r, depth + 1),
      ];
    case MapSchema(:final values):
      return {
        for (var i = r.nextInt(3); i > 0; i--)
          pick(_strings): generate(values, r, depth + 1),
      };
    case RecordSchema(:final fields):
      return {for (final f in fields) f.name: generate(f.schema, r, depth + 1)};
    case UnionSchema(:final branches):
      final choices = depth > 2
          ? branches.where((s) => s.type == 'null').toList()
          : branches;
      final branch = pick(choices.isEmpty ? branches : choices);
      final value = generate(branch, r, depth + 1);
      return branch.type == 'null' && r.nextBool()
          ? null
          : Branch(_name(branch), value);
  }
}

/// [value] with one part in it replaced at random.
Object? mutate(Schema schema, Object? value, Random r, int depth) {
  if (schema.logicalType != null) return generate(schema, r, depth);
  switch (schema) {
    case RecordSchema(:final fields):
      final f = fields[r.nextInt(fields.length)];
      final record = value as Map<String, Object?>;
      return {
        ...record,
        f.name: mutate(f.schema, record[f.name], r, depth + 1),
      };
    case ArraySchema(:final items):
      final list = [...value as List<Object?>];
      if (list.isEmpty || r.nextInt(4) == 0) {
        list.add(generate(items, r, depth + 1));
      } else if (r.nextInt(3) == 0) {
        list.removeLast();
      } else {
        final i = r.nextInt(list.length);
        list[i] = mutate(items, list[i], r, depth + 1);
      }
      return list;
    case UnionSchema(:final branches):
      if (value is! Branch || r.nextBool()) return generate(schema, r, depth);
      final branch = branches.firstWhere((s) => _name(s) == value.name);
      return Branch(value.name, mutate(branch, value.value, r, depth + 1));
    default:
      return generate(schema, r, depth);
  }
}
